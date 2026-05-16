import Foundation
import UIKit

internal let kSDKVersion = "1.4.1"

internal final class DeviceContext {
    static let shared = DeviceContext()

    var userId: String?
    var sessionId: String
    var sessionNumber: Int = 0

    private let defaults = UserDefaults(suiteName: "com.scoova.monitor") ?? .standard

    private init() {
        self.userId = nil
        self.sessionId = UUID().uuidString
    }

    func newSession() {
        sessionId = UUID().uuidString
    }

    func incrementSession() {
        sessionNumber = defaults.integer(forKey: "session_number") + 1
        defaults.set(sessionNumber, forKey: "session_number")
    }

    /// Wipe the persisted session number and the first-launch marker. Called
    /// from clearLocalUserData() so the next session looks like a fresh install.
    func resetSessionCounter() {
        defaults.removeObject(forKey: "session_number")
        defaults.removeObject(forKey: "first_launch_done")
        sessionNumber = 0
    }

    func isFirstLaunch() -> Bool {
        let key = "first_launch_done"
        let first = !defaults.bool(forKey: key)
        if first { defaults.set(true, forKey: key) }
        return first
    }

    func collect() -> [String: Any] {
        let device = UIDevice.current
        let screen = UIScreen.main
        let processInfo = ProcessInfo.processInfo

        var info: [String: Any] = [
            "manufacturer": "Apple",
            "model": deviceModel(),
            "osName": "iOS",
            "osVersion": device.systemVersion,
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
            "country": Locale.current.regionCode ?? "",
            "screenResolution": "\(Int(screen.bounds.width * screen.scale))x\(Int(screen.bounds.height * screen.scale))",
            "cpuArch": cpuArchitecture(),
            "ramTotal": processInfo.physicalMemory,
            "orientation": device.orientation.isLandscape ? "landscape" : "portrait",
            "jailbroken": isJailbroken(),
            "framework": detectFramework(),
            "sdkVersion": kSDKVersion
        ]

        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            info["appVersion"] = appVersion
        }
        if let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            info["buildNumber"] = buildNumber
        }

        // Battery
        device.isBatteryMonitoringEnabled = true
        if device.batteryLevel >= 0 {
            info["batteryLevel"] = device.batteryLevel
            info["isCharging"] = device.batteryState == .charging || device.batteryState == .full
        }

        // Thermal state
        info["thermalState"] = thermalState()

        // Network type
        info["networkType"] = getNetworkType()

        // Available memory
        info["ramFree"] = freeMemory()

        // Disk
        if let diskFree = freeDiskSpace() {
            info["diskFree"] = diskFree
        }

        // Carrier
        if let carrier = getCarrier() {
            info["carrier"] = carrier
        }

        // Note: the SDK does not read device GPS location. Region (country /
        // city) is resolved server-side from the request IP at ingest — see
        // the Transparency page. Keeping device-location APIs out of the SDK
        // entirely means there's nothing here for a host developer to audit.

        return info
    }

    func collectLight() -> [String: String] {
        var info: [String: String] = [
            "manufacturer": "Apple",
            "model": deviceModel(),
            "osName": "iOS",
            "osVersion": UIDevice.current.systemVersion,
            "locale": Locale.current.identifier,
            "country": Locale.current.regionCode ?? "",
            "cpuArch": cpuArchitecture(),
            "framework": detectFramework(),
            "sdkVersion": kSDKVersion
        ]
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            info["appVersion"] = v
        }
        if let carrier = getCarrier() { info["carrier"] = carrier }
        info["networkType"] = getNetworkType()
        return info
    }

    private func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { id, element in
            guard let value = element.value as? Int8, value != 0 else { return id }
            return id + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }

    private func cpuArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private func getCarrier() -> String? {
        // CTCarrier is deprecated in iOS 16+, return nil for modern iOS
        return nil
    }

    private func detectFramework() -> String {
        if Bundle.main.object(forInfoDictionaryKey: "FlutterDeploymentTarget") != nil { return "flutter" }
        if NSClassFromString("RCTBridge") != nil { return "react-native" }
        if NSClassFromString("KotlinBase") != nil { return "kmp" }
        return "native"
    }

    func detectThirdPartySDKs() -> [[String: String]] {
        var sdks: [[String: String]] = []
        let knownSDKs: [String: String] = [
            "FIRApp": "firebase",
            "GADMobileAds": "google-admob",
            "FBSDKCoreKit": "facebook-sdk",
            "STPAPIClient": "stripe",
            "SentrySDK": "sentry",
            "Amplitude": "amplitude",
            "Mixpanel": "mixpanel",
            "AppsFlyerLib": "appsflyer",
            "ADJConfig": "adjust",
            "Braze": "braze",
            "OneSignal": "onesignal",
            "GMSMapView": "google-maps",
            "MKMapView": "apple-maps",
            "CLLocationManager": "core-location",
            "LOTAnimationView": "lottie"
        ]
        for (className, sdkName) in knownSDKs {
            if NSClassFromString(className) != nil {
                sdks.append(["name": sdkName])
            }
        }
        return sdks
    }

    private func isJailbroken() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let paths = [
            "/Applications/Cydia.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/bin/bash", "/usr/sbin/sshd", "/etc/apt",
            "/private/var/lib/apt/"
        ]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
        #endif
    }

    private func getNetworkType() -> String {
        return NetworkMonitor.shared.currentType
    }

    private func freeMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    private func freeDiskSpace() -> Int64? {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let path = paths.last?.path else { return nil }
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path)
        return attrs?[.systemFreeSize] as? Int64
    }

    // Device GPS location is intentionally NOT collected by this SDK.
    // Region is derived server-side from the request IP at ingest, which
    // is enough for the regional analytics the dashboard shows — and it
    // means the SDK touches no location APIs at all.
}
