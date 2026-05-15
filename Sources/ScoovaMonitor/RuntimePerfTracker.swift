import Foundation
import Darwin
#if canImport(QuartzCore)
import QuartzCore
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Continuous runtime performance metrics. Two streams:
///
///  - **frame_rate** — `CADisplayLink` on the main runloop counts vsync
///    ticks. Every 5 seconds we emit `fps` + `dropped_frames_percent`.
///    Auto-pauses on `UIApplication.didEnterBackground` so we don't
///    keep the CPU awake for nothing.
///
///  - **memory** — `task_info(TASK_VM_INFO_64)` reads the process's
///    `phys_footprint` on a 30-second timer. Same cadence Android's
///    `Debug.getMemoryInfo()` uses, so the dashboard's memory chart
///    has comparable resolution across platforms.
///
/// Both run on background-friendly schedulers and do nothing while the
/// app is suspended. Cost in foreground is dominated by the
/// CADisplayLink callback (~free — vsync would fire anyway). Memory
/// poll is two Mach calls per 30 s — negligible.
internal final class RuntimePerfTracker {

    private let batcher: EventBatcher

    // MARK: Frame rate
    private var displayLink: CADisplayLink?
    private var frameTickCount: Int = 0
    private var lastWindowStart: CFTimeInterval = 0
    private let frameWindowSeconds: CFTimeInterval = 5.0
    /// Vsync target (60 on most devices, 120 on ProMotion). Refreshed on
    /// each CADisplayLink callback so we adapt to the actual hardware.
    private var targetFps: Double = 60.0

    // MARK: Memory
    private var memoryTimer: DispatchSourceTimer?
    private let memoryQueue = DispatchQueue(label: "com.scoova.monitor.memory", qos: .utility)
    private let memoryIntervalSeconds: Int = 30

    init(batcher: EventBatcher) {
        self.batcher = batcher
    }

    func start() {
        startFrameRate()
        startMemorySampling()
        observeAppLifecycle()
    }

    func stop() {
        stopFrameRate()
        stopMemorySampling()
    }

    // MARK: - Frame rate

    private func startFrameRate() {
        // CADisplayLink must be created and added on the main thread.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(self.onDisplayTick(_:)))
            // .common so it keeps firing during scroll gestures (which would
            // otherwise switch the runloop to .tracking and pause us).
            link.add(to: .main, forMode: .common)
            self.displayLink = link
            self.lastWindowStart = CACurrentMediaTime()
        }
    }

    private func stopFrameRate() {
        DispatchQueue.main.async { [weak self] in
            self?.displayLink?.invalidate()
            self?.displayLink = nil
        }
    }

    @objc private func onDisplayTick(_ link: CADisplayLink) {
        frameTickCount += 1

        // ProMotion devices report up to 120Hz; non-ProMotion 60Hz. Read
        // every tick — preferredFramesPerSecond can change at runtime.
        let preferred = Double(link.preferredFramesPerSecond)
        if preferred > 0 { targetFps = preferred }
        else if #available(iOS 15.0, *) {
            let pref = link.preferredFrameRateRange.preferred ?? 0
            if pref > 0 { targetFps = Double(pref) }
        }

        let now = CACurrentMediaTime()
        let elapsed = now - lastWindowStart
        guard elapsed >= frameWindowSeconds else { return }

        let fps = Double(frameTickCount) / elapsed
        let expectedFrames = targetFps * elapsed
        let droppedPct = max(0.0, min(100.0, (1.0 - fps / targetFps) * 100.0))

        // Floor fps + ceil drop% so a paused window doesn't ship absurd
        // numbers (a backgrounded app emits 0 ticks).
        if expectedFrames > 0 {
            batcher.trackMetric(type: "frame_rate",
                                name: "fps",
                                value: fps.clamped(to: 0...targetFps),
                                unit: "fps")
            batcher.trackMetric(type: "frame_rate",
                                name: "dropped_frames_percent",
                                value: droppedPct,
                                unit: "percent")
        }

        frameTickCount = 0
        lastWindowStart = now
    }

    // MARK: - Memory

    private func startMemorySampling() {
        let timer = DispatchSource.makeTimerSource(queue: memoryQueue)
        // First sample immediately so the dashboard isn't blank for
        // 30 s after launch.
        timer.schedule(deadline: .now(), repeating: .seconds(memoryIntervalSeconds))
        timer.setEventHandler { [weak self] in self?.sampleMemory() }
        timer.resume()
        memoryTimer = timer
    }

    private func stopMemorySampling() {
        memoryTimer?.cancel()
        memoryTimer = nil
    }

    private func sampleMemory() {
        guard let bytes = Self.physFootprintBytes() else { return }
        batcher.trackMetric(type: "memory",
                            name: "used_bytes",
                            value: Double(bytes),
                            unit: "bytes")
    }

    /// Reads the process's physical memory footprint via task_info.
    /// Returns nil on the rare path where the syscall fails.
    static func physFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size /
                                           MemoryLayout<integer_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    // MARK: - Lifecycle

    private func observeAppLifecycle() {
        #if canImport(UIKit)
        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(onBackground),
                       name: UIApplication.didEnterBackgroundNotification,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(onForeground),
                       name: UIApplication.willEnterForegroundNotification,
                       object: nil)
        #endif
    }

    @objc private func onBackground() {
        // Pause CADisplayLink — keeping it active in background is a
        // pointless battery drain (no frames are rendered). Memory
        // sampling can keep running; phys_footprint is meaningful even
        // when the app is suspended-but-resident.
        DispatchQueue.main.async { [weak self] in
            self?.displayLink?.isPaused = true
        }
    }

    @objc private func onForeground() {
        DispatchQueue.main.async { [weak self] in
            self?.displayLink?.isPaused = false
            self?.lastWindowStart = CACurrentMediaTime()
            self?.frameTickCount = 0
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
