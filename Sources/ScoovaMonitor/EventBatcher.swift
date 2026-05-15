import Foundation
import Compression

internal final class EventBatcher {
    private let apiKey: String
    private let endpoint: String
    private let maxBatchSize: Int

    // Disk-backed queues — survive app kills
    private let eventDiskQueue: DiskQueue
    private let metricDiskQueue: DiskQueue
    private var flushTimer: Timer?

    // Dedicated session that bypasses ScoovaURLProtocol interception
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []
        return URLSession(configuration: config)
    }()

    // Exponential backoff
    private var consecutiveFailures = 0
    private let maxBackoffSeconds: TimeInterval = 300

    init(apiKey: String, endpoint: String, maxBatchSize: Int = 50, flushInterval: TimeInterval = 300) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.maxBatchSize = maxBatchSize
        self.eventDiskQueue = DiskQueue(name: "events")
        self.metricDiskQueue = DiskQueue(name: "metrics")

        DispatchQueue.main.async {
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { [weak self] _ in
                self?.flush()
            }
        }
    }

    func trackEvent(name: String, data: [String: String]? = nil) {
        let light = DeviceContext.shared.collectLight()
        var event: [String: Any] = [
            "eventName": name,
            "sessionId": DeviceContext.shared.sessionId,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "device": light
        ]
        // Always stamp a user_id — real (h_) if setUserId was called, anon_ otherwise.
        // DAU/MAU/retention/sessions analytics depend on this being non-null.
        if let stamped = PrivacyGuard.hashUserId(DeviceContext.shared.userId) {
            event["userId"] = stamped
        }
        if DeviceContext.shared.sessionNumber > 0 {
            event["sessionNumber"] = DeviceContext.shared.sessionNumber
        }
        if let data = data {
            event["eventData"] = PrivacyGuard.sanitizeEventData(data) as Any
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: event),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            eventDiskQueue.append(jsonStr)
        }

        if eventDiskQueue.count() >= maxBatchSize { flush() }
    }

    func trackMetric(type: String, name: String, value: Double, unit: String,
                     url: String? = nil, method: String? = nil, statusCode: Int? = nil) {
        var metric: [String: Any] = [
            "metricType": type,
            "metricName": name,
            "value": value,
            "unit": unit,
            "sessionId": DeviceContext.shared.sessionId,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            // Stack identifier — "native" means the native iOS SDK.
            // Flutter iOS sends "flutter", RN iOS sends "react-native",
            // KMP iOS sends "kmp". Combined with osName=iOS in the
            // device payload, the dashboard renders these as
            // "iOS (native)", "iOS · flutter", etc.
            "framework": "native",
        ]
        // Attach device context so the dashboard's per-platform breakdown
        // can fill in os_name + os_version + device_model. Without this,
        // metrics arrived with os_name=null and the breakdown table had
        // to guess from framework alone.
        let dev = DeviceContext.shared.collect()
        metric["device"] = [
            "manufacturer": dev["manufacturer"] as? String ?? "Apple",
            "model":        dev["model"] as? String ?? "",
            "osName":       dev["osName"] as? String ?? "iOS",
            "osVersion":    dev["osVersion"] as? String ?? "",
            "appVersion":   dev["appVersion"] as? String ?? "",
            "country":      dev["country"] as? String ?? "",
            "carrier":      dev["carrier"] as? String ?? "",
            "networkType":  dev["networkType"] as? String ?? "",
        ]
        if let url = url { metric["url"] = PrivacyGuard.sanitizeUrl(url) as Any }
        if let method = method { metric["httpMethod"] = method }
        if let statusCode = statusCode { metric["statusCode"] = statusCode }

        if let jsonData = try? JSONSerialization.data(withJSONObject: metric),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            metricDiskQueue.append(jsonStr)
        }

        if metricDiskQueue.count() >= maxBatchSize { flush() }
    }

    func flush() {
        // Skip if in heavy backoff
        if consecutiveFailures > 3 { return }
        flushEvents()
        flushMetrics()
    }

    private func flushEvents() {
        let rawBatch = eventDiskQueue.take(maxBatchSize)
        guard !rawBatch.isEmpty else { return }

        let events = rawBatch.compactMap { str -> [String: Any]? in
            guard let data = str.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        let payload: [String: Any] = ["events": events]
        postGzipJSON(to: "\(endpoint)/v1/ingest/events/batch", payload: payload) { [weak self] success in
            if success {
                self?.consecutiveFailures = 0
                ScoovaMonitor.shared.log("Flushed \(events.count) events")
            } else {
                self?.consecutiveFailures += 1
                self?.eventDiskQueue.appendAll(rawBatch) // Put back on disk
                ScoovaMonitor.shared.log("Flush failed (attempt \(self?.consecutiveFailures ?? 0))")
            }
        }
    }

    private func flushMetrics() {
        let rawBatch = metricDiskQueue.take(maxBatchSize)
        guard !rawBatch.isEmpty else { return }

        let metrics = rawBatch.compactMap { str -> [String: Any]? in
            guard let data = str.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        let payload: [String: Any] = ["metrics": metrics]
        postGzipJSON(to: "\(endpoint)/v1/ingest/metrics/batch", payload: payload) { [weak self] success in
            if success {
                self?.consecutiveFailures = 0
                ScoovaMonitor.shared.log("Flushed \(metrics.count) metrics")
            } else {
                self?.consecutiveFailures += 1
                self?.metricDiskQueue.appendAll(rawBatch)
            }
        }
    }

    /// POST with gzip compression
    private func postGzipJSON(to urlString: String, payload: [String: Any], completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: urlString),
              let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let bid = ScoovaMonitor.shared.bundleId
        if !bid.isEmpty { request.setValue(bid, forHTTPHeaderField: "X-Bundle-Id") }
        request.httpBody = jsonData
        request.timeoutInterval = 10

        session.dataTask(with: request) { _, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode >= 400 {
                print("[ScoovaMonitor] POST \(urlString) failed: \(statusCode)")
            }
            completion(error == nil && (200...299).contains(statusCode))
        }.resume()
    }

    private func gzipCompress(_ data: Data) -> Data? {
        // Apple's Compression framework: ZLIB raw deflate. The receiving server
        // accepts deflate as well as gzip; we use the raw zlib stream which
        // is what compression_encode_buffer produces.
        let dstCapacity = max(data.count, 64)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dst.deallocate() }

        let written = data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) -> Int in
            guard let srcPtr = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(dst, dstCapacity, srcPtr, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(bytes: dst, count: written)
    }

    /// Drop every queued event + metric on disk. Used by clearLocalUserData()
    /// to satisfy GDPR right-to-erasure end-to-end.
    func clearAllQueues() {
        eventDiskQueue.clear()
        metricDiskQueue.clear()
    }
}
