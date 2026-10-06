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

private final class CraftNativeFlexSpacer: UIView {}

final class CraftNativeScreenController: UIViewController {
    private final class RenderedNode {
        let identity: String
        let type: String
        let view: UIView
        var protocolId: String?
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
    private var tapRecognizers: [ObjectIdentifier: UITapGestureRecognizer] = [:]
    private var imageSources: [ObjectIdentifier: String] = [:]
    private var imageTasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var renderedRoot: RenderedNode?
    private var flatListRows: [ObjectIdentifier: [String: RenderedNode]] = [:]
    private var flatListOwners: [String: String] = [:]
    private let mutationDocument = CraftNativeMutationDocument()
    private let capabilityScope = UUID().uuidString
    private var pendingCapabilityRequests = Set<String>()
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var deepLinkListener: UUID?

    init(config: CraftConfig, routeName: String? = nil, routeParams: [String: Any] = [:]) {
        self.config = config
        self.routeName = routeName
        self.routeParams = routeParams
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        imageTasks.values.forEach { $0.cancel() }
        pendingCapabilityRequests.forEach { CraftNativeActions.cancel(requestToken: $0) }
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        if let deepLinkListener = deepLinkListener { DeepLinkManager.shared.removeNativeListener(deepLinkListener) }
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
        observeNativeEvents()
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
        let capabilities = CraftNativeActions.capabilities(config: config)
        let capabilityData = try? JSONSerialization.data(withJSONObject: capabilities)
        let capabilityJSON = capabilityData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        jsContext.evaluateScript("""
            globalThis.__stxNativeCallback = null;
            globalThis.__stxNativeBridge = {
                platform: "ios",
                mutationProtocolVersion: 1,
                capabilityProtocolVersion: \(craftNativeCapabilityProtocolVersion),
                capabilities: \(capabilityJSON),
                initialAppState: "\(CraftNativeActions.currentAppState())",
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

    private func observeNativeEvents() {
        func observe(_ name: Notification.Name, state: String) {
            lifecycleObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.sendAppState(state) })
        }
        observe(UIApplication.didBecomeActiveNotification, state: "active")
        observe(UIApplication.willResignActiveNotification, state: "inactive")
        observe(UIApplication.didEnterBackgroundNotification, state: "background")
        sendAppState(CraftNativeActions.currentAppState())
        deepLinkListener = DeepLinkManager.shared.addNativeListener { [weak self] url, initial in
            guard let self = self, self.navigationController?.topViewController === self else { return }
            var payload = CraftNativeActions.deepLinkData(url)
            payload["initial"] = initial
            self.send(type: "DEEP_LINK", payload: payload)
        }
    }

    private func sendAppState(_ state: String) {
        guard navigationController?.topViewController === self else { return }
        send(type: "APP_STATE", payload: ["state": state])
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
              let type = message["type"] as? String else { return }
        let payload = message["payload"] as? [String: Any] ?? [:]

        switch type {
        case "RENDER":
            guard let document = payload["document"] as? [String: Any] else { return }
            render(document)
        case "MUTATE":
            do {
                let result = try applyMutation(payload)
                send(type: "MUTATION_ACK", payload: [
                    "batchId": result.batchId,
                    "revision": result.revision,
                    "version": craftNativeMutationProtocolVersion,
                ])
            } catch let failure as CraftNativeMutationFailure {
                var error: [String: Any] = [
                    "batchId": payload["batchId"] as? String ?? "",
                    "code": failure.code,
                    "message": failure.message,
                    "version": craftNativeMutationProtocolVersion,
                ]
                if let operationIndex = failure.operationIndex { error["operationIndex"] = operationIndex }
                send(type: "MUTATION_ERROR", payload: error)
            } catch {
                send(type: "MUTATION_ERROR", payload: [
                    "batchId": payload["batchId"] as? String ?? "",
                    "code": "INVALID_BATCH",
                    "message": "mutation batch could not be applied",
                    "version": craftNativeMutationProtocolVersion,
                ])
            }
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
            let requestToken = "\(capabilityScope)/\(id)"
            pendingCapabilityRequests.insert(requestToken)
            CraftNativeActions.perform(
                requestToken: requestToken,
                version: payload["version"] as? Int ?? craftNativeCapabilityProtocolVersion,
                module: payload["module"] as? String ?? "",
                method: payload["method"] as? String ?? "",
                args: args,
                config: config
            ) { [weak self] answer in
                guard let self = self, self.pendingCapabilityRequests.remove(requestToken) != nil else { return }
                switch answer {
                case .success(let data):
                    self.send(type: "API_RESPONSE", payload: [
                        "version": craftNativeCapabilityProtocolVersion,
                        "requestId": id,
                        "data": data,
                    ], correlationId: id)
                case .failure(let error):
                    self.send(type: "API_ERROR", payload: [
                        "version": craftNativeCapabilityProtocolVersion,
                        "requestId": id,
                        "code": error.code,
                        "message": error.message,
                    ], correlationId: id)
                }
            }
        case "API_CANCEL":
            guard let id = payload["requestId"] as? String else { return }
            let requestToken = "\(capabilityScope)/\(id)"
            pendingCapabilityRequests.remove(requestToken)
            CraftNativeActions.cancel(requestToken: requestToken)
        default:
            break
        }
    }

    // Internal so simulator-hosted XCTest can assert actual UIView identity.
    func render(_ document: [String: Any]) {
        mutationDocument.replace(with: document)
        renderCommitted(document)
    }

    @discardableResult
    func applyMutation(_ payload: [String: Any]) throws -> CraftNativeMutationResult {
        let result = try mutationDocument.apply(payload)
        if !result.requiresFullRender, applyTargetedUpdates(result.affectedNodeIds) { return result }
        if let document = result.document { renderCommitted(document) } else { clearRenderedTree() }
        return result
    }

    private func applyTargetedUpdates(_ ids: [String]) -> Bool {
        var applied = Set<String>()
        for id in ids {
            let target = flatListOwners[id] ?? id
            guard applied.insert(target).inserted else { continue }
            guard let document = mutationDocument.node(target), let previous = renderedNode(target) else { return false }
            _ = reconcile(document, identity: previous.identity, path: target, previous: previous)
        }
        return true
    }

    private func renderedNode(_ id: String, below node: RenderedNode? = nil) -> RenderedNode? {
        guard let node = node ?? renderedRoot else { return nil }
        if node.protocolId == id { return node }
        for child in node.children {
            if let match = renderedNode(id, below: child) { return match }
        }
        return nil
    }

    private func renderCommitted(_ document: [String: Any]) {
        let previous = renderedRoot
        let next = reconcile(document, identity: "root", path: "root", previous: previous)
        if previous?.view !== next.view {
            if let old = previous { detach(old, from: rootStack) }
            rootStack.addArrangedSubview(next.view)
        }
        renderedRoot = next
    }

    private func clearRenderedTree() {
        if let root = renderedRoot { detach(root, from: rootStack) }
        renderedRoot = nil
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
        current.protocolId = node["id"] as? String
        result.accessibilityIdentifier = accessibilityIdentifier(node, props: props) ?? path
        if type != "View" && type != "SafeAreaView" && type != "ScrollView" && type != "FlatList" {
            result.setContentHuggingPriority(.required, for: .vertical)
        }
        applyViewStyle(style, to: result, node: current)

        switch type {
        case "Text":
            let label = result as! UILabel
            configureText(label, text: children.compactMap { $0 as? String }.joined(), style: style)
        case "Button":
            let button = result as! UIButton
            button.setTitle(props["title"] as? String ?? children.compactMap { $0 as? String }.joined(), for: .normal)
            button.setTitleColor(color(style["color"]) ?? .systemBlue, for: .normal)
            button.titleLabel?.font = textFont(
                style,
                default: button.titleLabel?.font ?? .systemFont(ofSize: UIFont.buttonFontSize)
            )
            updateHandler(events["onPress"] ?? events["onClick"], for: button)
        case "TextInput":
            let field = result as! UITextField
            field.placeholder = props["placeholder"] as? String
            field.textColor = color(style["color"]) ?? .label
            field.font = textFont(style, default: field.font ?? .systemFont(ofSize: UIFont.systemFontSize))
            field.textAlignment = textAlignment(style["textAlign"])
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
            reconcileChildren(children, in: scroll.contentStack, parent: current, path: path, style: style)
        case "FlatList":
            let list = result as! CraftNativeFlatList
            reconcileFlatList(
                children.compactMap { $0 as? [String: Any] },
                in: list,
                parent: current,
                path: path,
                props: props,
                events: events
            )
        default:
            let stack = result as! UIStackView
            configureStack(stack, style: style)
            reconcileChildren(children, in: stack, parent: current, path: path, style: style)
        }
        if type != "Button" && type != "TextInput" {
            updatePressHandler(events["onPress"] ?? events["onClick"], for: result)
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
        case "FlatList":
            return CraftNativeFlatList()
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
        [node["id"], node["key"], props["key"], props["testID"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty }
    }

    private func accessibilityIdentifier(_ node: [String: Any], props: [String: Any]) -> String? {
        [props["testID"], props["key"], node["key"], node["id"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty }
    }

    private func reconcileChildren(
        _ children: [Any],
        in stack: UIStackView,
        parent: RenderedNode,
        path: String,
        style: [String: Any]
    ) {
        for spacer in stack.arrangedSubviews.compactMap({ $0 as? CraftNativeFlexSpacer }) {
            stack.removeArrangedSubview(spacer)
            spacer.removeFromSuperview()
        }
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
        if (style["flexDirection"] as? String)?.hasSuffix("-reverse") == true { next.reverse() }

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
        addJustificationSpacers(to: stack, value: style["justifyContent"] as? String)
    }

    private func reconcileFlatList(
        _ children: [[String: Any]],
        in list: CraftNativeFlatList,
        parent: RenderedNode,
        path: String,
        props: [String: Any],
        events: [String: String]
    ) {
        let listKey = ObjectIdentifier(list)
        let owner = parent.protocolId ?? path
        flatListOwners = flatListOwners.filter { $0.value != owner }
        for child in children { registerFlatListOwnership(child, owner: owner) }

        list.apply(
            nodes: children,
            horizontal: props["horizontal"] as? Bool == true,
            columns: (props["numColumns"] as? NSNumber)?.intValue ?? 1,
            inverted: props["inverted"] as? Bool == true,
            endReachedThreshold: (props["onEndReachedThreshold"] as? NSNumber)?.doubleValue
                ?? (props["threshold"] as? NSNumber)?.doubleValue
                ?? 0.1,
            renderItem: { [weak self] node, identity, _ in
                guard let self = self else { return UIView() }
                let previous = self.flatListRows[listKey]?[identity]
                let next = self.reconcile(
                    node,
                    identity: "list:\(identity)",
                    path: "\(path).\(identity)",
                    previous: previous
                )
                self.flatListRows[listKey, default: [:]][identity] = next
                return next.view
            },
            recycleItem: { [weak self] identity in
                guard let self = self,
                      let row = self.flatListRows[listKey]?.removeValue(forKey: identity) else { return }
                self.forgetHandlers(row)
            },
            endReached: events["onEndReached"].map { [weak self] handler in
                { self?.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]]) }
            }
        )
        parent.children = []
    }

    private func registerFlatListOwnership(_ node: [String: Any], owner: String) {
        let props = node["props"] as? [String: Any] ?? [:]
        for identity in [node["id"], node["key"], props["key"], props["testID"]].compactMap({ $0 as? String }) {
            if !identity.isEmpty { flatListOwners[identity] = owner }
        }
        for child in (node["children"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
            registerFlatListOwnership(child, owner: owner)
        }
    }

    private func detach(_ node: RenderedNode, from stack: UIStackView) {
        forgetHandlers(node)
        stack.removeArrangedSubview(node.view)
        node.view.removeFromSuperview()
    }

    private func forgetHandlers(_ node: RenderedNode) {
        if let list = node.view as? CraftNativeFlatList {
            let listKey = ObjectIdentifier(list)
            list.discardAll()
            flatListRows.removeValue(forKey: listKey)
            if let owner = node.protocolId { flatListOwners = flatListOwners.filter { $0.value != owner } }
        }
        let id = ObjectIdentifier(node.view)
        handlers.removeValue(forKey: id)
        if let recognizer = tapRecognizers.removeValue(forKey: id) {
            node.view.removeGestureRecognizer(recognizer)
        }
        imageSources.removeValue(forKey: id)
        imageTasks.removeValue(forKey: id)?.cancel()
        for child in node.children { forgetHandlers(child) }
    }

    private func updateHandler(_ handler: String?, for view: UIView) {
        let id = ObjectIdentifier(view)
        if let handler = handler { handlers[id] = handler }
        else { handlers.removeValue(forKey: id) }
    }

    private func updatePressHandler(_ handler: String?, for view: UIView) {
        let id = ObjectIdentifier(view)
        updateHandler(handler, for: view)
        if handler != nil, tapRecognizers[id] == nil {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(viewPressed(_:)))
            tapRecognizers[id] = recognizer
            view.addGestureRecognizer(recognizer)
        } else if handler == nil, let recognizer = tapRecognizers.removeValue(forKey: id) {
            view.removeGestureRecognizer(recognizer)
        }
        if view is UIImageView { view.isUserInteractionEnabled = handler != nil }
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
        let direction = style["flexDirection"] as? String
        stack.axis = direction == "row" || direction == "row-reverse" ? .horizontal : .vertical
        stack.spacing = number(stack.axis == .horizontal ? style["columnGap"] : style["rowGap"])
            ?? number(style["gap"]) ?? 0
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
        let horizontal = number(style["paddingHorizontal"]) ?? padding
        let vertical = number(style["paddingVertical"]) ?? padding
        stack.layoutMargins = UIEdgeInsets(
            top: number(style["paddingTop"]) ?? vertical,
            left: number(style["paddingLeft"]) ?? horizontal,
            bottom: number(style["paddingBottom"]) ?? vertical,
            right: number(style["paddingRight"]) ?? horizontal
        )
    }

    private func addJustificationSpacers(to stack: UIStackView, value: String?) {
        guard !stack.arrangedSubviews.isEmpty else { return }
        let leading = value == "center" || value == "flex-end"
        let trailing = value == nil || value == "flex-start" || value == "center"
        if leading { stack.insertArrangedSubview(CraftNativeFlexSpacer(), at: 0) }
        if trailing { stack.addArrangedSubview(CraftNativeFlexSpacer()) }
    }

    private func applyViewStyle(_ style: [String: Any], to view: UIView, node: RenderedNode) {
        view.backgroundColor = color(style["backgroundColor"]) ?? .clear
        view.alpha = number(style["opacity"]) ?? 1
        view.isHidden = style["display"] as? String == "none"
        view.layer.cornerRadius = number(style["borderRadius"]) ?? 0
        view.layer.borderWidth = number(style["borderWidth"]) ?? 0
        view.layer.borderColor = (color(style["borderColor"]) ?? .clear).cgColor
        view.clipsToBounds = style["overflow"] as? String == "hidden"
        updateDimension(number(style["width"]), constraint: &node.widthConstraint, anchor: view.widthAnchor)
        updateDimension(number(style["height"]), constraint: &node.heightConstraint, anchor: view.heightAnchor)
    }

    private func configureText(_ label: UILabel, text: String, style: [String: Any]) {
        let transformed: String
        switch style["textTransform"] as? String {
        case "uppercase": transformed = text.uppercased()
        case "lowercase": transformed = text.lowercased()
        case "capitalize": transformed = text.capitalized
        default: transformed = text
        }
        label.textColor = color(style["color"]) ?? .label
        label.font = textFont(style, default: .systemFont(ofSize: UIFont.systemFontSize))
        label.textAlignment = textAlignment(style["textAlign"])
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let spacing = number(style["letterSpacing"]) { attributes[.kern] = spacing }
        if let lineHeight = number(style["lineHeight"]) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            paragraph.alignment = label.textAlignment
            attributes[.paragraphStyle] = paragraph
        }
        switch style["textDecorationLine"] as? String {
        case "underline": attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        case "line-through": attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        case "underline line-through":
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        default: break
        }
        label.attributedText = attributes.isEmpty ? nil : NSAttributedString(string: transformed, attributes: attributes)
        if attributes.isEmpty { label.text = transformed }
    }

    private func textFont(_ style: [String: Any], default fallback: UIFont) -> UIFont {
        let size = number(style["fontSize"]) ?? fallback.pointSize
        let weight: UIFont.Weight
        switch style["fontWeight"] as? String {
        case "100": weight = .ultraLight
        case "200": weight = .thin
        case "300": weight = .light
        case "500": weight = .medium
        case "600": weight = .semibold
        case "bold", "700": weight = .bold
        case "800": weight = .heavy
        case "900": weight = .black
        default: weight = .regular
        }
        var font = (style["fontFamily"] as? String).flatMap { UIFont(name: $0, size: size) }
            ?? .systemFont(ofSize: size, weight: weight)
        if style["fontStyle"] as? String == "italic",
           let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        return font
    }

    private func textAlignment(_ value: Any?) -> NSTextAlignment {
        switch value as? String {
        case "left": return .left
        case "right": return .right
        case "center": return .center
        case "justify": return .justified
        default: return .natural
        }
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
            imageFailure(view, uri: nil, message: "Image source is missing")
            return
        }
        guard imageSources[id] != uri else { return }
        imageTasks.removeValue(forKey: id)?.cancel()
        imageSources[id] = uri
        view.image = nil
        view.accessibilityValue = nil

        if uri.hasPrefix("data:image/") {
            guard let comma = uri.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])),
                  let image = UIImage(data: data) else {
                imageFailure(view, uri: uri, message: "Image data is invalid")
                return
            }
            view.image = image
            return
        }
        if let url = URL(string: uri), url.scheme == "https" {
            let task = URLSession.shared.dataTask(with: url) { [weak self, weak view] data, _, _ in
                guard let self, let view else { return }
                DispatchQueue.main.async {
                    guard self.imageSources[ObjectIdentifier(view)] == uri else { return }
                    self.imageTasks.removeValue(forKey: ObjectIdentifier(view))
                    guard let data, let image = UIImage(data: data) else {
                        self.imageFailure(view, uri: uri, message: "Image download failed")
                        return
                    }
                    view.image = image
                }
            }
            imageTasks[id] = task
            task.resume()
            return
        }
        if !uri.contains(":") {
            guard let image = UIImage(named: uri) else {
                imageFailure(view, uri: uri, message: "Bundled image was not found")
                return
            }
            view.image = image
            return
        }
        imageFailure(view, uri: uri, message: "Unsupported image source")
    }

    private func imageFailure(_ view: UIImageView, uri: String?, message: String) {
        view.image = nil
        view.accessibilityValue = message
        NSLog("[craft native] %@: %@", message, uri ?? "<missing>")
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

    @objc private func viewPressed(_ sender: UITapGestureRecognizer) {
        guard let view = sender.view, let handler = handlers[ObjectIdentifier(view)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]])
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
