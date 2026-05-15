import Foundation
import UIKit

/// Lightweight session replay via view tree snapshots.
/// Captures UI structure (not pixels) — privacy-safe, tiny payload.
internal final class SessionReplay {
    static let shared = SessionReplay()

    struct ViewSnapshot: Codable {
        let timestamp: TimeInterval
        let screen: String
        let type: String // screen_enter, tap, scroll
        let tree: ViewNode?
        let targetType: String?
    }

    struct ViewNode: Codable {
        let type: String
        let id: String?
        let bounds: String?
        let text: String? // placeholder only, never real content
        let visible: Bool
        let children: [ViewNode]?
    }

    private var snapshots: [ViewSnapshot] = []
    private let maxSnapshots = 100
    private let lock = NSLock()

    private init() {}

    func captureSnapshot(viewController: UIViewController, type: String = "screen_enter") {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let view = viewController.view else { return }

            let tree = self.buildViewTree(view: view, depth: 0, maxDepth: 8)
            let snapshot = ViewSnapshot(
                timestamp: Date().timeIntervalSince1970,
                screen: String(describing: Swift.type(of: viewController)),
                type: type,
                tree: tree,
                targetType: nil
            )

            self.lock.lock()
            if self.snapshots.count >= self.maxSnapshots { self.snapshots.removeFirst() }
            self.snapshots.append(snapshot)
            self.lock.unlock()
        }
    }

    func flushSnapshots() {
        lock.lock()
        guard !snapshots.isEmpty else { lock.unlock(); return }
        let batch = snapshots
        snapshots.removeAll()
        lock.unlock()

        if let data = try? JSONEncoder().encode(batch),
           let jsonStr = String(data: data, encoding: .utf8) {
            ScoovaMonitor.shared.eventBatcher?.trackEvent(name: "session_replay", data: [
                "snapshot_count": String(batch.count),
                "snapshots": String(jsonStr.prefix(50_000))
            ])
        }
    }

    private func buildViewTree(view: UIView, depth: Int, maxDepth: Int) -> ViewNode {
        let type = String(describing: Swift.type(of: view))
        let id = view.accessibilityIdentifier
        let frame = view.frame
        let bounds = "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"

        // Never capture actual text — privacy safe
        var textPlaceholder: String? = nil
        if let label = view as? UILabel {
            textPlaceholder = "[text:\(label.text?.count ?? 0)ch]"
        } else if let field = view as? UITextField {
            textPlaceholder = "[input:\(field.text?.count ?? 0)ch]"
        }

        let children: [ViewNode]? = if depth < maxDepth && !view.subviews.isEmpty {
            view.subviews
                .filter { !$0.isHidden && $0.alpha > 0 }
                .map { buildViewTree(view: $0, depth: depth + 1, maxDepth: maxDepth) }
        } else {
            nil
        }

        return ViewNode(
            type: type,
            id: id,
            bounds: bounds,
            text: textPlaceholder,
            visible: !view.isHidden,
            children: children
        )
    }
}
