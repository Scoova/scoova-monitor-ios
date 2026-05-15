import Foundation
import UIKit

internal final class SessionTracker {
    private let batcher: EventBatcher
    private var sessionStartTime: Date?
    private var isInForeground = false

    init(batcher: EventBatcher) {
        self.batcher = batcher
    }

    func start() {
        startNewSession()

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification, object: nil
        )
    }

    @objc private func appDidBecomeActive() {
        guard !isInForeground else { return }
        isInForeground = true
        startNewSession()
        batcher.trackEvent(name: "session_start", data: [
            "session_id": DeviceContext.shared.sessionId
        ])
        ScoovaMonitor.shared.log("Session started: \(DeviceContext.shared.sessionId)")
    }

    @objc private func appDidEnterBackground() {
        guard isInForeground else { return }
        isInForeground = false
        endSession()
    }

    @objc private func appWillTerminate() {
        endSession()
    }

    private func startNewSession() {
        DeviceContext.shared.newSession()
        sessionStartTime = Date()
    }

    private func endSession() {
        let duration = sessionStartTime.map { Date().timeIntervalSince($0) } ?? 0
        batcher.trackEvent(name: "session_end", data: [
            "session_id": DeviceContext.shared.sessionId,
            "duration_seconds": String(format: "%.1f", duration)
        ])
        batcher.flush()
        ScoovaMonitor.shared.log("Session ended: \(DeviceContext.shared.sessionId) (\(String(format: "%.1f", duration))s)")
    }
}
