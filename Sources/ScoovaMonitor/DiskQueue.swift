import Foundation

/// Persistent disk-backed queue. Events survive app kills and crashes.
internal final class DiskQueue {
    private let fileURL: URL
    private let maxSize: Int
    private let lock = NSLock()

    init(name: String, maxSize: Int = 1000) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.fileURL = dir.appendingPathComponent("scoova_queue_\(name).jsonl")
        self.maxSize = maxSize
    }

    func append(_ json: String) {
        lock.lock()
        defer { lock.unlock() }
        do {
            var lines = readLines()
            if lines.count >= maxSize {
                lines.removeFirst(lines.count - maxSize + 1)
            }
            lines.append(json)
            try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {}
    }

    func appendAll(_ jsons: [String]) {
        guard !jsons.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            var lines = readLines()
            lines.append(contentsOf: jsons)
            while lines.count > maxSize { lines.removeFirst() }
            try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {}
    }

    func take(_ count: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        do {
            var lines = readLines()
            guard !lines.isEmpty else { return [] }
            let batch = Array(lines.prefix(count))
            lines.removeFirst(min(count, lines.count))
            try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            return batch
        } catch {
            return []
        }
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return readLines().count
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func readLines() -> [String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return content.components(separatedBy: "\n").filter { !$0.isEmpty }
    }
}
