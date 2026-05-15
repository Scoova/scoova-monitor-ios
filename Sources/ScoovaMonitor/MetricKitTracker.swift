import Foundation
import MetricKit
#if canImport(UIKit)
import UIKit
#endif

/// MetricKit integration (Fix #36) — Collects Apple's built-in performance diagnostics.
/// Available on iOS 13+, provides 24h aggregated metrics for free.
/// Also handles watchdog termination detection (Fix #37).
@available(iOS 13.0, *)
internal final class MetricKitTracker: NSObject, MXMetricManagerSubscriber {

    static let shared = MetricKitTracker()

    private override init() {
        super.init()
    }

    func start() {
        MXMetricManager.shared.add(self)
        checkForWatchdogTermination()
        ScoovaMonitor.shared.log("MetricKit tracker started")
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            processPayload(payload)
        }
    }

    @available(iOS 14.0, *)
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            processDiagnostic(payload)
        }
    }

    // MARK: - Metric Processing

    private func processPayload(_ payload: MXMetricPayload) {
        guard let batcher = ScoovaMonitor.shared.eventBatcher else { return }

        // App launch time
        if let launchMetrics = payload.applicationLaunchMetrics {
            if let resumeTime = launchMetrics.histogrammedTimeToFirstDraw.bucketEnumerator.allObjects.first {
                batcher.trackMetric(type: "metrickit", name: "time_to_first_draw",
                    value: 0, unit: "ms") // Simplified — real impl parses histogram
            }
        }

        // Memory — peakMemoryUsage is a Measurement<UnitInformationStorage>
        if let memoryMetrics = payload.memoryMetrics {
            let peakMB = memoryMetrics.peakMemoryUsage.converted(to: .bytes).value / 1_048_576.0
            batcher.trackMetric(type: "metrickit", name: "peak_memory",
                value: peakMB, unit: "MB")
        }

        // Cellular data
        if let cellConditions = payload.cellularConditionMetrics {
            batcher.trackEvent(name: "metrickit_cellular", data: [
                "bars_histogram": "collected"
            ])
        }

        // Disk writes — cumulativeLogicalWrites is a Measurement<UnitInformationStorage>
        if let diskIO = payload.diskIOMetrics {
            let writesMB = diskIO.cumulativeLogicalWrites.converted(to: .bytes).value / 1_048_576.0
            batcher.trackMetric(type: "metrickit", name: "cumulative_disk_writes",
                value: writesMB, unit: "MB")
        }

        ScoovaMonitor.shared.log("Processed MetricKit payload")
    }

    @available(iOS 14.0, *)
    private func processDiagnostic(_ payload: MXDiagnosticPayload) {
        guard let batcher = ScoovaMonitor.shared.eventBatcher else { return }

        // Crash diagnostics from MetricKit
        if let crashDiagnostics = payload.crashDiagnostics {
            for crash in crashDiagnostics {
                batcher.trackEvent(name: "metrickit_crash", data: [
                    "signal": crash.signal?.description ?? "unknown",
                    "exception_type": crash.exceptionType?.description ?? "unknown",
                    "termination_reason": crash.terminationReason ?? "unknown"
                ])
            }
        }

        // Hang diagnostics — route to crash_reports as ANR (matches Android
        // parity and the iOS watchdog above). MetricKit gives us a real
        // symbolicated call tree from the OS, so we ship that instead of
        // the placeholder our in-process watchdog uses.
        if let hangDiagnostics = payload.hangDiagnostics {
            for hang in hangDiagnostics {
                let durationSeconds = hang.hangDuration.converted(to: .seconds).value
                let stack = hang.callStackTree.jsonRepresentation()
                let stackStr = String(data: stack, encoding: .utf8) ?? "(MetricKit call tree unavailable)"
                ScoovaMonitor.shared.crashHandler?.reportHang(
                    durationThresholdSeconds: durationSeconds,
                    source: "MetricKit hangDiagnostic",
                    mainThreadStack: stackStr
                )
            }
        }

        // CPU exceptions
        if let cpuDiagnostics = payload.cpuExceptionDiagnostics {
            for cpu in cpuDiagnostics {
                batcher.trackEvent(name: "metrickit_cpu_exception", data: [
                    "total_cpu_time": cpu.totalCPUTime.description,
                    "total_sampled_time": cpu.totalSampledTime.description
                ])
            }
        }

        ScoovaMonitor.shared.log("Processed MetricKit diagnostics")
    }

    // MARK: - Watchdog Termination Detection (Fix #37)

    /// Detects if the app was killed by the watchdog (background termination)
    /// by checking if the last session ended cleanly.
    private func checkForWatchdogTermination() {
        let defaults = UserDefaults(suiteName: "com.scoova.monitor") ?? .standard
        let lastCleanExit = defaults.bool(forKey: "clean_exit")
        let hadPreviousSession = defaults.bool(forKey: "had_session")

        if hadPreviousSession && !lastCleanExit {
            // App was terminated without clean exit — likely watchdog or OOM
            ScoovaMonitor.shared.eventBatcher?.trackEvent(name: "abnormal_termination", data: [
                "type": "watchdog_or_oom",
                "previous_session": "unclean_exit"
            ])
            ScoovaMonitor.shared.crashHandler?.addBreadcrumb(
                message: "Previous session terminated abnormally (watchdog/OOM)", category: "system"
            )
        }

        // Mark session as started (unclean)
        defaults.set(false, forKey: "clean_exit")
        defaults.set(true, forKey: "had_session")

        // Register for clean exit
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            defaults.set(true, forKey: "clean_exit")
        }
    }
}
