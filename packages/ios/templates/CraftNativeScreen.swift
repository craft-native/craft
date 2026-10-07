import Foundation
import JavaScriptCore
import SwiftUI
import UIKit

private let craftNativeCapabilityTimeoutMilliseconds = 30_000

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

private struct CraftNativeLayoutStyle {
    let width: CGFloat?
    let height: CGFloat?
    let minWidth: CGFloat?
    let maxWidth: CGFloat?
    let minHeight: CGFloat?
    let maxHeight: CGFloat?
    let position: String
    let top: CGFloat?
    let right: CGFloat?
    let bottom: CGFloat?
    let left: CGFloat?
    let alignSelf: String?

    init(_ raw: [String: Any]) {
        func number(_ value: Any?) -> CGFloat? { (value as? NSNumber).map { CGFloat(truncating: $0) } }
        width = number(raw["width"])
        height = number(raw["height"])
        minWidth = number(raw["minWidth"])
        maxWidth = number(raw["maxWidth"])
        minHeight = number(raw["minHeight"])
        maxHeight = number(raw["maxHeight"])
        position = raw["position"] as? String ?? "relative"
        top = number(raw["top"])
        right = number(raw["right"])
        bottom = number(raw["bottom"])
        left = number(raw["left"])
        alignSelf = raw["alignSelf"] as? String
    }
}

private final class CraftNativeFlowView: UIStackView {
    var wrap = false { didSet { invalidateIntrinsicContentSize(); setNeedsLayout() } }
    var alignItems = "stretch" { didSet { alignment = alignmentValue; setNeedsLayout() } }
    var justifyContent = "flex-start" { didSet { distribution = distributionValue; setNeedsLayout() } }
    var gap: CGFloat = 0 { didSet { spacing = gap; invalidateIntrinsicContentSize(); setNeedsLayout() } }
    var rowGap: CGFloat? { didSet { invalidateIntrinsicContentSize(); setNeedsLayout() } }
    var columnGap: CGFloat? { didSet { invalidateIntrinsicContentSize(); setNeedsLayout() } }
    var padding = UIEdgeInsets.zero {
        didSet {
            layoutMargins = padding
            isLayoutMarginsRelativeArrangement = true
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }
    private var childStyles: [ObjectIdentifier: CraftNativeLayoutStyle] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        alignment = .fill
        distribution = .fill
        isLayoutMarginsRelativeArrangement = true
    }

    required init(coder: NSCoder) { super.init(coder: coder) }

    private var alignmentValue: UIStackView.Alignment {
        switch alignItems {
        case "flex-start": return .leading
        case "center": return .center
        case "flex-end": return .trailing
        case "baseline": return .firstBaseline
        default: return .fill
        }
    }

    private var distributionValue: UIStackView.Distribution {
        switch justifyContent {
        case "center": return .equalCentering
        case "space-between", "space-around", "space-evenly": return .equalSpacing
        default: return .fill
        }
    }

    func setLayoutStyle(_ raw: [String: Any], for view: UIView) {
        childStyles[ObjectIdentifier(view)] = CraftNativeLayoutStyle(raw)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func removeLayoutStyle(for view: UIView) { childStyles.removeValue(forKey: ObjectIdentifier(view)) }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        setNeedsLayout()
    }

    override func willRemoveSubview(_ subview: UIView) {
        childStyles.removeValue(forKey: ObjectIdentifier(subview))
        super.willRemoveSubview(subview)
    }

    override var intrinsicContentSize: CGSize {
        let children = subviews.filter { !$0.isHidden && !($0 is CraftNativeFlexSpacer) }
        guard !children.isEmpty else { return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }
        let sizes = children.map { measuredSize(for: $0, available: CGSize(width: 10_000, height: 10_000)) }
        let main = sizes.map { axis == .horizontal ? $0.width : $0.height }.reduce(0, +)
        let cross = sizes.map { axis == .horizontal ? $0.height : $0.width }.max() ?? 0
        let mainGap = max(0, CGFloat(max(0, children.count - 1))) * mainGapValue
        if axis == .horizontal {
            return CGSize(width: padding.left + padding.right + main + mainGap, height: padding.top + padding.bottom + cross)
        }
        return CGSize(width: padding.left + padding.right + cross, height: padding.top + padding.bottom + main + mainGap)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = bounds.inset(by: padding)
        let availableMain = axis == .horizontal ? content.width : content.height
        var lines: [([UIView], [CGSize], CGFloat, CGFloat)] = []
        var items: [UIView] = []
        var sizes: [CGSize] = []
        var main: CGFloat = 0
        var cross: CGFloat = 0

        func flush() {
            guard !items.isEmpty else { return }
            lines.append((items, sizes, main, cross))
            items = []; sizes = []; main = 0; cross = 0
        }

        for child in subviews where !child.isHidden && !(child is CraftNativeFlexSpacer) {
            let style = childStyles[ObjectIdentifier(child)] ?? CraftNativeLayoutStyle([:])
            if style.position == "absolute" { continue }
            let size = measuredSize(for: child, available: content.size, style: style)
            let childMain = axis == .horizontal ? size.width : size.height
            let childCross = axis == .horizontal ? size.height : size.width
            let next = items.isEmpty ? childMain : main + mainGapValue + childMain
            if wrap && !items.isEmpty && next > availableMain { flush() }
            items.append(child); sizes.append(size)
            main = items.count == 1 ? childMain : main + mainGapValue + childMain
            cross = max(cross, childCross)
        }
        flush()

        var crossOffset: CGFloat = 0
        for (lineItems, lineSizes, lineMain, lineCross) in lines {
            let free = max(0, availableMain - lineMain)
            let (leading, between) = distribution(free: free, count: lineItems.count)
            var mainOffset = leading
            for (index, child) in lineItems.enumerated() {
                let style = childStyles[ObjectIdentifier(child)] ?? CraftNativeLayoutStyle([:])
                let size = lineSizes[index]
                let childCross = axis == .horizontal ? size.height : size.width
                let alignment = style.alignSelf ?? alignItems
                let crossSize: CGFloat = alignment == "stretch" && styleCrossDimension(style) == nil ? lineCross : childCross
                let crossPosition: CGFloat
                switch alignment {
                case "center": crossPosition = (lineCross - crossSize) / 2
                case "flex-end": crossPosition = lineCross - crossSize
                default: crossPosition = 0
                }
                let frame: CGRect
                if axis == .horizontal {
                    frame = CGRect(x: content.minX + mainOffset, y: content.minY + crossOffset + crossPosition, width: size.width, height: crossSize)
                } else {
                    frame = CGRect(x: content.minX + crossOffset + crossPosition, y: content.minY + mainOffset, width: crossSize, height: size.height)
                }
                child.frame = frame.integral
                mainOffset += (axis == .horizontal ? size.width : size.height) + mainGapValue + between
            }
            crossOffset += lineCross + crossGapValue
        }

        for child in subviews where !child.isHidden && !(child is CraftNativeFlexSpacer) {
            let style = childStyles[ObjectIdentifier(child)] ?? CraftNativeLayoutStyle([:])
            guard style.position == "absolute" else { continue }
            let size = measuredSize(for: child, available: content.size, style: style)
            let width = style.left != nil && style.right != nil ? max(0, content.width - (style.left ?? 0) - (style.right ?? 0)) : size.width
            let height = style.top != nil && style.bottom != nil ? max(0, content.height - (style.top ?? 0) - (style.bottom ?? 0)) : size.height
            let x = style.left ?? (style.right.map { content.width - $0 - width } ?? 0)
            let y = style.top ?? (style.bottom.map { content.height - $0 - height } ?? 0)
            child.frame = CGRect(x: content.minX + x, y: content.minY + y, width: width, height: height).integral
        }
    }

    private var mainGapValue: CGFloat { axis == .horizontal ? (columnGap ?? gap) : (rowGap ?? gap) }
    private var crossGapValue: CGFloat { axis == .horizontal ? (rowGap ?? 0) : (columnGap ?? 0) }

    private func styleCrossDimension(_ style: CraftNativeLayoutStyle) -> CGFloat? {
        axis == .horizontal ? style.height : style.width
    }

    private func measuredSize(for view: UIView, available: CGSize, style: CraftNativeLayoutStyle? = nil) -> CGSize {
        let style = style ?? childStyles[ObjectIdentifier(view)] ?? CraftNativeLayoutStyle([:])
        let intrinsic = view.intrinsicContentSize
        let fitted = view.sizeThatFits(available)
        let width = style.width ?? (intrinsic.width > 0 && intrinsic.width != UIView.noIntrinsicMetric ? intrinsic.width : max(0, fitted.width))
        let height = style.height ?? (intrinsic.height > 0 && intrinsic.height != UIView.noIntrinsicMetric ? intrinsic.height : max(0, fitted.height))
        return CGSize(width: clamp(width, min: style.minWidth, max: style.maxWidth), height: clamp(height, min: style.minHeight, max: style.maxHeight))
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat?, max upper: CGFloat?) -> CGFloat {
        var result = value
        if let lower { result = max(result, lower) }
        if let upper { result = min(result, upper) }
        return result
    }

    private func distribution(free: CGFloat, count: Int) -> (CGFloat, CGFloat) {
        guard count > 0 else { return (0, 0) }
        switch justifyContent {
        case "center": return (free / 2, 0)
        case "flex-end": return (free, 0)
        case "space-between": return (0, count > 1 ? free / CGFloat(count - 1) : 0)
        case "space-around": return (free / CGFloat(count * 2), free / CGFloat(count))
        case "space-evenly": return (free / CGFloat(count + 1), free / CGFloat(count + 1))
        default: return (0, 0)
        }
    }
}

private final class CraftNativeScrollView: UIScrollView {
    let contentStack = CraftNativeFlowView()
    private var crossAxisConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
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

final class CraftNativeScreenController: UIViewController, UIScrollViewDelegate {
    private final class RenderedNode {
        let identity: String
        let type: String
        let view: UIView
        var protocolId: String?
        var style: [String: Any] = [:]
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
    private let rootStack = CraftNativeFlowView()
    private var handlers: [ObjectIdentifier: String] = [:]
    private var focusHandlers: [ObjectIdentifier: String] = [:]
    private var blurHandlers: [ObjectIdentifier: String] = [:]
    private var submitHandlers: [ObjectIdentifier: String] = [:]
    private var scrollHandlers: [ObjectIdentifier: String] = [:]
    private var scrollBeginHandlers: [ObjectIdentifier: String] = [:]
    private var scrollEndHandlers: [ObjectIdentifier: String] = [:]
    private var tapRecognizers: [ObjectIdentifier: UITapGestureRecognizer] = [:]
    private var imageSources: [ObjectIdentifier: String] = [:]
    private var imageTasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var renderedRoot: RenderedNode?
    private var flatListRows: [ObjectIdentifier: [String: RenderedNode]] = [:]
    private var flatListOwners: [String: String] = [:]
    private let mutationDocument = CraftNativeMutationDocument()
    private let capabilityScope = UUID().uuidString
    private var pendingCapabilityRequests = Set<String>()
    private var pendingCapabilityDeadlines: [String: DispatchWorkItem] = [:]
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
        pendingCapabilityDeadlines.values.forEach { $0.cancel() }
        pendingCapabilityRequests.forEach { CraftNativeActions.cancel(requestToken: $0) }
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        if let deepLinkListener = deepLinkListener { DeepLinkManager.shared.removeNativeListener(deepLinkListener) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = routeName ?? config.appName
        view.backgroundColor = config.resolvedBackgroundColor
        rootStack.axis = .vertical
        rootStack.alignItems = "stretch"
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
                capabilityTimeoutMs: \(craftNativeCapabilityTimeoutMilliseconds),
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
        rootStack.setLayoutStyle(["alignSelf": "stretch"], for: label)
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
            let deadline = DispatchWorkItem { [weak self] in
                guard let self = self, self.pendingCapabilityRequests.remove(requestToken) != nil else { return }
                self.pendingCapabilityDeadlines.removeValue(forKey: requestToken)
                CraftNativeActions.cancel(requestToken: requestToken)
                self.send(type: "API_ERROR", payload: [
                    "version": craftNativeCapabilityProtocolVersion,
                    "requestId": id,
                    "code": "TIMEOUT",
                    "message": "Native API request timed out",
                ], correlationId: id)
            }
            pendingCapabilityDeadlines[requestToken] = deadline
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(craftNativeCapabilityTimeoutMilliseconds),
                execute: deadline
            )
            CraftNativeActions.perform(
                requestToken: requestToken,
                version: payload["version"] as? Int ?? craftNativeCapabilityProtocolVersion,
                module: payload["module"] as? String ?? "",
                method: payload["method"] as? String ?? "",
                args: args,
                config: config
            ) { [weak self] answer in
                guard let self = self, self.pendingCapabilityRequests.remove(requestToken) != nil else { return }
                self.pendingCapabilityDeadlines.removeValue(forKey: requestToken)?.cancel()
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
            pendingCapabilityDeadlines.removeValue(forKey: requestToken)?.cancel()
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
        rootStack.setLayoutStyle(next.style, for: next.view)
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
        current.style = style
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
            field.keyboardType = keyboardType(props["keyboardType"])
            field.returnKeyType = returnKeyType(props["returnKeyType"])
            field.autocorrectionType = props["autoCorrect"] as? Bool == false ? .no : .default
            field.autocapitalizationType = capitalizationType(props["autoCapitalize"])
            field.isSecureTextEntry = props["secureTextEntry"] as? Bool == true
            field.isEnabled = props["editable"] as? Bool != false
            updateField(field, value: props["value"] as? String)
            updateHandler(events["onChange"] ?? events["onChangeText"], for: field)
            updateAuxiliaryHandler(events["onFocus"], in: &focusHandlers, for: field)
            updateAuxiliaryHandler(events["onBlur"] ?? events["onEndEditing"], in: &blurHandlers, for: field)
            updateAuxiliaryHandler(events["onSubmitEditing"], in: &submitHandlers, for: field)
            if props["autoFocus"] as? Bool == true, !field.isFirstResponder {
                DispatchQueue.main.async { _ = field.becomeFirstResponder() }
            }
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
            scroll.delegate = self
            scroll.isScrollEnabled = props["scrollEnabled"] as? Bool != false
            scroll.showsVerticalScrollIndicator = props["showsVerticalScrollIndicator"] as? Bool != false
            scroll.showsHorizontalScrollIndicator = props["showsHorizontalScrollIndicator"] as? Bool != false
            scroll.alwaysBounceVertical = props["alwaysBounceVertical"] as? Bool ?? (direction == .vertical)
            scroll.alwaysBounceHorizontal = props["alwaysBounceHorizontal"] as? Bool ?? (direction == .horizontal)
            updateAuxiliaryHandler(events["onScroll"], in: &scrollHandlers, for: scroll)
            updateAuxiliaryHandler(events["onScrollBeginDrag"], in: &scrollBeginHandlers, for: scroll)
            updateAuxiliaryHandler(events["onScrollEndDrag"], in: &scrollEndHandlers, for: scroll)
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
            let stack = result as! CraftNativeFlowView
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
            field.addTarget(self, action: #selector(textFocused(_:)), for: .editingDidBegin)
            field.addTarget(self, action: #selector(textBlurred(_:)), for: .editingDidEnd)
            field.addTarget(self, action: #selector(textSubmitted(_:)), for: .editingDidEndOnExit)
            return field
        case "Image":
            return UIImageView()
        case "ScrollView":
            return CraftNativeScrollView()
        case "FlatList":
            return CraftNativeFlatList()
        default:
            return CraftNativeFlowView()
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
        in stack: CraftNativeFlowView,
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
            if index < stack.arrangedSubviews.count, stack.arrangedSubviews[index] === child.view {
                stack.setLayoutStyle(child.style, for: child.view)
                continue
            }
            if child.view.superview === stack { stack.removeArrangedSubview(child.view) }
            stack.insertArrangedSubview(child.view, at: min(index, stack.arrangedSubviews.count))
            stack.setLayoutStyle(child.style, for: child.view)
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

    private func detach(_ node: RenderedNode, from stack: CraftNativeFlowView) {
        forgetHandlers(node)
        stack.removeLayoutStyle(for: node.view)
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
        focusHandlers.removeValue(forKey: id)
        blurHandlers.removeValue(forKey: id)
        submitHandlers.removeValue(forKey: id)
        scrollHandlers.removeValue(forKey: id)
        scrollBeginHandlers.removeValue(forKey: id)
        scrollEndHandlers.removeValue(forKey: id)
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

    private func updateAuxiliaryHandler(
        _ handler: String?,
        in handlers: inout [ObjectIdentifier: String],
        for view: UIView
    ) {
        let id = ObjectIdentifier(view)
        if let handler, !handler.isEmpty { handlers[id] = handler }
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

    private func configureStack(_ stack: CraftNativeFlowView, style: [String: Any]) {
        let direction = style["flexDirection"] as? String
        stack.axis = direction == "row" || direction == "row-reverse" ? .horizontal : .vertical
        stack.wrap = style["flexWrap"] as? String == "wrap" || style["flexWrap"] as? Bool == true
        stack.alignItems = style["alignItems"] as? String ?? "stretch"
        stack.justifyContent = style["justifyContent"] as? String ?? "flex-start"
        stack.gap = number(style["gap"]) ?? 0
        stack.rowGap = number(style["rowGap"])
        stack.columnGap = number(style["columnGap"])
        let padding = number(style["padding"]) ?? 0
        let horizontal = number(style["paddingHorizontal"]) ?? padding
        let vertical = number(style["paddingVertical"]) ?? padding
        stack.padding = UIEdgeInsets(
            top: number(style["paddingTop"]) ?? vertical,
            left: number(style["paddingLeft"]) ?? horizontal,
            bottom: number(style["paddingBottom"]) ?? vertical,
            right: number(style["paddingRight"]) ?? horizontal
        )
    }

    private func addJustificationSpacers(to stack: CraftNativeFlowView, value: String?) { }

    private func applyViewStyle(_ style: [String: Any], to view: UIView, node: RenderedNode) {
        let width = style["minWidth"] == nil && style["maxWidth"] == nil ? number(style["width"]) : nil
        let height = style["minHeight"] == nil && style["maxHeight"] == nil ? number(style["height"]) : nil
        updateDimension(width, constraint: &node.widthConstraint, anchor: view.widthAnchor)
        updateDimension(height, constraint: &node.heightConstraint, anchor: view.heightAnchor)
        view.backgroundColor = color(style["backgroundColor"]) ?? .clear
        view.alpha = number(style["opacity"]) ?? 1
        view.isHidden = style["display"] as? String == "none"
        view.layer.cornerRadius = number(style["borderRadius"]) ?? 0
        view.layer.borderWidth = number(style["borderWidth"]) ?? 0
        view.layer.borderColor = (color(style["borderColor"]) ?? .clear).cgColor
        view.clipsToBounds = style["overflow"] as? String == "hidden"
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
        if let value = props["accessibilityValue"] {
            view.accessibilityValue = (value as? String) ?? (value as? NSNumber)?.stringValue
        } else if type == "TextInput", let field = view as? UITextField {
            view.accessibilityValue = field.text
        }
        let role = props["accessibilityRole"] as? String
        view.isAccessibilityElement = role != "none" && (view.accessibilityLabel != nil || role != nil || ["Text", "Button", "Image", "TextInput"].contains(type))
        var traits: UIAccessibilityTraits = []
        switch role ?? type.lowercased() {
        case "button": traits.insert(.button)
        case "image": traits.insert(.image)
        case "header": traits.insert(.header)
        case "link": traits.insert(.link)
        case "search": traits.insert(.searchField)
        default: break
        }
        if let state = props["accessibilityState"] as? [String: Any] {
            if state["disabled"] as? Bool == true { traits.insert(.notEnabled) }
            if state["selected"] as? Bool == true { traits.insert(.selected) }
            if state["checked"] as? Bool == true { traits.insert(.selected) }
        }
        if let control = view as? UIControl, !control.isEnabled { traits.insert(.notEnabled) }
        view.accessibilityTraits = traits
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

    @objc private func textFocused(_ sender: UITextField) {
        guard let handler = focusHandlers[ObjectIdentifier(sender)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]])
    }

    @objc private func textBlurred(_ sender: UITextField) {
        guard let handler = blurHandlers[ObjectIdentifier(sender)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["text": sender.text ?? ""]])
    }

    @objc private func textSubmitted(_ sender: UITextField) {
        guard let handler = submitHandlers[ObjectIdentifier(sender)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["text": sender.text ?? ""]])
    }

    @objc private func viewPressed(_ sender: UITapGestureRecognizer) {
        guard let view = sender.view, let handler = handlers[ObjectIdentifier(view)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]])
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let handler = scrollHandlers[ObjectIdentifier(scrollView)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": scrollEvent(scrollView)])
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard let handler = scrollBeginHandlers[ObjectIdentifier(scrollView)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": scrollEvent(scrollView)])
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard let handler = scrollEndHandlers[ObjectIdentifier(scrollView)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": scrollEvent(scrollView)])
    }

    private func scrollEvent(_ scrollView: UIScrollView) -> [String: Any] {
        [
            "contentOffset": ["x": scrollView.contentOffset.x, "y": scrollView.contentOffset.y],
            "contentSize": ["width": scrollView.contentSize.width, "height": scrollView.contentSize.height],
            "layoutMeasurement": ["width": scrollView.bounds.width, "height": scrollView.bounds.height],
        ]
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

    private func keyboardType(_ value: Any?) -> UIKeyboardType {
        switch value as? String {
        case "email-address": return .emailAddress
        case "numeric": return .numberPad
        case "phone-pad": return .phonePad
        case "decimal-pad": return .decimalPad
        case "url": return .URL
        default: return .default
        }
    }

    private func returnKeyType(_ value: Any?) -> UIReturnKeyType {
        switch value as? String {
        case "done": return .done
        case "go": return .go
        case "next": return .next
        case "search": return .search
        case "send": return .send
        default: return .default
        }
    }

    private func capitalizationType(_ value: Any?) -> UITextAutocapitalizationType {
        switch value as? String {
        case "none": return .none
        case "words": return .words
        case "characters": return .allCharacters
        default: return .sentences
        }
    }

    private func color(_ value: Any?) -> UIColor? {
        guard let hex = value as? String else { return nil }
        return UIColor(hex: hex)
    }
}
