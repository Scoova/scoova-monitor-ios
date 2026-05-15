import Foundation
import Network

/// Monitors network state using NWPathMonitor (Fix #8)
/// Also provides automatic URLSession tracking (Fix #10)
internal final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.scoova.monitor.network", qos: .utility)

    private(set) var currentType: String = "unknown"
    private(set) var isConnected: Bool = true

    private init() {}

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.isConnected = path.status == .satisfied

            if path.usesInterfaceType(.wifi) {
                self?.currentType = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                self?.currentType = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                self?.currentType = "ethernet"
            } else {
                self?.currentType = path.status == .satisfied ? "other" : "none"
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}

// MARK: - Auto URL tracking via URLProtocol (Fix #10)

/// Intercepts all URLSession requests to automatically track network performance.
/// Register with: URLProtocol.registerClass(ScoovaURLProtocol.self)
public final class ScoovaURLProtocol: URLProtocol {
    private static let handledKey = "ScoovaMonitorHandled"
    private var dataTask: URLSessionDataTask?
    private var startTime: Date?
    private var responseData = Data()

    override public class func canInit(with request: URLRequest) -> Bool {
        // Don't intercept our own requests or already-handled requests
        guard URLProtocol.property(forKey: handledKey, in: request) == nil else { return false }
        guard let host = request.url?.host, !host.contains("scoo-va.info") else { return false }
        return true
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        startTime = Date()
        let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        dataTask = session.dataTask(with: mutable as URLRequest)
        dataTask?.resume()
    }

    override public func stopLoading() {
        dataTask?.cancel()
    }
}

extension ScoovaURLProtocol: URLSessionDataDelegate {
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
        client?.urlProtocol(self, didLoad: data)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let duration = startTime.map { Date().timeIntervalSince($0) * 1000 } ?? 0
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let url = task.originalRequest?.url?.absoluteString ?? ""
        let method = task.originalRequest?.httpMethod ?? "GET"

        // Track the network request
        if ScoovaMonitor.shared.isInitialized {
            ScoovaMonitor.shared.trackNetworkRequest(
                url: url, method: method,
                statusCode: statusCode, durationMs: duration
            )
        }

        if let error = error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
