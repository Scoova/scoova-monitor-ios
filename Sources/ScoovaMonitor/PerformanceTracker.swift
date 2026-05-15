import Foundation
import Darwin

internal final class PerformanceTracker {
    private let batcher: EventBatcher
    private let processStartTime: Date

    init(batcher: EventBatcher) {
        self.batcher = batcher
        self.processStartTime = Self.resolveProcessStartTime()
    }

    /// Real process start time via sysctl(KERN_PROC_PID, getpid()).
    ///
    /// This must be the *process* start time. `ProcessInfo.systemUptime`
    /// gives system boot time instead — on a device that's been powered
    /// on for hours, subtracting that would report a cold start of
    /// however long the phone had been on, not the actual launch time.
    /// sysctl(KERN_PROC_PID) is the correct source.
    ///
    /// Falls back to "now" if sysctl ever fails — better to ship a tiny
    /// number than a bogus one.
    private static func resolveProcessStartTime() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let rc = mib.withUnsafeMutableBufferPointer { ptr -> Int32 in
            sysctl(ptr.baseAddress, UInt32(ptr.count), &info, &size, nil, 0)
        }
        guard rc == 0 else { return Date() }
        let sec = TimeInterval(info.kp_proc.p_starttime.tv_sec)
        let usec = TimeInterval(info.kp_proc.p_starttime.tv_usec) / 1_000_000
        return Date(timeIntervalSince1970: sec + usec)
    }

    func trackAppStart() {
        let startupMs = Date().timeIntervalSince(processStartTime) * 1000
        // Sanity floor — if sysctl returned "now" as a fallback, we'd
        // otherwise ship a sub-1ms value that's misleading on the
        // dashboard's startup percentile chart.
        let safeMs = max(1.0, startupMs)
        batcher.trackMetric(
            type: "app_start",
            name: "cold_start",
            value: safeMs,
            unit: "ms"
        )
    }

    func trackNetworkRequest(url: String, method: String, statusCode: Int, durationMs: Double) {
        batcher.trackMetric(
            type: "network",
            name: "http_request",
            value: durationMs,
            unit: "ms",
            url: url,
            method: method,
            statusCode: statusCode
        )
    }

    func trackCustomMetric(name: String, value: Double, unit: String) {
        batcher.trackMetric(
            type: "custom",
            name: name,
            value: value,
            unit: unit
        )
    }
}
