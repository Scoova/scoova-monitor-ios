import Foundation
import UIKit

/// Scoova Monitor SDK — Main entry point.
///
/// Initialize in your AppDelegate:
/// ```swift
/// ScoovaMonitor.shared.initialize(apiKey: "sm_your_api_key")
/// ```
public final class ScoovaMonitor {
    public static let shared = ScoovaMonitor()

    private(set) var apiKey: String = ""
    private(set) var bundleId: String = ""
    private(set) var endpoint: String = "https://monitor.scoo-va.info"
    private(set) var isInitialized = false

    internal var crashHandler: CrashHandler?
    internal var eventBatcher: EventBatcher?
    internal var sessionTracker: SessionTracker?
    internal var performanceTracker: PerformanceTracker?
    internal var batteryTracker: BatteryTracker?
    internal var runtimePerfTracker: RuntimePerfTracker?

    private var userId: String?

    private init() {
        self.crashHandler = nil
        self.eventBatcher = nil
        self.sessionTracker = nil
        self.performanceTracker = nil
        self.userId = nil
    }

    /// Initialize the SDK. Call this as early as possible in app launch.
    public func initialize(apiKey: String, config: Config = Config()) {
        guard !isInitialized else { return }

        self.apiKey = apiKey
        self.endpoint = config.endpoint
        self.bundleId = Bundle.main.bundleIdentifier ?? ""
        self.isInitialized = true

        // Resolve the anonymous installation ID first — every event from this point
        // onwards needs it as the user_id fallback for DAU/MAU/retention analytics.
        AnonIdStore.initialize()

        // Initialize components
        eventBatcher = EventBatcher(apiKey: apiKey, endpoint: endpoint,
                                     maxBatchSize: config.maxBatchSize,
                                     flushInterval: config.flushInterval)
        crashHandler = CrashHandler(apiKey: apiKey, endpoint: endpoint)
        sessionTracker = SessionTracker(batcher: eventBatcher!)
        performanceTracker = PerformanceTracker(batcher: eventBatcher!)

        // Install crash handler
        crashHandler?.install()

        // Start session tracking
        sessionTracker?.start()

        // Track app start
        performanceTracker?.trackAppStart()

        // Start network monitor
        NetworkMonitor.shared.start()

        // Start auto tracking (screens, breadcrumbs, hang detection, memory)
        AutoTracker.shared.start()

        // Register URL protocol for automatic network tracking
        if config.enablePerformance {
            URLProtocol.registerClass(ScoovaURLProtocol.self)
        }

        // Increment session count and detect first launch
        DeviceContext.shared.incrementSession()

        // Detect and report third-party SDKs on first launch — only if the
        // host explicitly opted in via Config.enableSDKDetection. Off by default.
        if DeviceContext.shared.isFirstLaunch() {
            if config.enableSDKDetection { reportDetectedSDKs() }
            trackEvent("first_launch")
        }

        // Auto-capture install attribution via Apple's AdServices. The
        // helper is idempotent across re-inits (UserDefaults flag) and
        // best-effort — failures fall back to "unknown" rather than
        // blocking init. We only fire `install_info` if the host hasn't
        // already called setInstallSource manually.
        InstallAttribution.captureIfNeeded { [weak self] source, campaign in
            self?.eventBatcher?.trackEvent(name: "install_info", data: [
                "install_source": source,
                "install_campaign": campaign ?? "",
                "session_number": String(DeviceContext.shared.sessionNumber),
            ])
        }

        // Battery tracking
        batteryTracker = BatteryTracker(batcher: eventBatcher!)
        batteryTracker?.start()

        // Continuous frame_rate (CADisplayLink) + memory (task_info)
        // sampling. Auto-pauses on background.
        runtimePerfTracker = RuntimePerfTracker(batcher: eventBatcher!)
        runtimePerfTracker?.start()

        // Send any pending crashes from last session
        crashHandler?.sendPendingCrashes()

        log("Scoova Monitor initialized")
    }

    /// Track a custom analytics event.
    public func trackEvent(_ name: String, data: [String: String]? = nil) {
        ensureInitialized()
        eventBatcher?.trackEvent(name: name, data: data)
    }

    /// Set the user ID for crash and analytics attribution.
    ///
    /// Side-effect: when a previously-anonymous install identifies for
    /// the first time, fire one /v1/ingest/identify so the server merges
    /// the anon profile into the real one. Without this, the same human
    /// shows up as two rows in user_profiles (anon + real) and gets
    /// counted twice in DAU/MAU/cohort retention. Best-effort and
    /// idempotent — repeated calls with the same id no-op.
    public func setUserId(_ userId: String) {
        ensureInitialized()
        let previousUserId = self.userId
        self.userId = userId
        DeviceContext.shared.userId = userId
        guard !userId.isEmpty,
              let anon = AnonIdStore.get(),
              let hashed = PrivacyGuard.hashUserId(userId) else { return }
        if lastIdentifiedAs == hashed { return }
        if previousUserId == userId && identifySent { return }
        Task.detached { [endpoint, apiKey, bundleId] in
            let ok = await Self.postIdentify(
                endpoint: endpoint, apiKey: apiKey, bundleId: bundleId,
                anonId: anon, hashedUserId: hashed
            )
            if ok {
                await MainActor.run {
                    ScoovaMonitor.shared.identifySent = true
                    ScoovaMonitor.shared.lastIdentifiedAs = hashed
                }
            }
        }
    }

    private var identifySent = false
    private var lastIdentifiedAs: String? = nil

    private static func postIdentify(endpoint: String, apiKey: String, bundleId: String,
                                     anonId: String, hashedUserId: String) async -> Bool {
        guard let url = URL(string: "\(endpoint)/v1/ingest/identify") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue(bundleId, forHTTPHeaderField: "X-Bundle-Id")
        req.timeoutInterval = 5
        let body = "{\"anonId\":\"\(anonId)\",\"userId\":\"\(hashedUserId)\"}"
        req.httpBody = body.data(using: .utf8)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    /// Track a network request performance metric.
    public func trackNetworkRequest(url: String, method: String, statusCode: Int, durationMs: Double) {
        ensureInitialized()
        performanceTracker?.trackNetworkRequest(url: url, method: method,
                                                 statusCode: statusCode, durationMs: durationMs)
    }

    /// Log a non-fatal error.
    public func logError(_ error: Error, context: String? = nil) {
        ensureInitialized()
        crashHandler?.reportNonFatal(error, context: context)
    }

    /// Add a breadcrumb for crash context.
    public func addBreadcrumb(_ message: String, category: String = "custom") {
        ensureInitialized()
        crashHandler?.addBreadcrumb(message: message, category: category)
    }

    /// Track a screen view for user flow analysis.
    public func trackScreen(_ screenName: String) {
        ensureInitialized()
        eventBatcher?.trackEvent(name: "screen_view", data: ["screen_name": screenName])
    }

    /// Set the install source for acquisition tracking.
    public func setInstallSource(_ source: String, campaign: String? = nil) {
        ensureInitialized()
        eventBatcher?.trackEvent(name: "install_info", data: [
            "install_source": source,
            "install_campaign": campaign ?? "",
            "session_number": String(DeviceContext.shared.sessionNumber)
        ])
    }

    /// Get a logger for a specific tag/module.
    /// ```swift
    /// let logger = ScoovaMonitor.shared.logger(tag: "payment")
    /// logger.info("Payment started", data: ["amount": "29.99"])
    /// ```
    public func logger(tag: String) -> ScoovaLogger {
        ensureInitialized()
        return ScoovaLogger(tag: tag)
    }

    /// Quick log — shorthand without creating a logger instance.
    public func log(tag: String, level: ScoovaLogger.Level, message: String, data: [String: String]? = nil) {
        ensureInitialized()
        ScoovaLogger(tag: tag).log(level, message, data: data)
    }

    /// Flush pending events, metrics, and logs immediately.
    public func flush() {
        ensureInitialized()
        eventBatcher?.flush()
        LogQueue.shared.flush()
    }

    /// Wipe every piece of telemetry the SDK has buffered or persisted on
    /// this device. Call this when the host app's user invokes "delete my
    /// account" — pairs with the server-side `DELETE /v1/ingest/me/{userId}`
    /// to satisfy GDPR Article 17 / CCPA "right to be forgotten" end-to-end.
    ///
    /// What this clears:
    ///   - the in-memory + on-disk event / metric / log queues
    ///   - the pending crash file (if any)
    ///   - breadcrumbs accumulated this session
    ///   - the anonymous installation ID (a fresh one is generated on the next event)
    ///   - the persisted session counter
    ///   - the user_id set via setUserId()
    ///
    /// Does NOT contact the server. The host app should also call your
    /// server's GDPR delete endpoint with the user_id you previously sent.
    public func clearLocalUserData() {
        ensureInitialized()
        // Best-effort wipe — we never want this to throw and block the host's
        // delete-account flow.
        eventBatcher?.clearAllQueues()
        crashHandler?.clearPendingCrashes()
        crashHandler?.clearBreadcrumbs()
        AnonIdStore.reset()
        DeviceContext.shared.userId = nil
        DeviceContext.shared.resetSessionCounter()
        log(tag: "ScoovaMonitor", level: .info, message: "Local user data cleared")
    }

    private func reportDetectedSDKs() {
        let sdks = DeviceContext.shared.detectThirdPartySDKs()
        if !sdks.isEmpty {
            let sdkData = sdks.reduce(into: [String: String]()) { result, sdk in
                result[sdk["name"] ?? "unknown"] = sdk["version"] ?? "detected"
            }
            eventBatcher?.trackEvent(name: "detected_sdks", data: sdkData)
        }
    }

    private func ensureInitialized() {
        guard isInitialized else {
            fatalError("ScoovaMonitor not initialized. Call ScoovaMonitor.shared.initialize(apiKey:) first.")
        }
    }

    internal func log(_ message: String) {
        #if DEBUG
        print("[ScoovaMonitor] \(message)")
        #endif
    }

    public struct Config {
        public var endpoint: String
        public var enableCrashReporting: Bool
        public var enableAnalytics: Bool
        public var enablePerformance: Bool
        public var flushInterval: TimeInterval
        public var maxBatchSize: Int
        /// Probe the bundle for third-party SDK presence (Firebase, Sentry,
        /// Mixpanel, etc) and report once-per-install. **Disabled by default**
        /// — enable explicitly only if you want the "Detected SDKs" dashboard.
        public var enableSDKDetection: Bool

        public init(
            endpoint: String = "https://monitor.scoo-va.info",
            enableCrashReporting: Bool = true,
            enableAnalytics: Bool = true,
            enablePerformance: Bool = true,
            flushInterval: TimeInterval = 300,
            maxBatchSize: Int = 50,
            enableSDKDetection: Bool = false
        ) {
            self.endpoint = endpoint
            self.enableCrashReporting = enableCrashReporting
            self.enableAnalytics = enableAnalytics
            self.enablePerformance = enablePerformance
            self.flushInterval = flushInterval
            self.maxBatchSize = maxBatchSize
            self.enableSDKDetection = enableSDKDetection
        }
    }
}
