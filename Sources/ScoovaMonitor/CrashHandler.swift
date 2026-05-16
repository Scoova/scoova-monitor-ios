import Foundation
import UIKit

internal final class CrashHandler {
    private let apiKey: String
    private let endpoint: String
    private var breadcrumbs: [Breadcrumb] = []
    private var recentLogs: [String] = []
    private var recentNetworkRequests: [String] = []
    private let maxBreadcrumbs = 100
    private let maxRecentItems = 50
    private let queue = DispatchQueue(label: "com.scoova.monitor.crash", qos: .utility)

    struct Breadcrumb: Codable {
        let message: String
        let category: String
        let timestamp: String
    }

    init(apiKey: String, endpoint: String) {
        self.apiKey = apiKey
        self.endpoint = endpoint
    }

    func install() {
        NSSetUncaughtExceptionHandler { exception in
            CrashHandler.handleException(exception)
        }
        installSignalHandlers()
        ScoovaMonitor.shared.log("Crash handler installed")
    }

    /// Report a main-thread hang as a non-fatal crash row.
    ///
    /// This is the iOS equivalent of an Android ANR. We deliberately route
    /// through the same `crash_reports` path (not `analytics_events`) so the
    /// dashboard's Crashes UI can show ANR rate alongside crash rate, the
    /// way Firebase / Sentry / Crashlytics do.
    func reportHang(durationThresholdSeconds: Double, source: String, mainThreadStack: String? = nil) {
        ScoovaMonitor.shared.log("Hang captured (>\(durationThresholdSeconds)s, \(source)) — uploading")
        queue.async { [weak self] in
            guard let self = self else { return }
            let stack = mainThreadStack
                ?? "(main thread stack unavailable from \(source) — see Xcode Organizer for symbolicated trace)"
            let report = self.buildFullCrashReport(
                exceptionType: "ANR (Main Thread Hang)",
                message: "Main thread blocked for >\(durationThresholdSeconds)s (source: \(source))",
                stackTrace: stack,
                isFatal: false
            )
            self.saveCrashToDisk(report)
            // Keep the on-disk copy unless the server confirmed receipt —
            // a failed send then replays on the next launch.
            if self.sendReportSync(report) {
                try? FileManager.default.removeItem(at: self.pendingCrashFile())
            }
        }
    }

    func reportNonFatal(_ error: Error, context: String? = nil) {
        let errType = String(describing: type(of: error))
        ScoovaMonitor.shared.log("Non-fatal error captured: \(errType) — uploading")
        queue.async { [weak self] in
            guard let self = self else { return }
            let report = self.buildFullCrashReport(
                exceptionType: errType,
                message: error.localizedDescription + (context.map { " | \($0)" } ?? ""),
                stackTrace: Thread.callStackSymbols.joined(separator: "\n"),
                isFatal: false
            )
            // Save to disk first — guarantees the next launch will flush
            // it via sendPendingCrashes() even if the in-process sync
            // POST below fails / gets killed mid-flight.
            self.saveCrashToDisk(report)
            // Attempt synchronous delivery. Only drop the on-disk copy if
            // the server actually accepted it — otherwise it stays and
            // sendPendingCrashes() replays it on the next launch.
            if self.sendReportSync(report) {
                try? FileManager.default.removeItem(at: self.pendingCrashFile())
            }
        }
    }

    func addBreadcrumb(message: String, category: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.breadcrumbs.count >= self.maxBreadcrumbs { self.breadcrumbs.removeFirst() }
            self.breadcrumbs.append(Breadcrumb(
                message: message, category: category,
                timestamp: ISO8601DateFormatter().string(from: Date())
            ))
        }
    }

    func addRecentLog(_ log: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.recentLogs.count >= self.maxRecentItems { self.recentLogs.removeFirst() }
            self.recentLogs.append(log)
        }
    }

    func addRecentNetworkRequest(_ request: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.recentNetworkRequests.count >= self.maxRecentItems { self.recentNetworkRequests.removeFirst() }
            self.recentNetworkRequests.append(request)
        }
    }

    func sendPendingCrashes() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let fileURL = self.pendingCrashFile()
            guard let data = try? Data(contentsOf: fileURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            // Confirmed delivery: keep the on-disk copy unless the server
            // accepted it (2xx). Previously this was a fire-and-forget POST
            // followed by an unconditional delete — a crash from the last
            // session was lost whenever that POST failed (offline launch,
            // transient 5xx, process killed mid-flight). Now a failed send
            // simply replays on the next launch.
            if self.sendReportSync(json) {
                try? FileManager.default.removeItem(at: fileURL)
                ScoovaMonitor.shared.log("Sent pending crash from previous session")
            }
        }
    }

    // MARK: - Exception Handling

    private static func handleException(_ exception: NSException) {
        guard let handler = ScoovaMonitor.shared.crashHandler else { return }
        let report = handler.buildFullCrashReport(
            exceptionType: exception.name.rawValue,
            message: exception.reason ?? "No reason",
            stackTrace: exception.callStackSymbols.joined(separator: "\n"),
            isFatal: true
        )
        // Save first so the report survives if the in-handler POST is cut
        // short, then deliver synchronously. Drop the on-disk copy only on
        // confirmed receipt — otherwise it stays and sendPendingCrashes()
        // replays it next launch (instead of silently double-sending).
        handler.saveCrashToDisk(report)
        if handler.sendReportSync(report) {
            try? FileManager.default.removeItem(at: handler.pendingCrashFile())
        }
    }

    private func installSignalHandlers() {
        let signals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP]
        for sig in signals {
            signal(sig) { signal in
                let handler = ScoovaMonitor.shared.crashHandler
                let report = handler?.buildFullCrashReport(
                    exceptionType: "Signal \(signal) (\(CrashHandler.signalName(signal)))",
                    message: "Fatal signal: \(CrashHandler.signalName(signal)) (\(signal)). \(CrashHandler.signalExplanation(signal))",
                    stackTrace: Thread.callStackSymbols.joined(separator: "\n"),
                    isFatal: true
                )
                if let report = report {
                    handler?.saveCrashToDisk(report)
                }
                Darwin.signal(signal, SIG_DFL)
                Darwin.raise(signal)
            }
        }
    }

    // MARK: - Full Forensic Report

    private func buildFullCrashReport(
        exceptionType: String, message: String, stackTrace: String, isFatal: Bool
    ) -> [String: Any] {

        // Thread dump
        let allThreads = captureAllThreads()

        // App state
        let appState = captureAppState()

        // Memory
        let memoryState = captureMemoryState()

        // Crash pattern
        let crashPattern = detectCrashPattern(exceptionType: exceptionType, message: message, stackTrace: stackTrace)

        // Breadcrumbs
        let breadcrumbStr = breadcrumbs.isEmpty ? "" :
            "\n\n--- Breadcrumbs (last \(breadcrumbs.count)) ---\n" +
            breadcrumbs.suffix(30).map { "[\($0.timestamp)] [\($0.category)] \($0.message)" }.joined(separator: "\n")

        // Build crash context
        var crashContext: [String: String] = [:]
        crashContext["crashPattern"] = crashPattern
        crashContext["threadCount"] = String(ProcessInfo.processInfo.activeProcessorCount)
        crashContext["exceptionType"] = exceptionType

        var payload: [String: Any] = [
            "exceptionType": exceptionType,
            "message": PrivacyGuard.sanitizeMessage(message),
            "stackTrace": PrivacyGuard.sanitizeStackTrace(stackTrace + breadcrumbStr),
            "isFatal": isFatal,
            "sessionId": DeviceContext.shared.sessionId,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "allThreads": allThreads,
            "appState": appState,
            "memoryState": memoryState,
            "crashContext": crashContext,
            "recentLogs": Array(recentLogs.suffix(20)),
            "recentNetworkRequests": Array(recentNetworkRequests.suffix(10))
        ]

        if let userId = DeviceContext.shared.userId {
            payload["userId"] = PrivacyGuard.hashUserId(userId) as Any
        }

        payload["device"] = DeviceContext.shared.collect()

        return payload
    }

    // MARK: - Thread Dump

    private func captureAllThreads() -> String {
        var dump = "=== ALL THREADS AT CRASH TIME ===\n"
        dump += "Active processor count: \(ProcessInfo.processInfo.activeProcessorCount)\n\n"
        dump += "--- Current Thread ---\n"
        for symbol in Thread.callStackSymbols {
            dump += "    \(symbol)\n"
        }
        dump += "\n(Note: iOS does not expose other threads' stacks from user space.\n"
        dump += "Use the crash log from Xcode Organizer for full thread dumps.)\n"
        return dump
    }

    // MARK: - App State

    private func captureAppState() -> [String: String] {
        var state: [String: String] = [:]

        let app = UIApplication.shared
        state["appState"] = {
            switch app.applicationState {
            case .active: return "foreground_active"
            case .inactive: return "foreground_inactive"
            case .background: return "background"
            @unknown default: return "unknown"
            }
        }()

        state["sessionNumber"] = String(DeviceContext.shared.sessionNumber)
        state["sessionId"] = DeviceContext.shared.sessionId

        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            state["appVersion"] = appVersion
        }
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            state["buildNumber"] = build
        }
        state["bundleId"] = Bundle.main.bundleIdentifier ?? "unknown"

        let uptime = ProcessInfo.processInfo.systemUptime
        state["processUptimeMinutes"] = String(format: "%.1f", uptime / 60.0)

        // Thermal state
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: state["thermalState"] = "nominal"
        case .fair: state["thermalState"] = "fair"
        case .serious: state["thermalState"] = "serious"
        case .critical: state["thermalState"] = "critical"
        @unknown default: state["thermalState"] = "unknown"
        }

        // Low power mode
        state["isLowPowerMode"] = ProcessInfo.processInfo.isLowPowerModeEnabled ? "true" : "false"

        return state
    }

    // MARK: - Memory State

    private func captureMemoryState() -> [String: String] {
        var mem: [String: String] = [:]

        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        mem["physicalMemory"] = formatBytes(Int64(physicalMemory))

        // App memory usage
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            mem["appMemoryUsed"] = formatBytes(Int64(info.resident_size))
            mem["appMemoryPercent"] = String(format: "%.1f%%", Double(info.resident_size) / Double(physicalMemory) * 100)
        }

        // Disk space
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? Int64,
           let total = attrs[.systemSize] as? Int64 {
            mem["diskFree"] = formatBytes(free)
            mem["diskTotal"] = formatBytes(total)
        }

        return mem
    }

    // MARK: - Crash Pattern Detection

    private func detectCrashPattern(exceptionType: String, message: String, stackTrace: String) -> String {
        let msg = message.lowercased()
        let type = exceptionType.lowercased()

        return switch true {
        case type.contains("nsrangeexception") || type.contains("indexoutofrange"):
            "INDEX_OOB: Array/collection access beyond bounds. Check array sizes before accessing."
        case type.contains("nsinternalinconsistency"):
            "INTERNAL_INCONSISTENCY: UIKit state corruption. Often caused by modifying UI from background thread or data source inconsistency."
        case type.contains("nsinvalidargument"):
            "INVALID_ARGUMENT: Method received an unexpected nil or wrong-type argument."
        case msg.contains("unexpectedly found nil"):
            "FORCE_UNWRAP: Force-unwrapped an Optional that was nil. Use guard let or if let instead."
        case msg.contains("index out of range"):
            "INDEX_OOB: Array access beyond bounds. Validate index before accessing."
        case msg.contains("exc_bad_access") || exceptionType.contains("SIGSEGV") || exceptionType.contains("SIGBUS"):
            "BAD_ACCESS: Accessing deallocated memory. Check for use-after-free, dangling pointers, or zombie objects."
        case exceptionType.contains("SIGABRT"):
            "ABORT: Process aborted. Usually from a failed assertion, unhandled exception, or constraint violation."
        case msg.contains("thread") && msg.contains("main"):
            "MAIN_THREAD: UI operation performed on background thread. Dispatch to main queue."
        case msg.contains("coredata") || msg.contains("nsmanagedobject"):
            "COREDATA: Core Data threading violation or context error. Use performAndWait or proper context."
        case msg.contains("memory") || type.contains("malloc"):
            "OOM: Out of memory. Check for large image loading, memory leaks, or unbounded caches."
        case msg.contains("network") || msg.contains("nsurlsession") || msg.contains("timeout"):
            "NETWORK: Network operation failure. Check connectivity, timeout handling, and error callbacks."
        case msg.contains("json") || msg.contains("codable") || msg.contains("decod"):
            "JSON_DECODE: JSON parsing failure. Check API response format matches your Codable models."
        case msg.contains("keychain"):
            "KEYCHAIN: Keychain access error. Check entitlements and background access settings."
        case stackTrace.contains("UICollectionView") || stackTrace.contains("UITableView"):
            "COLLECTION_VIEW: Data source inconsistency. Make sure numberOfItems matches your data array."
        case stackTrace.contains("SwiftUI") && msg.contains("update"):
            "SWIFTUI: SwiftUI state update on wrong thread or during view update cycle."
        default:
            "UNKNOWN: Review stack trace for root cause."
        }
    }

    // MARK: - Signal Names

    private static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "SIGABRT"
        case SIGBUS: return "SIGBUS"
        case SIGFPE: return "SIGFPE"
        case SIGILL: return "SIGILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGTRAP: return "SIGTRAP"
        default: return "SIGNAL_\(signal)"
        }
    }

    private static func signalExplanation(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "Process was aborted. Usually from NSException, assert(), or abort()."
        case SIGBUS: return "Bus error — accessing misaligned memory or invalid physical address."
        case SIGFPE: return "Floating point exception — division by zero or arithmetic overflow."
        case SIGILL: return "Illegal instruction — corrupted binary, bad cast, or calling convention mismatch."
        case SIGSEGV: return "Segmentation fault — accessing memory that doesn't belong to this process."
        case SIGTRAP: return "Trace/breakpoint trap — debugger break, Swift fatalError(), or precondition failure."
        default: return "Unexpected signal."
        }
    }

    // MARK: - Send / Save

    /// Coerce a crash payload into something JSONSerialization always
    /// accepts. A single non-finite Double (NaN / Infinity — e.g. a rate
    /// with a zero denominator, or simulator battery state) otherwise makes
    /// the whole report unserializable, and it was being dropped silently
    /// by *both* the network send and the on-disk replay fallback.
    private func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = jsonSafe(v) }
            return out
        case let arr as [Any]:
            return arr.map { jsonSafe($0) }
        case let b as Bool:   return b
        case let i as Int:    return i
        case let d as Double: return d.isFinite ? d : 0
        case let f as Float:  return f.isFinite ? f : 0
        case let s as String: return s
        case is NSNull:       return value
        default:              return String(describing: value)
        }
    }

    /// Serialize a crash payload, sanitizing it first. Returns nil only if
    /// it is still invalid afterward — and logs it, never fails silently.
    private func crashJSON(_ payload: [String: Any]) -> Data? {
        let safe = jsonSafe(payload)
        guard JSONSerialization.isValidJSONObject(safe),
              let data = try? JSONSerialization.data(withJSONObject: safe) else {
            ScoovaMonitor.shared.log("Crash report dropped: payload not serializable")
            return nil
        }
        return data
    }

    private func sendReport(_ payload: [String: Any]) {
        postJSON(payload)
    }

    /// Synchronously POST a crash report. Returns true only if the server
    /// accepted it (2xx) — callers use this to decide whether to keep the
    /// on-disk copy for next-launch replay.
    @discardableResult
    private func sendReportSync(_ payload: [String: Any]) -> Bool {
        guard let data = crashJSON(payload) else { return false }
        guard let url = URL(string: "\(endpoint)/v1/ingest/crashes") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        // Server's validateApiKeyWithBundle requires X-Bundle-Id when
        // the platform row was registered with one. Without this,
        // crashes silently fail with a 401 even though the API key is
        // valid.
        request.setValue(ScoovaMonitor.shared.bundleId, forHTTPHeaderField: "X-Bundle-Id")
        request.httpBody = data
        request.timeoutInterval = 10
        var delivered = false
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                ScoovaMonitor.shared.log("Crash upload failed: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) {
                    delivered = true
                    ScoovaMonitor.shared.log("Crash report uploaded (HTTP \(http.statusCode))")
                } else {
                    ScoovaMonitor.shared.log("Crash upload rejected: HTTP \(http.statusCode)")
                }
            }
            semaphore.signal()
        }.resume()
        if semaphore.wait(timeout: .now() + 12) == .timedOut {
            ScoovaMonitor.shared.log("Crash upload timed out")
        }
        return delivered
    }

    private func postJSON(_ payload: [String: Any]) {
        guard let data = crashJSON(payload) else { return }
        guard let url = URL(string: "\(endpoint)/v1/ingest/crashes") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue(ScoovaMonitor.shared.bundleId, forHTTPHeaderField: "X-Bundle-Id")
        request.httpBody = data
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                ScoovaMonitor.shared.log("Failed to send crash: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                ScoovaMonitor.shared.log("Crash upload rejected: HTTP \(http.statusCode)")
            }
        }.resume()
    }

    private func saveCrashToDisk(_ payload: [String: Any]) {
        guard let data = crashJSON(payload) else { return }
        try? data.write(to: pendingCrashFile())
    }

    fileprivate func pendingCrashFile() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("scoova_pending_crash.json")
    }

    /// Wipe the pending-crash file (if any). Called from clearLocalUserData().
    func clearPendingCrashes() {
        try? FileManager.default.removeItem(at: pendingCrashFile())
    }

    /// Clear in-memory breadcrumbs. Called from clearLocalUserData().
    func clearBreadcrumbs() {
        queue.async { [weak self] in self?.breadcrumbs.removeAll() }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        switch bytes {
        case let b where b >= 1_073_741_824: return String(format: "%.1f GB", Double(b) / 1_073_741_824)
        case let b where b >= 1_048_576: return String(format: "%.1f MB", Double(b) / 1_048_576)
        case let b where b >= 1024: return String(format: "%.1f KB", Double(b) / 1024)
        default: return "\(bytes) B"
        }
    }
}
