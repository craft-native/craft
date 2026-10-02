import Foundation
import JavaScriptCore
import SwiftUI
import UIKit

/// A WebView-free host for the first stx-native vertical slice. The bundled
/// JavaScript sends whole, compiled view trees to UIKit and receives control
/// events and Craft API replies through JavaScriptCore.
struct CraftNativeScreen: UIViewControllerRepresentable {
    let config: CraftConfig

    func makeUIViewController(context: Context) -> CraftNativeScreenController {
        CraftNativeScreenController(config: config)
    }

    func updateUIViewController(_ controller: CraftNativeScreenController, context: Context) {}
}

final class CraftNativeScreenController: UIViewController {
    private let config: CraftConfig
    private let jsContext = JSContext()!
    private let rootStack = UIStackView()
    private var handlers: [ObjectIdentifier: String] = [:]
    private var textFields: [String: UITextField] = [:]

    init(config: CraftConfig) {
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = config.resolvedBackgroundColor
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.distribution = .fill
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            rootStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        ])
        setupJavaScript()
        loadBundle()
    }

    private func setupJavaScript() {
        jsContext.exceptionHandler = { _, exception in
            NSLog("[craft native] JavaScript exception: %@", exception?.toString() ?? "unknown")
        }
        let postMessage: @convention(block) (String) -> Void = { [weak self] json in
            self?.receive(json)
        }
        jsContext.setObject(postMessage, forKeyedSubscript: "craftNativePostMessage" as NSString)
        jsContext.evaluateScript("""
            globalThis.__stxNativeCallback = null;
            globalThis.__stxNativeBridge = {
                postMessage: function(message) { craftNativePostMessage(message); },
                onMessage: function(callback) { globalThis.__stxNativeCallback = callback; }
            };
            globalThis.console = {
                log: function() {}, warn: function() {}, error: function() {}
            };
        """)
    }

    private func loadBundle() {
        guard let url = Bundle.main.url(forResource: "native-screen", withExtension: "js", subdirectory: "dist")
            ?? Bundle.main.url(forResource: "native-screen", withExtension: "js"),
            let script = try? String(contentsOf: url, encoding: .utf8) else {
            showError("Missing dist/native-screen.js. Compile a .stx screen with stx-native first.")
            return
        }
        jsContext.evaluateScript(script)
    }

    private func showError(_ message: String) {
        let label = UILabel()
        label.numberOfLines = 0
        label.textColor = .systemRed
        label.textAlignment = .center
        label.text = message
        rootStack.addArrangedSubview(label)
        NSLog("[craft native] %@", message)
    }

    private func receive(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String,
              let payload = message["payload"] as? [String: Any] else { return }

        switch type {
        case "RENDER":
            guard let document = payload["document"] as? [String: Any] else { return }
            render(document)
        case "API_REQUEST":
            guard let id = message["id"] as? String else { return }
            let args = payload["args"] as? [Any] ?? []
            let route: (action: String, body: [String: Any])?
            switch (payload["module"] as? String, payload["method"] as? String) {
            case ("Device", "getInfo"):
                route = ("getDeviceInfo", [:])
            case ("Haptics", "impact"):
                route = ("haptic", ["style": args.first ?? NSNull()])
            case ("Clipboard", "write"):
                route = ("clipboardWrite", ["text": args.first ?? NSNull()])
            case ("Clipboard", "read"):
                route = ("clipboardRead", [:])
            default:
                route = nil
            }
            guard let route = route,
                  let answer = CraftNativeActions.perform(action: route.action, body: route.body, config: config) else {
                send(type: "API_ERROR", payload: ["requestId": id, "code": "UNKNOWN_ACTION", "message": "Unsupported native API"], correlationId: id)
                return
            }
            switch answer {
            case .success(let data):
                send(type: "API_RESPONSE", payload: ["requestId": id, "data": data], correlationId: id)
            case .failure(let error):
                send(type: "API_ERROR", payload: ["requestId": id, "code": error.code, "message": error.message], correlationId: id)
            }
        default:
            break
        }
    }

    private func render(_ document: [String: Any]) {
        // Rebuilding the tiny tree keeps the first slice deterministic. Keep
        // the active field and cursor across renders so typing does not drop
        // the keyboard when its onChange handler updates another Text node.
        let focused = textFields.first { $0.value.isFirstResponder }
        let focusedText = focused?.value.text
        let cursor = focused.flatMap { pair -> Int? in
            guard let range = pair.value.selectedTextRange else { return nil }
            return pair.value.offset(from: pair.value.beginningOfDocument, to: range.start)
        }
        rootStack.arrangedSubviews.forEach { child in
            rootStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        handlers.removeAll()
        textFields.removeAll()
        rootStack.addArrangedSubview(makeView(document, path: "root"))
        if let key = focused?.key, let field = textFields[key] {
            if let focusedText = focusedText { field.text = focusedText }
            field.becomeFirstResponder()
            if let cursor = cursor,
               let position = field.position(from: field.beginningOfDocument, offset: min(cursor, field.text?.count ?? 0)) {
                field.selectedTextRange = field.textRange(from: position, to: position)
            }
        }
    }

    private func makeView(_ node: [String: Any], path: String) -> UIView {
        let type = node["type"] as? String ?? "View"
        let props = node["props"] as? [String: Any] ?? [:]
        let style = node["style"] as? [String: Any] ?? [:]
        let events = node["events"] as? [String: String] ?? [:]
        let children = node["children"] as? [Any] ?? []
        let key = node["key"] as? String ?? props["testID"] as? String ?? path
        let result: UIView

        switch type {
        case "Text":
            let label = UILabel()
            label.numberOfLines = 0
            label.text = children.compactMap { $0 as? String }.joined()
            label.textColor = color(style["color"]) ?? .label
            if let size = number(style["fontSize"]) {
                label.font = .systemFont(ofSize: size)
            }
            result = label
        case "Button":
            let button = UIButton(type: .system)
            button.setTitle(props["title"] as? String ?? children.compactMap { $0 as? String }.joined(), for: .normal)
            button.addTarget(self, action: #selector(buttonPressed(_:)), for: .touchUpInside)
            if let handler = events["onPress"] ?? events["onClick"] {
                handlers[ObjectIdentifier(button)] = handler
            }
            result = button
        case "TextInput":
            let field = UITextField()
            field.borderStyle = .roundedRect
            field.placeholder = props["placeholder"] as? String
            field.text = props["value"] as? String
            field.addTarget(self, action: #selector(textChanged(_:)), for: .editingChanged)
            if let handler = events["onChange"] ?? events["onChangeText"] {
                handlers[ObjectIdentifier(field)] = handler
            }
            textFields[key] = field
            result = field
        default:
            let stack = UIStackView()
            stack.axis = style["flexDirection"] as? String == "row" ? .horizontal : .vertical
            stack.alignment = .fill
            stack.distribution = .fill
            stack.spacing = number(style["gap"]) ?? 0
            let padding = number(style["padding"]) ?? 0
            stack.layoutMargins = UIEdgeInsets(
                top: number(style["paddingTop"]) ?? padding,
                left: number(style["paddingLeft"]) ?? padding,
                bottom: number(style["paddingBottom"]) ?? padding,
                right: number(style["paddingRight"]) ?? padding
            )
            stack.isLayoutMarginsRelativeArrangement = true
            for (index, child) in children.enumerated() {
                if let child = child as? [String: Any] {
                    stack.addArrangedSubview(makeView(child, path: "\(key).\(index)"))
                }
            }
            if path == "root", stack.axis == .vertical {
                stack.addArrangedSubview(UIView())
            }
            result = stack
        }

        result.accessibilityIdentifier = key
        if type != "View" && type != "SafeAreaView" {
            result.setContentHuggingPriority(.required, for: .vertical)
        }
        if let background = color(style["backgroundColor"]) {
            result.backgroundColor = background
        }
        if let radius = number(style["borderRadius"]) {
            result.layer.cornerRadius = radius
        }
        if let width = number(style["width"]) {
            result.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        if let height = number(style["height"]) {
            result.heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        return result
    }

    @objc private func buttonPressed(_ sender: UIButton) {
        guard let handler = handlers[ObjectIdentifier(sender)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]])
    }

    @objc private func textChanged(_ sender: UITextField) {
        guard let handler = handlers[ObjectIdentifier(sender)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["text": sender.text ?? ""]])
    }

    private func send(type: String, payload: [String: Any], correlationId: String? = nil) {
        var message: [String: Any] = ["type": type, "payload": payload]
        if let correlationId = correlationId { message["correlationId"] = correlationId }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        jsContext.objectForKeyedSubscript("__stxNativeCallback")?.call(withArguments: [json])
    }

    private func number(_ value: Any?) -> CGFloat? {
        (value as? NSNumber).map { CGFloat(truncating: $0) }
    }

    private func color(_ value: Any?) -> UIColor? {
        guard let hex = value as? String else { return nil }
        return UIColor(hex: hex)
    }
}
