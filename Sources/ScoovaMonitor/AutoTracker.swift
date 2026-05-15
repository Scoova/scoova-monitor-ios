import Foundation
import UIKit

/// Automatic tracking: screens, breadcrumbs, memory warnings, hang detection.
/// Covers Fix #9 (auto screen tracking), #18 (auto breadcrumbs), #20 (memory warnings), #22 (hang detection)
internal final class AutoTracker {
    static let shared = AutoTracker()

    private var previousScreen: String?
    private var screenStartTime: Date?
    private var hangWatchdog: Thread?
    private var isTracking = false

    private init() {}

    func start() {
        guard !isTracking else { return }
        isTracking = true

        // Auto screen tracking via UIViewController lifecycle swizzling
        swizzleViewDidAppear()

        // Memory warning tracking
        NotificationCenter.default.addObserver(
            self, selector: #selector(didReceiveMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil
        )

        // Auto breadcrumbs for app lifecycle
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)

        // Hang detection (main thread watchdog)
        startHangDetector()

        // Auto tap tracking (privacy-safe: IDs and types only, no text)
        swizzleSendEvent()

        // Orientation changes
        NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged),
            name: UIDevice.orientationDidChangeNotification, object: nil)

        // Keyboard show/hide (not content)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardShown),
            name: UIResponder.keyboardDidShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden),
            name: UIResponder.keyboardDidHideNotification, object: nil)

        ScoovaMonitor.shared.log("AutoTracker started (privacy-safe)")
    }

    // MARK: - Screen Tracking (Fix #9)

    private func swizzleViewDidAppear() {
        let originalSelector = #selector(UIViewController.viewDidAppear(_:))
        let swizzledSelector = #selector(UIViewController.scoova_viewDidAppear(_:))

        guard let originalMethod = class_getInstanceMethod(UIViewController.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(UIViewController.self, swizzledSelector) else { return }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    func trackScreen(_ screenName: String) {
        let now = Date()

        // Track duration on previous screen
        if let prev = previousScreen, let start = screenStartTime {
            let duration = now.timeIntervalSince(start)
            ScoovaMonitor.shared.eventBatcher?.trackEvent(name: "screen_view", data: [
                "screen_name": prev,
                "duration_seconds": String(format: "%.1f", duration),
                "next_screen": screenName
            ])
        }

        previousScreen = screenName
        screenStartTime = now

        // Auto breadcrumb
        ScoovaMonitor.shared.crashHandler?.addBreadcrumb(message: "Screen: \(screenName)", category: "navigation")
    }

    // MARK: - Memory Warning (Fix #20)

    @objc private func didReceiveMemoryWarning() {
        ScoovaMonitor.shared.eventBatcher?.trackEvent(name: "memory_warning", data: [
            "free_memory": String(DeviceContext.shared.collect()["ramFree"] as? UInt64 ?? 0)
        ])
        ScoovaMonitor.shared.crashHandler?.addBreadcrumb(message: "Memory warning received", category: "system")
    }

    // MARK: - Auto Breadcrumbs (Fix #18)

    @objc private func appWillResignActive() {
        ScoovaMonitor.shared.crashHandler?.addBreadcrumb(message: "App resigned active", category: "lifecycle")
        // Drain queued events before the OS can suspend us. Disk queue persists
        // anything that doesn't get sent, so kill mid-flight is safe — flushing
        // here keeps the dashboard fresh under longer flush intervals.
        ScoovaMonitor.shared.flush()
    }

    @objc private func appDidBecomeActive() {
        ScoovaMonitor.shared.crashHandler?.addBreadcrumb(message: "App became active", category: "lifecycle")
    }

    // MARK: - Privacy-Safe Tap Tracking
    // Tracks control type + accessibilityIdentifier, NEVER text content

    private var lastTapTime: Date = .distantPast

    private func swizzleSendEvent() {
        let originalSelector = #selector(UIApplication.sendEvent(_:))
        let swizzledSelector = #selector(UIApplication.scoova_sendEvent(_:))
        guard let originalMethod = class_getInstanceMethod(UIApplication.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(UIApplication.self, swizzledSelector) else { return }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    func trackTap(_ view: UIView) {
        // Debounce: no more than 1 tap per 300ms
        let now = Date()
        guard now.timeIntervalSince(lastTapTime) > 0.3 else { return }
        lastTapTime = now

        // Get safe identifier — accessibilityIdentifier or class name, NEVER text
        let viewId = view.accessibilityIdentifier ?? ""
        let viewType: String
        switch view {
        case is UIButton: viewType = "button"
        case is UISwitch: viewType = "switch"
        case is UISegmentedControl: viewType = "segmented_control"
        case is UISlider: viewType = "slider"
        case is UITableViewCell: viewType = "table_cell"
        case is UICollectionViewCell: viewType = "collection_cell"
        default: viewType = String(describing: type(of: view)).lowercased()
        }

        // Only track interactive controls
        let isInteractive = view is UIControl || view.gestureRecognizers?.isEmpty == false
        guard isInteractive || view is UITableViewCell || view is UICollectionViewCell else { return }

        var data: [String: String] = [
            "view_type": viewType,
            "screen": previousScreen ?? "unknown"
        ]
        if !viewId.isEmpty { data["view_id"] = viewId }
        // NEVER add text content, label, or title

        ScoovaMonitor.shared.eventBatcher?.trackEvent(name: "user_tap", data: data)
        ScoovaMonitor.shared.crashHandler?.addBreadcrumb(
            message: "Tap: \(viewType)\(!viewId.isEmpty ? "#\(viewId)" : "") on \(previousScreen ?? "?")",
            category: "ui"
        )
    }

    // MARK: - Orientation + Keyboard

    @objc private func orientationChanged() {
        let orientation = UIDevice.current.orientation
        let name: String
        switch orientation {
        case .portrait: name = "portrait"
        case .landscapeLeft, .landscapeRight: name = "landscape"
        case .portraitUpsideDown: name = "portrait_upside_down"
        default: return // Skip .faceUp, .faceDown, .unknown
        }
        ScoovaMonitor.shared.eventBatcher?.trackEvent(name: "orientation_change", data: ["orientation": name])
        ScoovaMonitor.shared.crashHandler?.addBreadcrumb(message: "Orientation: \(name)", category: "system")
    }

    @objc private func keyboardShown() {
        ScoovaMonitor.shared.crashHandler?.addBreadcrumb(message: "Keyboard shown", category: "ui")
    }

    @objc private func keyboardHidden() {
        ScoovaMonitor.shared.crashHandler?.addBreadcrumb(message: "Keyboard hidden", category: "ui")
    }

    // MARK: - Hang Detection (Fix #22)

    private func startHangDetector() {
        hangWatchdog = Thread {
            while true {
                let responded = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
                responded.pointee = false

                DispatchQueue.main.async {
                    responded.pointee = true
                }

                Thread.sleep(forTimeInterval: 3.0) // 3 second threshold

                if !responded.pointee {
                    // Main thread is blocked — report hang as a non-fatal
                    // crash row (ANR-equivalent on iOS). Using the watchdog
                    // thread's own callStackSymbols would dump the watchdog,
                    // not the main thread, so we leave the stack nil and let
                    // CrashHandler stamp a placeholder that points users at
                    // the Xcode Organizer for the symbolicated trace.
                    ScoovaMonitor.shared.crashHandler?.reportHang(
                        durationThresholdSeconds: 3.0,
                        source: "AutoTracker watchdog"
                    )
                    ScoovaMonitor.shared.crashHandler?.addBreadcrumb(
                        message: "Main thread hang detected (>3s)", category: "performance"
                    )
                    // Wait longer before checking again
                    Thread.sleep(forTimeInterval: 10.0)
                }

                responded.deallocate()
                Thread.sleep(forTimeInterval: 5.0) // Check every 8s total
            }
        }
        hangWatchdog?.name = "ScoovaMonitor-HangDetector"
        hangWatchdog?.qualityOfService = .utility
        hangWatchdog?.start()
    }
}

// MARK: - UIApplication Tap Swizzle (privacy-safe)

extension UIApplication {
    @objc func scoova_sendEvent(_ event: UIEvent) {
        scoova_sendEvent(event) // Call original

        // Only track touch-ended events (actual taps)
        guard event.type == .touches else { return }
        guard let touch = event.allTouches?.first, touch.phase == .ended else { return }
        guard let view = touch.view else { return }

        AutoTracker.shared.trackTap(view)
    }
}

// MARK: - UIViewController Swizzle

extension UIViewController {
    @objc func scoova_viewDidAppear(_ animated: Bool) {
        // Call original (swizzled) implementation
        scoova_viewDidAppear(animated)

        // Skip system/internal view controllers
        let className = String(describing: type(of: self))
        let skipPrefixes = ["UI", "_UI", "NS", "_NS", "AVPlayerView", "SFSafari", "MFMail", "PKPayment"]
        guard !skipPrefixes.contains(where: { className.hasPrefix($0) }) else { return }

        AutoTracker.shared.trackScreen(className)
    }
}
