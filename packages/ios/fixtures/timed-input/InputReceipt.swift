import SwiftUI
import UIKit
import ObjectiveC

/// Test-host evidence only. Observe delivery without recognizing gestures,
/// injecting input, replaying callbacks, or changing the receiver's state.
enum InputReceipt {
    static private(set) var callbacks: [String] = []
    private static var events: [[String: Any]] = []
    private static var cachedChunks: [String]?
    private static var phases: [String: Int] = [:]
    private static let installed: Void = {
        let original = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:)))!
        let observer = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.recordTimedInput(_:)))!
        method_exchangeImplementations(original, observer)
    }()

    static func install() { _ = installed }

    static func receive(_ event: UIEvent, in window: UIWindow) {
        for touch in event.allTouches ?? [] where touch.window === window {
            let phase: String
            switch touch.phase {
            case .began: phase = "began"
            case .ended: phase = "ended"
            case .cancelled: phase = "cancelled"
            default: continue
            }
            phases[phase, default: 0] += 1
            let point = touch.location(in: window)
            append([
                "kind": "touch", "phase": phase, "timestamp": touch.timestamp,
                "deliveredAt": ProcessInfo.processInfo.systemUptime,
                "x": point.x, "y": point.y, "keyWindow": window.isKeyWindow,
                "applicationState": UIApplication.shared.applicationState.rawValue,
                "view": touch.view.map { String(describing: type(of: $0)) } ?? "nil",
            ])
        }
    }

    static func callback(_ name: String, before: [String], after: [String]) {
        callbacks.append(name)
        append(["kind": "callback", "name": name, "before": before, "after": after,
                "deliveredAt": ProcessInfo.processInfo.systemUptime])
    }

    private static func append(_ event: [String: Any]) {
        // The canonical record has 48 touch phases and 24 callbacks. Keep the
        // first observations if a broken host produces an unbounded stream.
        if events.count < 256 {
            events.append(event)
            cachedChunks = nil
        }
    }

    static var touchCounts: String {
        "began=\(phases["began", default: 0]);ended=\(phases["ended", default: 0]);cancelled=\(phases["cancelled", default: 0])"
    }

    static var journalChunks: [String] {
        if let cachedChunks { return cachedChunks }
        guard let data = try? JSONSerialization.data(withJSONObject: events, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return ["invalid receipt"] }
        // XCTest caps each snapshot value at 512 characters. Chunk before
        // crossing that boundary; joining the numbered values restores JSON.
        var chunks: [String] = []
        var remaining = text[...]
        while !remaining.isEmpty {
            chunks.append(String(remaining.prefix(400)))
            remaining = remaining.dropFirst(400)
        }
        cachedChunks = chunks
        return chunks
    }
}

private extension UIWindow {
    @objc func recordTimedInput(_ event: UIEvent) {
        InputReceipt.receive(event, in: self)
        // After exchange this invokes UIKit's original sendEvent exactly once.
        recordTimedInput(event)
    }
}

/// Values are read on demand when XCTest takes a snapshot. Recording
/// touches does not trigger SwiftUI renders or synchronous disk/network I/O.
struct InputReceiptView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { ReceiptView() }
    func updateUIView(_ view: UIView, context: Context) {}

    private final class Value: UIAccessibilityElement {
        let read: () -> String
        init(_ id: String, container: UIView, read: @escaping () -> String) {
            self.read = read
            super.init(accessibilityContainer: container)
            accessibilityIdentifier = id
            accessibilityLabel = id
            accessibilityFrameInContainerSpace = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        override var accessibilityValue: String? {
            get { read() }
            set {}
        }
    }

    private final class ReceiptView: UIView {
        private var items: [Int: Value] = [:]
        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        override func accessibilityElementCount() -> Int { 2 + InputReceipt.journalChunks.count }
        override func accessibilityElement(at index: Int) -> Any? {
            guard index >= 0, index < accessibilityElementCount() else { return nil }
            if let item = items[index] { return item }
            let item: Value
            switch index {
            case 0: item = Value("native-touch-counts", container: self) { InputReceipt.touchCounts }
            case 1: item = Value("received-callbacks", container: self) { InputReceipt.callbacks.joined(separator: ",") }
            default:
                let chunk = index - 2
                item = Value("native-input-journal-\(chunk)", container: self) {
                    let chunks = InputReceipt.journalChunks
                    return chunk < chunks.count ? chunks[chunk] : ""
                }
            }
            items[index] = item
            return item
        }
        override func index(ofAccessibilityElement element: Any) -> Int {
            items.first(where: { $0.value === (element as? Value) })?.key ?? NSNotFound
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
