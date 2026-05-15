import Foundation
import UIKit

/// Tracks battery drain rate, level, and temperature for performance monitoring.
internal final class BatteryTracker {

    private let batcher: EventBatcher
    private var timer: Timer?
    private var lastLevel: Float?
    private var lastSampleTime: Date?
    private var sessionStartLevel: Float?
    private var sessionStartTime: Date?

    init(batcher: EventBatcher) {
        self.batcher = batcher
    }

    func start() {
        // Enable battery monitoring
        UIDevice.current.isBatteryMonitoringEnabled = true

        // Initial sample
        sampleBattery()
        sessionStartLevel = UIDevice.current.batteryLevel
        sessionStartTime = Date()

        // Sample every 5 minutes
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.sampleBattery()
        }

        // Listen for battery events
        NotificationCenter.default.addObserver(self, selector: #selector(batteryLevelChanged),
                                               name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(batteryStateChanged),
                                               name: UIDevice.batteryStateDidChangeNotification, object: nil)

        ScoovaMonitor.shared.log("BatteryTracker started")
    }

    private func sampleBattery() {
        let level = UIDevice.current.batteryLevel // 0.0 to 1.0, -1 if unknown
        guard level >= 0 else { return }

        let percentage = level * 100
        let state = UIDevice.current.batteryState
        let isCharging = state == .charging || state == .full
        let now = Date()

        // Report level
        batcher.trackMetric(type: "battery", name: "level", value: Double(percentage), unit: "percent")

        // Report thermal state (iOS 11+)
        if #available(iOS 11.0, *) {
            let thermalState = ProcessInfo.processInfo.thermalState
            let tempEstimate: Double
            switch thermalState {
            case .nominal: tempEstimate = 30.0
            case .fair: tempEstimate = 35.0
            case .serious: tempEstimate = 40.0
            case .critical: tempEstimate = 45.0
            @unknown default: tempEstimate = 32.0
            }
            batcher.trackMetric(type: "battery", name: "temperature", value: tempEstimate, unit: "celsius")

            if thermalState == .serious || thermalState == .critical {
                batcher.trackEvent(name: "thermal_warning", data: [
                    "state": String(describing: thermalState),
                    "battery_level": String(format: "%.0f", percentage)
                ])
            }
        }

        // Calculate drain rate (only when not charging)
        if !isCharging, let prevLevel = lastLevel, let prevTime = lastSampleTime {
            let levelDelta = prevLevel - percentage
            let timeDeltaHours = now.timeIntervalSince(prevTime) / 3600.0
            if timeDeltaHours > 0.01 && levelDelta > 0 {
                let drainPerHour = Double(levelDelta) / timeDeltaHours
                if drainPerHour > 0 && drainPerHour < 100 {
                    batcher.trackMetric(type: "battery", name: "drain_rate",
                                       value: drainPerHour, unit: "percent_per_hour")
                }
            }
        }

        lastLevel = percentage
        lastSampleTime = now
    }

    func reportSessionSummary() {
        guard let startLevel = sessionStartLevel, let startTime = sessionStartTime else { return }
        let currentLevel = UIDevice.current.batteryLevel * 100
        guard currentLevel >= 0 else { return }

        let durationHours = Date().timeIntervalSince(startTime) / 3600.0
        guard durationHours > 0.01 else { return }

        let drain = startLevel - currentLevel
        let drainPerHour = drain > 0 ? Double(drain) / durationHours : 0

        batcher.trackEvent(name: "battery_session_summary", data: [
            "start_level": String(format: "%.0f", startLevel),
            "end_level": String(format: "%.0f", currentLevel),
            "drain_percent": String(format: "%.1f", drain),
            "drain_per_hour": String(format: "%.2f", drainPerHour),
            "duration_minutes": String(format: "%.0f", durationHours * 60)
        ])
    }

    @objc private func batteryLevelChanged() {
        let level = UIDevice.current.batteryLevel
        if level >= 0 && level < 0.1 {
            batcher.trackEvent(name: "battery_low", data: [
                "level": String(format: "%.0f", level * 100)
            ])
            ScoovaMonitor.shared.addBreadcrumb("Battery low: \(Int(level * 100))%", category: "system")
        }
    }

    @objc private func batteryStateChanged() {
        let state = UIDevice.current.batteryState
        switch state {
        case .charging:
            ScoovaMonitor.shared.addBreadcrumb("Charger connected", category: "system")
        case .unplugged:
            sampleBattery() // Reset drain tracking
            ScoovaMonitor.shared.addBreadcrumb("Charger disconnected", category: "system")
        default: break
        }
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}
