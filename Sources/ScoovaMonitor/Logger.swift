import Foundation

/// Scoova Monitor Logger — Structured event and debug logging.
///
/// Usage:
/// ```swift
/// let logger = ScoovaMonitor.shared.logger(tag: "payment")
///
/// logger.info("Payment started", data: ["amount": "29.99", "currency": "USD"])
/// logger.warning("Retry payment", data: ["attempt": "2"])
/// logger.error("Payment failed", data: ["error_code": "card_declined"])
/// logger.debug("Payment flow details")
///
/// // Or use the static shorthand:
/// ScoovaMonitor.shared.log(tag: "payment", level: .info, message: "Payment completed")
/// ```
public final class ScoovaLogger {

    public enum Level: String {
        case debug, info, warning, error
    }

    private let tag: String

    internal init(tag: String) {
        self.tag = tag
    }

    public func debug(_ message: String, data: [String: String]? = nil) { log(.debug, message, data: data) }
    public func info(_ message: String, data: [String: String]? = nil) { log(.info, message, data: data) }
    public func warning(_ message: String, data: [String: String]? = nil) { log(.warning, message, data: data) }
    public func error(_ message: String, data: [String: String]? = nil) { log(.error, message, data: data) }

    public func log(_ level: Level, _ message: String, data: [String: String]? = nil) {
        guard ScoovaMonitor.shared.isInitialized else { return }

        let payload: [String: Any?] = [
            "level": level.rawValue,
            "tag": tag,
            "message": PrivacyGuard.sanitizeMessage(message),
            "data": PrivacyGuard.sanitizeEventData(data),
            "userId": PrivacyGuard.hashUserId(DeviceContext.shared.userId),
            "sessionId": DeviceContext.shared.sessionId,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        LogQueue.shared.enqueue(payload.compactMapValues { $0 })

        // Breadcrumb for crash context
        ScoovaMonitor.shared.crashHandler?.addBreadcrumb(
            message: "[\(level.rawValue)] [\(tag)] \(message)", category: "log"
        )

        // Print to console in debug
        #if DEBUG
        let emoji: String
        switch level {
        case .debug: emoji = "🔍"
        case .info: emoji = "ℹ️"
        case .warning: emoji = "⚠️"
        case .error: emoji = "❌"
        }
        print("\(emoji) [Scoova:\(tag)] \(message)")
        #endif
    }
}

/// Internal log queue — batches logs and sends to server.
internal final class LogQueue {
    static let shared = LogQueue()

    private let diskQueue = DiskQueue(name: "logs", maxSize: 2000)
    private let lock = NSLock()

    private init() {}

    func enqueue(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        diskQueue.append(str)

        if diskQueue.count() >= 50 { flush() }
    }

    func flush() {
        let batch = diskQueue.take(100)
        guard !batch.isEmpty else { return }

        let logs = batch.compactMap { str -> [String: Any]? in
            guard let data = str.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        let payload: [String: Any] = ["logs": logs]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            diskQueue.appendAll(batch)
            return
        }

        guard let url = URL(string: "\(ScoovaMonitor.shared.endpoint)/v1/ingest/logs/batch") else {
            diskQueue.appendAll(batch)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ScoovaMonitor.shared.apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = jsonData
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error != nil || !(200...299).contains(statusCode) {
                self?.diskQueue.appendAll(batch) // Re-queue
            }
        }.resume()
    }
}
