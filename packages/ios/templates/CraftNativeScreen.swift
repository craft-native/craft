import Foundation
import JavaScriptCore
import SwiftUI
import UIKit

/// A WebView-free host for the first stx-native vertical slice. The bundled
/// JavaScript sends whole, compiled view trees to UIKit and receives control
/// events and Craft API replies through JavaScriptCore.
struct CraftNativeScreen: UIViewControllerRepresentable {
    let config: CraftConfig

    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: CraftNativeScreenController(config: config))
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

private final class CraftNativeScrollView: UIScrollView {
    let contentStack = UIStackView()
    private var crossAxisConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.distribution = .fill
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor)
        ])
        setAxis(.vertical)
    }

    required init?(coder: NSCoder) { nil }

    func setAxis(_ axis: NSLayoutConstraint.Axis) {
        contentStack.axis = axis
        crossAxisConstraint?.isActive = false
        crossAxisConstraint = axis == .vertical
            ? contentStack.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor)
            : contentStack.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor)
        crossAxisConstraint?.isActive = true
        alwaysBounceVertical = axis == .vertical
        alwaysBounceHorizontal = axis == .horizontal
    }
}

final class CraftNativeScreenController: UIViewController {
    private final class RenderedNode {
        let identity: String
        let type: String
        let view: UIView
        var children: [RenderedNode] = []
        var widthConstraint: NSLayoutConstraint?
        var heightConstraint: NSLayoutConstraint?

        init(identity: String, type: String, view: UIView) {
            self.identity = identity
            self.type = type
            self.view = view
        }
    }

    private let config: CraftConfig
    private let routeName: String?
    private let routeParams: [String: Any]
    private let jsContext = JSContext()!
    private let rootStack = UIStackView()
    private var handlers: [ObjectIdentifier: String] = [:]
    private var imageSources: [ObjectIdentifier: String] = [:]
    private var imageTasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var renderedRoot: RenderedNode?

    init(config: CraftConfig, routeName: String? = nil, routeParams: [String: Any] = [:]) {
        self.config = config
        self.routeName = routeName
        self.routeParams = routeParams
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = routeName ?? config.appName
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
        if let routeName = routeName {
            jsContext.setObject(routeName, forKeyedSubscript: "__stxNativeRoute" as NSString)
        }
        jsContext.setObject(routeParams as NSDictionary, forKeyedSubscript: "__stxNativeParams" as NSString)
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
        if routeName == nil, let selected = jsContext.objectForKeyedSubscript("__stxNativeRoute")?.toString() {
            navigationItem.title = selected
        }
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
        case "NAVIGATE", "NAVIGATE_REPLACE":
            guard navigationController?.topViewController === self,
                  let screen = payload["screen"] as? String, !screen.isEmpty,
                  let navigation = navigationController else { return }
            let params = payload["params"] as? [String: Any] ?? [:]
            let next = CraftNativeScreenController(config: config, routeName: screen, routeParams: params)
            if type == "NAVIGATE" {
                navigation.pushViewController(next, animated: true)
            } else {
                navigation.setViewControllers(Array(navigation.viewControllers.dropLast()) + [next], animated: true)
            }
        case "NAVIGATE_BACK":
            if navigationController?.topViewController === self {
                navigationController?.popViewController(animated: true)
            }
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

    // Internal so simulator-hosted XCTest can assert actual UIView identity.
    func render(_ document: [String: Any]) {
        let previous = renderedRoot
        let next = reconcile(document, identity: "root", path: "root", previous: previous)
        if previous?.view !== next.view {
            if let old = previous { detach(old, from: rootStack) }
            rootStack.addArrangedSubview(next.view)
        }
        renderedRoot = next
    }

    private func reconcile(_ node: [String: Any], identity: String, path: String, previous: RenderedNode?) -> RenderedNode {
        let type = node["type"] as? String ?? "View"
        let props = node["props"] as? [String: Any] ?? [:]
        let style = node["style"] as? [String: Any] ?? [:]
        let events = node["events"] as? [String: String] ?? [:]
        let children = node["children"] as? [Any] ?? []
        let current: RenderedNode
        if let previous = previous, previous.identity == identity, previous.type == type {
            current = previous
        } else {
            current = RenderedNode(identity: identity, type: type, view: makeView(type))
        }

        let result = current.view
        result.accessibilityIdentifier = explicitKey(node, props: props) ?? path
        if type != "View" && type != "SafeAreaView" && type != "ScrollView" {
            result.setContentHuggingPriority(.required, for: .vertical)
        }
        result.backgroundColor = color(style["backgroundColor"]) ?? .clear
        result.layer.cornerRadius = number(style["borderRadius"]) ?? 0
        updateDimension(number(style["width"]), constraint: &current.widthConstraint, anchor: result.widthAnchor)
        updateDimension(number(style["height"]), constraint: &current.heightConstraint, anchor: result.heightAnchor)

        switch type {
        case "Text":
            let label = result as! UILabel
            label.text = children.compactMap { $0 as? String }.joined()
            label.textColor = color(style["color"]) ?? .label
            label.font = .systemFont(ofSize: number(style["fontSize"]) ?? UIFont.systemFontSize)
        case "Button":
            let button = result as! UIButton
            button.setTitle(props["title"] as? String ?? children.compactMap { $0 as? String }.joined(), for: .normal)
            updateHandler(events["onPress"] ?? events["onClick"], for: button)
        case "TextInput":
            let field = result as! UITextField
            field.placeholder = props["placeholder"] as? String
            updateField(field, value: props["value"] as? String)
            updateHandler(events["onChange"] ?? events["onChangeText"], for: field)
        case "Image":
            let image = result as! UIImageView
            image.contentMode = imageContentMode(style["resizeMode"] ?? props["resizeMode"])
            image.clipsToBounds = image.contentMode == .scaleAspectFill
            updateImage(image, source: props["source"])
        case "ScrollView":
            let scroll = result as! CraftNativeScrollView
            let direction = (props["horizontal"] as? Bool) == true || style["flexDirection"] as? String == "row"
                ? NSLayoutConstraint.Axis.horizontal : .vertical
            scroll.setAxis(direction)
            configureStack(scroll.contentStack, style: style)
            reconcileChildren(children, in: scroll.contentStack, parent: current, path: path)
        default:
            let stack = result as! UIStackView
            configureStack(stack, style: style)
            reconcileChildren(children, in: stack, parent: current, path: path)
        }
        applyAccessibility(props, type: type, to: result)
        return current
    }

    private func makeView(_ type: String) -> UIView {
        switch type {
        case "Text":
            let label = UILabel()
            label.numberOfLines = 0
            return label
        case "Button":
            let button = UIButton(type: .system)
            button.addTarget(self, action: #selector(buttonPressed(_:)), for: .touchUpInside)
            return button
        case "TextInput":
            let field = UITextField()
            field.borderStyle = .roundedRect
            field.addTarget(self, action: #selector(textChanged(_:)), for: .editingChanged)
            return field
        case "Image":
            return UIImageView()
        case "ScrollView":
            return CraftNativeScrollView()
        default:
            let stack = UIStackView()
            stack.alignment = .fill
            stack.distribution = .fill
            stack.isLayoutMarginsRelativeArrangement = true
            return stack
        }
    }

    private func explicitKey(_ node: [String: Any], props: [String: Any]) -> String? {
        // The current stx-native compiler emits key in props; accept the IR
        // field too so keyed children keep working when the compiler adopts it.
        [node["key"], props["key"], props["testID"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty }
    }

    private func reconcileChildren(_ children: [Any], in stack: UIStackView, parent: RenderedNode, path: String) {
        let nodes = children.compactMap { $0 as? [String: Any] }
        let keys = nodes.compactMap { explicitKey($0, props: $0["props"] as? [String: Any] ?? [:]) }
        let counts = Dictionary(keys.map { ($0, 1) }, uniquingKeysWith: +)
        let old = Dictionary(uniqueKeysWithValues: parent.children.map { ($0.identity, $0) })
        var next: [RenderedNode] = []

        for (index, node) in nodes.enumerated() {
            let key = explicitKey(node, props: node["props"] as? [String: Any] ?? [:])
            // Keys are local to a parent. Ambiguous sibling keys fall back to
            // position so a move never attaches the wrong live control.
            let identity = key.flatMap { counts[$0] == 1 ? "key:\($0)" : nil } ?? "index:\(index)"
            let child = reconcile(node, identity: identity, path: "\(path).\(index)", previous: old[identity])
            next.append(child)
        }

        for child in parent.children where !next.contains(where: { $0 === child }) {
            detach(child, from: stack)
        }
        for (index, child) in next.enumerated() {
            if index < stack.arrangedSubviews.count, stack.arrangedSubviews[index] === child.view { continue }
            if stack.arrangedSubviews.contains(where: { $0 === child.view }) {
                stack.removeArrangedSubview(child.view)
            }
            stack.insertArrangedSubview(child.view, at: index)
        }
        parent.children = next
        if path == "root" && stack.axis == .vertical {
            // Keep the initial screen pinned to the safe-area top.
            if stack.arrangedSubviews.count == next.count { stack.addArrangedSubview(UIView()) }
        } else if stack.arrangedSubviews.count > next.count {
            for filler in stack.arrangedSubviews.dropFirst(next.count) {
                stack.removeArrangedSubview(filler)
                filler.removeFromSuperview()
            }
        }
    }

    private func detach(_ node: RenderedNode, from stack: UIStackView) {
        forgetHandlers(node)
        stack.removeArrangedSubview(node.view)
        node.view.removeFromSuperview()
    }

    private func forgetHandlers(_ node: RenderedNode) {
        let id = ObjectIdentifier(node.view)
        handlers.removeValue(forKey: id)
        imageSources.removeValue(forKey: id)
        imageTasks.removeValue(forKey: id)?.cancel()
        for child in node.children { forgetHandlers(child) }
    }

    private func updateHandler(_ handler: String?, for view: UIView) {
        let id = ObjectIdentifier(view)
        if let handler = handler { handlers[id] = handler }
        else { handlers.removeValue(forKey: id) }
    }

    private func updateField(_ field: UITextField, value: String?) {
        guard let value = value, field.text != value, field.markedTextRange == nil else { return }
        let selection = field.selectedTextRange
        let start = selection.map { field.offset(from: field.beginningOfDocument, to: $0.start) }
        let end = selection.map { field.offset(from: field.beginningOfDocument, to: $0.end) }
        field.text = value
        if let start = start, let end = end,
           let from = field.position(from: field.beginningOfDocument, offset: min(start, value.utf16.count)),
           let to = field.position(from: field.beginningOfDocument, offset: min(end, value.utf16.count)) {
            field.selectedTextRange = field.textRange(from: from, to: to)
        }
    }

    private func configureStack(_ stack: UIStackView, style: [String: Any]) {
        stack.axis = style["flexDirection"] as? String == "row" ? .horizontal : .vertical
        stack.spacing = number(style["gap"]) ?? 0
        switch style["alignItems"] as? String {
        case "flex-start": stack.alignment = .leading
        case "center": stack.alignment = .center
        case "flex-end": stack.alignment = .trailing
        case "baseline": stack.alignment = .firstBaseline
        default: stack.alignment = .fill
        }
        switch style["justifyContent"] as? String {
        case "space-between", "space-around", "space-evenly": stack.distribution = .equalSpacing
        default: stack.distribution = .fill
        }
        let padding = number(style["padding"]) ?? 0
        stack.layoutMargins = UIEdgeInsets(
            top: number(style["paddingTop"]) ?? padding,
            left: number(style["paddingLeft"]) ?? padding,
            bottom: number(style["paddingBottom"]) ?? padding,
            right: number(style["paddingRight"]) ?? padding
        )
    }

    private func imageContentMode(_ value: Any?) -> UIView.ContentMode {
        switch value as? String {
        case "cover": return .scaleAspectFill
        case "stretch": return .scaleToFill
        case "center": return .center
        default: return .scaleAspectFit
        }
    }

    private func updateImage(_ view: UIImageView, source: Any?) {
        let uri = (source as? String) ?? (source as? [String: Any])?["uri"] as? String
        let id = ObjectIdentifier(view)
        guard let uri, !uri.isEmpty else {
            imageTasks.removeValue(forKey: id)?.cancel()
            imageSources.removeValue(forKey: id)
            view.image = nil
            view.accessibilityValue = "Image source is missing"
            return
        }
        guard imageSources[id] != uri else { return }
        imageTasks.removeValue(forKey: id)?.cancel()
        imageSources[id] = uri
        view.image = nil
        view.accessibilityValue = nil

        if uri.hasPrefix("data:image/"), let comma = uri.firstIndex(of: ","),
           let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])),
           let image = UIImage(data: data) {
            view.image = image
            return
        }
        if let url = URL(string: uri), url.scheme == "https" {
            let task = URLSession.shared.dataTask(with: url) { [weak self, weak view] data, _, _ in
                guard let self, let view, let data, let image = UIImage(data: data) else { return }
                DispatchQueue.main.async {
                    guard self.imageSources[ObjectIdentifier(view)] == uri else { return }
                    view.image = image
                }
            }
            imageTasks[id] = task
            task.resume()
            return
        }
        if !uri.contains(":"), let image = UIImage(named: uri) {
            view.image = image
            return
        }
        view.accessibilityValue = "Unsupported image source"
        NSLog("[craft native] Unsupported image source: %@", uri)
    }

    private func applyAccessibility(_ props: [String: Any], type: String, to view: UIView) {
        view.accessibilityLabel = props["accessibilityLabel"] as? String
        view.accessibilityHint = props["accessibilityHint"] as? String
        let role = props["accessibilityRole"] as? String
        view.isAccessibilityElement = view.accessibilityLabel != nil || role != nil || ["Text", "Button", "Image", "TextInput"].contains(type)
        switch role ?? type.lowercased() {
        case "button": view.accessibilityTraits = .button
        case "image": view.accessibilityTraits = .image
        case "header": view.accessibilityTraits = .header
        case "link": view.accessibilityTraits = .link
        case "search": view.accessibilityTraits = .searchField
        default: view.accessibilityTraits = []
        }
    }

    private func updateDimension(_ value: CGFloat?, constraint: inout NSLayoutConstraint?, anchor: NSLayoutDimension) {
        if let value = value {
            if let constraint = constraint { constraint.constant = value }
            else {
                constraint = anchor.constraint(equalToConstant: value)
                constraint?.isActive = true
            }
        } else {
            constraint?.isActive = false
            constraint = nil
        }
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
