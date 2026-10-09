import Foundation
import JavaScriptCore
import SwiftUI
import UIKit

private let craftNativeCapabilityTimeoutMilliseconds = 30_000

private func craftNativeGridColumnCount(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return max(1, number.intValue) }
    guard let text = value as? String else { return 1 }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("repeat(") {
        let digits = trimmed.dropFirst("repeat(".count).prefix { $0.isNumber }
        if let count = Int(digits) { return max(1, count) }
    }
    let tracks = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
    return max(1, tracks.count)
}

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
    let flexGrow: CGFloat
    let flexShrink: CGFloat
    let flexBasis: CGFloat?
    let marginTop: CGFloat
    let marginRight: CGFloat
    let marginBottom: CGFloat
    let marginLeft: CGFloat
    let display: String
    let gridColumns: Int
    let gridAutoRows: CGFloat?

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
        flexGrow = number(raw["flexGrow"] ?? raw["flex"]) ?? 0
        flexShrink = number(raw["flexShrink"]) ?? 0
        flexBasis = number(raw["flexBasis"])
        let margin = number(raw["margin"]) ?? 0
        let horizontalMargin = number(raw["marginHorizontal"]) ?? margin
        let verticalMargin = number(raw["marginVertical"]) ?? margin
        marginTop = number(raw["marginTop"]) ?? verticalMargin
        marginRight = number(raw["marginRight"]) ?? horizontalMargin
        marginBottom = number(raw["marginBottom"]) ?? verticalMargin
        marginLeft = number(raw["marginLeft"]) ?? horizontalMargin
        display = raw["display"] as? String ?? "flex"
        gridColumns = craftNativeGridColumnCount(raw["gridTemplateColumns"] ?? raw["gridColumns"])
        gridAutoRows = number(raw["gridAutoRows"])
    }
}

private final class CraftNativeFlowView: UIStackView {
    var pressActiveOpacity: CGFloat?
    var pressBaseOpacity: CGFloat = 1
    var wrap = false { didSet { invalidateIntrinsicContentSize(); setNeedsLayout() } }
    var alignItems = "stretch" { didSet { alignment = alignmentValue; setNeedsLayout() } }
    var justifyContent = "flex-start" { didSet { distribution = distributionValue; setNeedsLayout() } }
    var gap: CGFloat = 0 { didSet { spacing = gap; invalidateIntrinsicContentSize(); setNeedsLayout() } }
    var rowGap: CGFloat? { didSet { invalidateIntrinsicContentSize(); setNeedsLayout() } }
    var columnGap: CGFloat? { didSet { invalidateIntrinsicContentSize(); setNeedsLayout() } }
    var grid = false { didSet { invalidateIntrinsicContentSize(); setNeedsLayout() } }
    var gridColumns = 1 { didSet { invalidateIntrinsicContentSize(); setNeedsLayout() } }
    var gridAutoRows: CGFloat? { didSet { invalidateIntrinsicContentSize(); setNeedsLayout() } }
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
        let children = subviews.filter {
            !$0.isHidden && !($0 is CraftNativeFlexSpacer) && !($0 is CraftNativeModalView)
                && (childStyles[ObjectIdentifier($0)] ?? CraftNativeLayoutStyle([:])).position != "absolute"
        }
        guard !children.isEmpty else { return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }
        if grid { return gridIntrinsicContentSize(children) }
        let sizes = children.map { measuredSize(for: $0, available: CGSize(width: 10_000, height: 10_000)) }
        let styles = children.map { childStyles[ObjectIdentifier($0)] ?? CraftNativeLayoutStyle([:]) }
        let main = sizes.enumerated().map { index, size in
            (axis == .horizontal ? size.width : size.height) + mainMargins(styles[index])
        }.reduce(0, +)
        let cross = sizes.enumerated().map { index, size in
            (axis == .horizontal ? size.height : size.width) + crossMargins(styles[index])
        }.max() ?? 0
        let mainGap = max(0, CGFloat(max(0, children.count - 1))) * mainGapValue
        if axis == .horizontal {
            return CGSize(width: padding.left + padding.right + main + mainGap, height: padding.top + padding.bottom + cross)
        }
        return CGSize(width: padding.left + padding.right + cross, height: padding.top + padding.bottom + main + mainGap)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = bounds.inset(by: padding)
        if grid {
            layoutGrid(content: content)
            return
        }
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

        for child in subviews where !child.isHidden && !(child is CraftNativeFlexSpacer) && !(child is CraftNativeModalView) {
            let style = childStyles[ObjectIdentifier(child)] ?? CraftNativeLayoutStyle([:])
            if style.position == "absolute" { continue }
            let size = measuredSize(for: child, available: content.size, style: style)
            let childMain = (axis == .horizontal ? size.width : size.height) + mainMargins(style)
            let childCross = (axis == .horizontal ? size.height : size.width) + crossMargins(style)
            let next = items.isEmpty ? childMain : main + mainGapValue + childMain
            if wrap && !items.isEmpty && next > availableMain { flush() }
            items.append(child); sizes.append(size)
            main = items.count == 1 ? childMain : main + mainGapValue + childMain
            cross = max(cross, childCross)
        }
        flush()

        var crossOffset: CGFloat = 0
        for (lineItems, lineSizes, lineMain, lineCross) in lines {
            let styles = lineItems.map { childStyles[ObjectIdentifier($0)] ?? CraftNativeLayoutStyle([:]) }
            let distributed = distributeMainAxisSizes(lineSizes, styles: styles, available: availableMain, lineMain: lineMain)
            let distributedMain = distributed.enumerated().reduce(0) { total, entry in
                total + (axis == .horizontal ? entry.element.width : entry.element.height) + mainMargins(styles[entry.offset])
            } + CGFloat(max(0, lineItems.count - 1)) * mainGapValue
            let free = max(0, availableMain - distributedMain)
            let (leading, between) = distribution(free: free, count: lineItems.count)
            var mainOffset = leading
            for (index, child) in lineItems.enumerated() {
                let style = childStyles[ObjectIdentifier(child)] ?? CraftNativeLayoutStyle([:])
                let size = distributed[index]
                let childCross = axis == .horizontal ? size.height : size.width
                let mainLeading = axis == .horizontal ? style.marginLeft : style.marginTop
                let mainTrailing = axis == .horizontal ? style.marginRight : style.marginBottom
                let crossLeading = axis == .horizontal ? style.marginTop : style.marginLeft
                let crossTrailing = axis == .horizontal ? style.marginBottom : style.marginRight
                let alignment = style.alignSelf ?? alignItems
                let crossSize: CGFloat = alignment == "stretch" && styleCrossDimension(style) == nil
                    ? max(0, lineCross - crossLeading - crossTrailing) : childCross
                let crossPosition: CGFloat
                switch alignment {
                case "center": crossPosition = crossLeading + (lineCross - crossLeading - crossTrailing - crossSize) / 2
                case "flex-end": crossPosition = lineCross - crossTrailing - crossSize
                default: crossPosition = crossLeading
                }
                let frame: CGRect
                if axis == .horizontal {
                    frame = CGRect(x: content.minX + mainOffset + mainLeading, y: content.minY + crossOffset + crossPosition, width: size.width, height: crossSize)
                } else {
                    frame = CGRect(x: content.minX + crossOffset + crossPosition, y: content.minY + mainOffset + mainLeading, width: crossSize, height: size.height)
                }
                child.frame = frame.integral
                mainOffset += mainLeading + (axis == .horizontal ? size.width : size.height) + mainTrailing + mainGapValue + between
            }
            crossOffset += lineCross + crossGapValue
        }

        for child in subviews where !child.isHidden && !(child is CraftNativeFlexSpacer) && !(child is CraftNativeModalView) {
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

    private func gridIntrinsicContentSize(_ children: [UIView]) -> CGSize {
        let columns = max(1, gridColumns)
        let horizontalGap = columnGap ?? gap
        let verticalGap = rowGap ?? gap
        var columnWidth: CGFloat = 0
        var rowHeights: [CGFloat] = []
        let flowChildren = children.filter {
            (childStyles[ObjectIdentifier($0)] ?? CraftNativeLayoutStyle([:])).position != "absolute"
        }
        for (index, child) in flowChildren.enumerated() {
            let style = childStyles[ObjectIdentifier(child)] ?? CraftNativeLayoutStyle([:])
            let size = measuredSize(for: child, available: CGSize(width: 10_000, height: 10_000), style: style)
            let row = index / columns
            while rowHeights.count <= row { rowHeights.append(gridAutoRows ?? 0) }
            columnWidth = max(columnWidth, size.width + style.marginLeft + style.marginRight)
            rowHeights[row] = max(rowHeights[row], size.height + style.marginTop + style.marginBottom)
        }
        let width = padding.left + padding.right + CGFloat(columns) * columnWidth + CGFloat(max(0, columns - 1)) * horizontalGap
        let height = padding.top + padding.bottom + rowHeights.reduce(0, +) + CGFloat(max(0, rowHeights.count - 1)) * verticalGap
        return CGSize(width: width, height: height)
    }

    private func layoutGrid(content: CGRect) {
        let children = subviews.filter { !$0.isHidden && !($0 is CraftNativeFlexSpacer) }
        let flowChildren = children.filter {
            (childStyles[ObjectIdentifier($0)] ?? CraftNativeLayoutStyle([:])).position != "absolute"
        }
        let columns = max(1, gridColumns)
        let horizontalGap = columnGap ?? gap
        let verticalGap = rowGap ?? gap
        let cellWidth = max(0, (content.width - CGFloat(max(0, columns - 1)) * horizontalGap) / CGFloat(columns))
        var rowHeights: [CGFloat] = []
        var sizes: [CGSize] = []
        for (index, child) in flowChildren.enumerated() {
            let style = childStyles[ObjectIdentifier(child)] ?? CraftNativeLayoutStyle([:])
            let size = measuredSize(
                for: child,
                available: CGSize(width: max(0, cellWidth - style.marginLeft - style.marginRight), height: content.height),
                style: style
            )
            sizes.append(size)
            let row = index / columns
            while rowHeights.count <= row { rowHeights.append(gridAutoRows ?? 0) }
            rowHeights[row] = max(rowHeights[row], size.height + style.marginTop + style.marginBottom)
        }
        var rowTop = content.minY
        for (index, child) in flowChildren.enumerated() {
            let style = childStyles[ObjectIdentifier(child)] ?? CraftNativeLayoutStyle([:])
            let row = index / columns
            let column = index % columns
            let rowHeight = rowHeights[row]
            let size = sizes[index]
            let align = style.alignSelf ?? alignItems
            let availableWidth = max(0, cellWidth - style.marginLeft - style.marginRight)
            let availableHeight = max(0, rowHeight - style.marginTop - style.marginBottom)
            let width = align == "stretch" && style.width == nil ? availableWidth : min(availableWidth, size.width)
            let height = align == "stretch" && style.height == nil ? availableHeight : min(availableHeight, size.height)
            let x = content.minX + CGFloat(column) * (cellWidth + horizontalGap) + style.marginLeft
                + (align == "center" ? (availableWidth - width) / 2 : align == "flex-end" ? availableWidth - width : 0)
            let y = rowTop + style.marginTop
                + (align == "center" ? (availableHeight - height) / 2 : align == "flex-end" ? availableHeight - height : 0)
            child.frame = CGRect(x: x, y: y, width: width, height: height).integral
            if column == columns - 1 || index == flowChildren.count - 1 { rowTop += rowHeight + verticalGap }
        }
        for child in children {
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

    private func mainMargins(_ style: CraftNativeLayoutStyle) -> CGFloat {
        axis == .horizontal ? style.marginLeft + style.marginRight : style.marginTop + style.marginBottom
    }

    private func crossMargins(_ style: CraftNativeLayoutStyle) -> CGFloat {
        axis == .horizontal ? style.marginTop + style.marginBottom : style.marginLeft + style.marginRight
    }

    private func styleCrossDimension(_ style: CraftNativeLayoutStyle) -> CGFloat? {
        axis == .horizontal ? style.height : style.width
    }

    private func measuredSize(for view: UIView, available: CGSize, style: CraftNativeLayoutStyle? = nil) -> CGSize {
        let style = style ?? childStyles[ObjectIdentifier(view)] ?? CraftNativeLayoutStyle([:])
        let intrinsic = view.intrinsicContentSize
        let fitted = view.sizeThatFits(available)
        let width = (axis == .horizontal ? style.flexBasis : nil) ?? style.width ?? (intrinsic.width > 0 && intrinsic.width != UIView.noIntrinsicMetric ? intrinsic.width : max(0, fitted.width))
        let height = (axis == .vertical ? style.flexBasis : nil) ?? style.height ?? (intrinsic.height > 0 && intrinsic.height != UIView.noIntrinsicMetric ? intrinsic.height : max(0, fitted.height))
        return CGSize(width: clamp(width, min: style.minWidth, max: style.maxWidth), height: clamp(height, min: style.minHeight, max: style.maxHeight))
    }

    private func distributeMainAxisSizes(
        _ sizes: [CGSize],
        styles: [CraftNativeLayoutStyle],
        available: CGFloat,
        lineMain: CGFloat
    ) -> [CGSize] {
        let free = available - lineMain
        let factors = free >= 0 ? styles.map(\.flexGrow) : styles.map(\.flexShrink)
        let total = factors.reduce(0, +)
        guard total > 0, free != 0 else { return sizes }
        return sizes.enumerated().map { index, size in
            let delta = free * factors[index] / total
            let style = styles[index]
            if axis == .horizontal {
                return CGSize(width: clamp(max(0, size.width + delta), min: style.minWidth, max: style.maxWidth), height: size.height)
            }
            return CGSize(width: size.width, height: clamp(max(0, size.height + delta), min: style.minHeight, max: style.maxHeight))
        }
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

private final class CraftNativeModalView: UIView {
    let contentStack = CraftNativeFlowView()
    private let blocker = UIView()
    private var renderedVisible = false
    var onRequestClose: (() -> Void)?

    var transparent = false {
        didSet { blocker.backgroundColor = transparent ? .clear : UIColor.black.withAlphaComponent(0.32) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        blocker.isUserInteractionEnabled = true
        blocker.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        blocker.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(blockerTapped)))
        addSubview(blocker)
        contentStack.backgroundColor = .clear
        addSubview(contentStack)
    }

    required init(coder: NSCoder) { super.init(coder: coder) }

    func setVisible(_ visible: Bool, opacity: CGFloat, animationType: String?) {
        guard renderedVisible != visible || isHidden != !visible else { return }
        renderedVisible = visible
        guard visible else {
            isHidden = true
            alpha = 0
            return
        }
        isHidden = false
        if animationType == "none" {
            alpha = opacity
        } else {
            alpha = 0
            UIView.animate(withDuration: animationType == "slide" ? 0.24 : 0.18) { self.alpha = opacity }
        }
    }

    @objc private func blockerTapped() { onRequestClose?() }

    override func layoutSubviews() {
        super.layoutSubviews()
        blocker.frame = bounds
        contentStack.frame = bounds
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

private final class CraftNativeTextView: UITextView {
    private let placeholderLabel = UILabel()
    var placeholder: String? {
        didSet { refreshPlaceholder() }
    }
    var placeholderColor: UIColor? {
        didSet { placeholderLabel.textColor = placeholderColor ?? .placeholderText }
    }
    var placeholderFont: UIFont? {
        didSet { placeholderLabel.font = placeholderFont ?? .systemFont(ofSize: 16) }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configurePlaceholder()
    }

    convenience init() {
        self.init(frame: .zero, textContainer: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePlaceholder()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = textContainerInset
        let padding = textContainer.lineFragmentPadding
        placeholderLabel.frame = CGRect(
            x: inset.left + padding,
            y: inset.top,
            width: max(0, bounds.width - inset.left - inset.right - padding * 2),
            height: max(0, bounds.height - inset.top - inset.bottom)
        )
    }

    func refreshPlaceholder() {
        placeholderLabel.text = placeholder
        placeholderLabel.isHidden = !(text?.isEmpty ?? true) || placeholder?.isEmpty != false
    }

    private func configurePlaceholder() {
        placeholderLabel.numberOfLines = 0
        placeholderLabel.font = font
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
        refreshPlaceholder()
    }
}

final class CraftNativeScreenController: UIViewController, UIScrollViewDelegate, UITextFieldDelegate, UITextViewDelegate, UIPickerViewDataSource, UIPickerViewDelegate {
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
    private var endEditingHandlers: [ObjectIdentifier: String] = [:]
    private var submitHandlers: [ObjectIdentifier: String] = [:]
    private var inputIdentities: [ObjectIdentifier: String] = [:]
    private var inputDrafts: [String: String] = [:]
    private var longPressHandlers: [ObjectIdentifier: String] = [:]
    private var textMaxLengths: [ObjectIdentifier: Int] = [:]
    private var scrollHandlers: [ObjectIdentifier: String] = [:]
    private var scrollBeginHandlers: [ObjectIdentifier: String] = [:]
    private var scrollEndHandlers: [ObjectIdentifier: String] = [:]
    private var scrollMomentumBeginHandlers: [ObjectIdentifier: String] = [:]
    private var scrollMomentumEndHandlers: [ObjectIdentifier: String] = [:]
    private var sliderCompleteHandlers: [ObjectIdentifier: String] = [:]
    private var sliderSteps: [ObjectIdentifier: Float] = [:]
    private var pickerOptions: [ObjectIdentifier: [(value: String, label: String)]] = [:]
    private var modalVisibility: [ObjectIdentifier: Bool] = [:]
    private var layoutHandlers: [ObjectIdentifier: String] = [:]
    private var lastLayoutFrames: [ObjectIdentifier: CGRect] = [:]
    private var tapRecognizers: [ObjectIdentifier: UITapGestureRecognizer] = [:]
    private var longPressRecognizers: [ObjectIdentifier: UILongPressGestureRecognizer] = [:]
    private var imageSources: [ObjectIdentifier: String] = [:]
    private var imageTasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var imageErrors: [ObjectIdentifier: String] = [:]
    private var tintedImages = Set<ObjectIdentifier>()
    private var imageLoadStartHandlers: [ObjectIdentifier: String] = [:]
    private var imageLoadHandlers: [ObjectIdentifier: String] = [:]
    private var imageLoadEndHandlers: [ObjectIdentifier: String] = [:]
    private var imageErrorHandlers: [ObjectIdentifier: String] = [:]
    private var renderedRoot: RenderedNode?
    private weak var lastFocusedInput: UIView?
    private var flatListRows: [ObjectIdentifier: [String: RenderedNode]] = [:]
    private var flatListOwners: [String: String] = [:]
    private let mutationDocument = CraftNativeMutationDocument()
    private let capabilityScope = UUID().uuidString
    private var pendingCapabilityRequests = Set<String>()
    private var pendingCapabilityDeadlines: [String: DispatchWorkItem] = [:]
    private var pendingTimers: [Int: DispatchWorkItem] = [:]
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var deepLinkListener: UUID?
    private var keyboardSafeAreaInset: CGFloat = 0

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
        pendingTimers.values.forEach { $0.cancel() }
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

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        refreshTraitDefaults()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshTraitDefaults()
    }

    private func refreshTraitDefaults() {
        view.backgroundColor = config.resolvedBackgroundColor
        if let document = mutationDocument.node("root") {
            renderCommitted(document)
        } else {
            rootStack.setNeedsLayout()
        }
        refreshTraitDefaults(in: renderedRoot)
    }

    private func refreshTraitDefaults(in node: RenderedNode?) {
        guard let node else { return }
        (node.view as? CraftNativeFlatList)?.refreshThemeDefaults()
        node.children.forEach { refreshTraitDefaults(in: $0) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        emitLayoutEvents()
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
        // JavaScriptCore has no timers of its own. The callbacks stay in
        // JavaScript; native only owns the main-queue deadline, so route
        // teardown cancels every pending timer with the controller.
        let scheduleTimer: @convention(block) (Int, Double) -> Void = { [weak self] id, delay in
            guard let self = self else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.pendingTimers.removeValue(forKey: id) != nil else { return }
                self.jsContext.objectForKeyedSubscript("__craftNativeFireTimer")?.call(withArguments: [id])
            }
            self.pendingTimers[id] = work
            let milliseconds = delay.isFinite ? Int(min(max(delay, 0), 2_147_483_647)) : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: work)
        }
        let cancelTimer: @convention(block) (Int) -> Void = { [weak self] id in
            self?.pendingTimers.removeValue(forKey: id)?.cancel()
        }
        jsContext.setObject(scheduleTimer, forKeyedSubscript: "craftNativeScheduleTimer" as NSString)
        jsContext.setObject(cancelTimer, forKeyedSubscript: "craftNativeCancelTimer" as NSString)
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
            if (typeof globalThis.setTimeout !== 'function') {
                (function() {
                    var timers = new Map();
                    var nextTimer = 0;
                    globalThis.setTimeout = function(callback, delay) {
                        var args = Array.prototype.slice.call(arguments, 2);
                        var id = ++nextTimer;
                        timers.set(id, function() {
                            if (typeof callback === 'function') callback.apply(undefined, args);
                        });
                        craftNativeScheduleTimer(id, Number(delay) || 0);
                        return id;
                    };
                    globalThis.clearTimeout = function(id) {
                        if (timers.delete(id)) craftNativeCancelTimer(id);
                    };
                    globalThis.__craftNativeFireTimer = function(id) {
                        var callback = timers.get(id);
                        if (!callback) return;
                        timers.delete(id);
                        callback();
                    };
                })();
            }
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
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.applyKeyboardSafeArea(notification)
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.applyKeyboardSafeArea(notification, hidden: true)
        })
        sendAppState(CraftNativeActions.currentAppState())
        deepLinkListener = DeepLinkManager.shared.addNativeListener { [weak self] url, initial in
            guard let self = self, self.navigationController?.topViewController === self else { return }
            var payload = CraftNativeActions.deepLinkData(url)
            payload["initial"] = initial
            self.send(type: "DEEP_LINK", payload: payload)
        }
    }

    private func applyKeyboardSafeArea(_ notification: Notification, hidden: Bool = false) {
        let inset: CGFloat
        if hidden {
            inset = 0
        } else if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
            let keyboardFrame = view.convert(frame.cgRectValue, from: nil)
            inset = max(0, view.bounds.intersection(keyboardFrame).height - view.safeAreaInsets.bottom)
        } else {
            return
        }
        guard abs(inset - keyboardSafeAreaInset) > 0.5 else { return }
        keyboardSafeAreaInset = inset
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        UIView.animate(withDuration: duration, delay: 0, options: UIView.AnimationOptions(rawValue: UInt(curve << 16))) {
            self.additionalSafeAreaInsets.bottom = inset
            self.view.layoutIfNeeded()
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
        let focused = firstResponder(in: rootStack) ?? lastFocusedInput
        var applied = Set<String>()
        for id in ids {
            let target = flatListOwners[id] ?? id
            guard applied.insert(target).inserted else { continue }
            guard let document = mutationDocument.node(target), let previous = renderedNode(target) else { return false }
            _ = reconcile(document, identity: previous.identity, path: target, previous: previous)
        }
        restoreFocus(focused)
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
        let focused = firstResponder(in: rootStack) ?? lastFocusedInput
        let previous = renderedRoot
        let next = reconcile(document, identity: "root", path: "root", previous: previous)
        if previous?.view !== next.view {
            if let old = previous { detach(old, from: rootStack) }
            rootStack.addArrangedSubview(next.view)
        }
        rootStack.setLayoutStyle(next.style, for: next.view)
        renderedRoot = next
        restoreFocus(focused)
    }

    private func clearRenderedTree() {
        if let root = renderedRoot { detach(root, from: rootStack) }
        renderedRoot = nil
    }

    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let responder = firstResponder(in: child) { return responder }
        }
        return nil
    }

    private func restoreFocus(_ focused: UIView?) {
        guard let focused, focused.window != nil, !focused.isFirstResponder else { return }
        _ = focused.becomeFirstResponder()
    }

    private func reconcile(_ node: [String: Any], identity: String, path: String, previous: RenderedNode?) -> RenderedNode {
        let type = node["type"] as? String ?? "View"
        let props = node["props"] as? [String: Any] ?? [:]
        let style = node["style"] as? [String: Any] ?? [:]
        let events = node["events"] as? [String: String] ?? [:]
        let children = node["children"] as? [Any] ?? []
        let current: RenderedNode
        let wantsMultilineTextView = type == "TextInput" && props["multiline"] as? Bool == true
        let canReuseInput = type != "TextInput" || ((previous?.view is UITextView) == wantsMultilineTextView)
        if let previous = previous, previous.identity == identity, previous.type == type, canReuseInput {
            current = previous
        } else {
            current = RenderedNode(identity: identity, type: type, view: makeView(type, props: props))
        }

        let result = current.view
        current.protocolId = node["id"] as? String
        current.style = style
        result.accessibilityIdentifier = accessibilityIdentifier(node, props: props) ?? path
        if type != "View" && type != "SafeAreaView" && type != "ScrollView" && type != "FlatList" && type != "Modal" {
            result.setContentHuggingPriority(.required, for: .vertical)
        }
        applyViewStyle(style, to: result, node: current)
        updateLayoutHandler(events["onLayout"], for: result)

        switch type {
        case "Text":
            let label = result as! UILabel
            label.numberOfLines = max(0, (props["numberOfLines"] as? NSNumber)?.intValue ?? 0)
            label.lineBreakMode = textLineBreakMode(props["ellipsizeMode"])
            configureText(label, text: children.compactMap { $0 as? String }.joined(), style: style)
        case "Button", "Link":
            let button = result as! UIButton
            let title = props["title"] as? String ?? children.compactMap { $0 as? String }.joined()
            let transformedTitle = transformedText(title, style: style)
            let titleColor = color(props["color"]) ?? color(style["color"]) ?? .systemBlue
            let font = textFont(
                style,
                default: .systemFont(ofSize: 16)
            )
            button.setAttributedTitle(NSAttributedString(
                string: transformedTitle,
                attributes: buttonTitleAttributes(style, color: titleColor, font: font, forceUnderline: type == "Link")
            ), for: .normal)
            button.contentHorizontalAlignment = buttonAlignment(style["textAlign"])
            button.isEnabled = props["disabled"] as? Bool != true
            updateHandler(nonEmptyHandler(events["onPress"]) ?? nonEmptyHandler(events["onClick"]), for: button)
        case "TextInput":
            if let textView = result as? UITextView {
                inputIdentities[ObjectIdentifier(textView)] = current.identity
                configureTextView(
                    textView,
                    props: props,
                    style: style,
                    events: events,
                    defaultValue: previous?.view === textView
                        ? nil
                        : inputDrafts[current.identity] ?? props["defaultValue"] as? String
                )
                break
            }
            let field = result as! UITextField
            field.placeholder = props["placeholder"] as? String
            if let placeholder = field.placeholder,
               let placeholderColor = color(props["placeholderTextColor"]) {
                field.attributedPlaceholder = NSAttributedString(
                    string: placeholder,
                    attributes: [.foregroundColor: placeholderColor]
                )
            } else {
                field.attributedPlaceholder = nil
            }
            field.tintColor = color(props["selectionColor"])
            let fieldId = ObjectIdentifier(field)
            inputIdentities[fieldId] = current.identity
            if let maxLength = (props["maxLength"] as? NSNumber)?.intValue, maxLength > 0 {
                textMaxLengths[fieldId] = maxLength
            } else {
                textMaxLengths.removeValue(forKey: fieldId)
            }
            field.delegate = self
            field.textColor = color(style["color"]) ?? .label
            field.font = textFont(style, default: .systemFont(ofSize: 16))
            field.textAlignment = textAlignment(style["textAlign"])
            field.defaultTextAttributes = inputTextAttributes(style, font: field.font ?? .systemFont(ofSize: 16), alignment: field.textAlignment)
            let desiredKeyboardType = keyboardType(props["keyboardType"])
            if field.keyboardType != desiredKeyboardType { field.keyboardType = desiredKeyboardType }
            let desiredReturnKeyType = returnKeyType(props["returnKeyType"])
            if field.returnKeyType != desiredReturnKeyType { field.returnKeyType = desiredReturnKeyType }
            let desiredAutocorrection: UITextAutocorrectionType = props["autoCorrect"] as? Bool == false ? .no : .default
            if field.autocorrectionType != desiredAutocorrection { field.autocorrectionType = desiredAutocorrection }
            let desiredCapitalization = capitalizationType(props["autoCapitalize"])
            if field.autocapitalizationType != desiredCapitalization { field.autocapitalizationType = desiredCapitalization }
            let desiredSecureEntry = props["secureTextEntry"] as? Bool == true
            if field.isSecureTextEntry != desiredSecureEntry { field.isSecureTextEntry = desiredSecureEntry }
            let desiredEnabled = props["editable"] as? Bool != false
            if field.isEnabled != desiredEnabled { field.isEnabled = desiredEnabled }
            if let value = props["value"] as? String {
                updateField(field, value: value)
            } else if previous?.view !== field {
                updateField(field, value: inputDrafts[current.identity] ?? props["defaultValue"] as? String)
            }
            updateHandler(nonEmptyHandler(events["onChange"]) ?? nonEmptyHandler(events["onChangeText"]), for: field)
            updateAuxiliaryHandler(events["onFocus"], in: &focusHandlers, for: field)
            updateAuxiliaryHandler(events["onBlur"], in: &blurHandlers, for: field)
            updateAuxiliaryHandler(events["onEndEditing"], in: &endEditingHandlers, for: field)
            updateAuxiliaryHandler(events["onSubmitEditing"], in: &submitHandlers, for: field)
            if props["autoFocus"] as? Bool == true, !field.isFirstResponder {
                DispatchQueue.main.async { _ = field.becomeFirstResponder() }
            }
        case "Picker":
            let picker = result as! UIPickerView
            let options = children.compactMap { child -> (value: String, label: String)? in
                guard let node = child as? [String: Any], node["type"] as? String == "Text" else { return nil }
                let optionProps = node["props"] as? [String: Any] ?? [:]
                let label = (node["children"] as? [Any] ?? []).compactMap { $0 as? String }.joined()
                guard !label.isEmpty else { return nil }
                return (value: optionProps["value"] as? String ?? label, label: label)
            }
            let pickerID = ObjectIdentifier(picker)
            pickerOptions[pickerID] = options
            picker.reloadAllComponents()
            if let selected = (props["selectedValue"] as? String) ?? (props["value"] as? String),
               let row = options.firstIndex(where: { $0.value == selected }) {
                picker.selectRow(row, inComponent: 0, animated: false)
            } else if !options.isEmpty {
                picker.selectRow(0, inComponent: 0, animated: false)
            }
            picker.isUserInteractionEnabled = props["disabled"] as? Bool != true
            updateHandler(nonEmptyHandler(events["onValueChange"]) ?? nonEmptyHandler(events["onChange"]), for: picker)
        case "Modal":
            let modal = result as! CraftNativeModalView
            modal.transparent = props["transparent"] as? Bool == true
            let visible = props["visible"] as? Bool == true
            let modalID = ObjectIdentifier(modal)
            let wasVisible = modalVisibility[modalID]
            modalVisibility[modalID] = visible
            modal.setVisible(visible, opacity: number(style["opacity"]) ?? 1, animationType: props["animationType"] as? String)
            modal.onRequestClose = nonEmptyHandler(events["onRequestClose"]).map { handler in
                { [weak self] in self?.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]]) }
            }
            if wasVisible != visible, visible || wasVisible == true {
                let lifecycleHandler = visible ? events["onShow"] : events["onDismiss"]
                if let lifecycleHandler = nonEmptyHandler(lifecycleHandler) {
                    send(type: "EVENT", payload: ["handlerName": lifecycleHandler, "nativeEvent": [:]])
                }
            }
            configureStack(modal.contentStack, style: style)
            reconcileChildren(children, in: modal.contentStack, parent: current, path: path, style: style)
        case "TouchableOpacity", "TouchableHighlight", "Pressable":
            let pressable = result as! CraftNativeFlowView
            configureStack(pressable, style: style)
            reconcileChildren(children, in: pressable, parent: current, path: path, style: style)
            pressable.pressActiveOpacity = props["disabled"] as? Bool == true
                ? nil : number(props["activeOpacity"]) ?? 0.5
            pressable.pressBaseOpacity = number(style["opacity"]) ?? 1
        case "Switch":
            let toggle = result as! UISwitch
            toggle.isOn = props["value"] as? Bool ?? props["checked"] as? Bool ?? false
            toggle.isEnabled = props["disabled"] as? Bool != true
            if let track = props["trackColor"] as? [String: Any] {
                toggle.onTintColor = color(track["true"])
                toggle.tintColor = color(track["false"])
            } else {
                toggle.onTintColor = nil
                toggle.tintColor = nil
            }
            toggle.thumbTintColor = color(props["thumbColor"])
            if let background = color(props["ios_backgroundColor"]) { toggle.tintColor = background }
            updateHandler(nonEmptyHandler(events["onValueChange"]) ?? nonEmptyHandler(events["onChange"]), for: toggle)
        case "Slider":
            let slider = result as! UISlider
            slider.minimumValue = (props["minimumValue"] as? NSNumber)?.floatValue ?? 0
            slider.maximumValue = max(slider.minimumValue + .leastNonzeroMagnitude, (props["maximumValue"] as? NSNumber)?.floatValue ?? 1)
            let value = (props["value"] as? NSNumber)?.floatValue ?? slider.minimumValue
            if let step = (props["step"] as? NSNumber)?.floatValue, step > 0 { sliderSteps[ObjectIdentifier(slider)] = step }
            else { sliderSteps.removeValue(forKey: ObjectIdentifier(slider)) }
            slider.value = snappedSliderValue(value, for: slider)
            slider.minimumTrackTintColor = color(props["minimumTrackTintColor"])
            slider.maximumTrackTintColor = color(props["maximumTrackTintColor"])
            slider.thumbTintColor = color(props["thumbTintColor"])
            slider.isEnabled = props["disabled"] as? Bool != true
            updateHandler(nonEmptyHandler(events["onValueChange"]) ?? nonEmptyHandler(events["onChange"]), for: slider)
            updateAuxiliaryHandler(events["onSlidingComplete"], in: &sliderCompleteHandlers, for: slider)
        case "ActivityIndicator":
            let indicator = result as! UIActivityIndicatorView
            let requestedSize = props["size"]
            indicator.style = (requestedSize as? String) == "large" ? .large : .medium
            let scale: CGFloat
            if let numericSize = requestedSize as? NSNumber {
                scale = max(0.5, CGFloat(numericSize.doubleValue / 20.0))
            } else if (requestedSize as? String) == "small" {
                scale = 0.75
            } else {
                scale = 1
            }
            indicator.transform = CGAffineTransform(scaleX: scale, y: scale)
            indicator.color = color(props["color"]) ?? .tintColor
            indicator.hidesWhenStopped = props["hidesWhenStopped"] as? Bool ?? true
            if props["animating"] as? Bool == false {
                indicator.stopAnimating()
            } else {
                indicator.startAnimating()
            }
        case "Image":
            let image = result as! UIImageView
            let imageID = ObjectIdentifier(image)
            if let tint = color(style["tintColor"]) {
                tintedImages.insert(imageID)
                image.tintColor = tint
            } else {
                tintedImages.remove(imageID)
                image.tintColor = nil
            }
            if let current = image.image { image.image = imageForDisplay(current, view: image) }
            let requestedResizeMode = style["resizeMode"] as? String ?? props["resizeMode"] as? String
            image.contentMode = imageContentMode(requestedResizeMode)
            image.clipsToBounds = image.contentMode == .scaleAspectFill
            updateAuxiliaryHandler(events["onLoadStart"], in: &imageLoadStartHandlers, for: image)
            updateAuxiliaryHandler(events["onLoad"], in: &imageLoadHandlers, for: image)
            updateAuxiliaryHandler(events["onLoadEnd"], in: &imageLoadEndHandlers, for: image)
            updateAuxiliaryHandler(events["onError"], in: &imageErrorHandlers, for: image)
            updateImage(image, source: props["source"])
        case "ScrollView":
            let scroll = result as! CraftNativeScrollView
            let flexDirection = style["flexDirection"] as? String
            let direction = (props["horizontal"] as? Bool) == true
                || flexDirection == "row"
                || flexDirection == "row-reverse"
                ? NSLayoutConstraint.Axis.horizontal : .vertical
            scroll.setAxis(direction)
            scroll.delegate = self
            scroll.isScrollEnabled = props["scrollEnabled"] as? Bool != false
            scroll.bounces = props["bounces"] as? Bool ?? true
            scroll.isPagingEnabled = props["pagingEnabled"] as? Bool ?? false
            scroll.keyboardDismissMode = keyboardDismissMode(props["keyboardDismissMode"])
            scroll.showsVerticalScrollIndicator = props["showsVerticalScrollIndicator"] as? Bool != false
            scroll.showsHorizontalScrollIndicator = props["showsHorizontalScrollIndicator"] as? Bool != false
            scroll.alwaysBounceVertical = props["alwaysBounceVertical"] as? Bool ?? (direction == .vertical)
            scroll.alwaysBounceHorizontal = props["alwaysBounceHorizontal"] as? Bool ?? (direction == .horizontal)
            updateAuxiliaryHandler(events["onScroll"], in: &scrollHandlers, for: scroll)
            updateAuxiliaryHandler(events["onScrollBeginDrag"], in: &scrollBeginHandlers, for: scroll)
            updateAuxiliaryHandler(events["onScrollEndDrag"], in: &scrollEndHandlers, for: scroll)
            updateAuxiliaryHandler(events["onMomentumScrollBegin"], in: &scrollMomentumBeginHandlers, for: scroll)
            updateAuxiliaryHandler(events["onMomentumScrollEnd"], in: &scrollMomentumEndHandlers, for: scroll)
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
        updateLongPressHandler(props["disabled"] as? Bool == true ? nil : events["onLongPress"], for: result)
        if type != "Button" && type != "Link" && type != "TextInput" && type != "Picker" && type != "Modal" && type != "Switch" && type != "Slider" && type != "ActivityIndicator" {
            let disabled = props["disabled"] as? Bool == true
            updatePressHandler(disabled ? nil : nonEmptyHandler(events["onPress"]) ?? nonEmptyHandler(events["onClick"]), for: result)
            if disabled { result.isUserInteractionEnabled = false }
        }
        applyAccessibility(props, type: type, to: result)
        return current
    }

    private func makeView(_ type: String, props: [String: Any]) -> UIView {
        switch type {
        case "Text":
            let label = UILabel()
            label.numberOfLines = 0
            return label
        case "Button", "Link":
            let button = UIButton(type: .system)
            button.addTarget(self, action: #selector(buttonPressed(_:)), for: .touchUpInside)
            return button
        case "TextInput":
            if props["multiline"] as? Bool == true {
                let textView = CraftNativeTextView()
                textView.delegate = self
                return textView
            }
            let field = UITextField()
            field.borderStyle = .roundedRect
            field.addTarget(self, action: #selector(textChanged(_:)), for: .editingChanged)
            field.addTarget(self, action: #selector(textFocused(_:)), for: .editingDidBegin)
            field.addTarget(self, action: #selector(textBlurred(_:)), for: .editingDidEnd)
            field.addTarget(self, action: #selector(textSubmitted(_:)), for: .editingDidEndOnExit)
            return field
        case "Picker":
            let picker = UIPickerView()
            picker.dataSource = self
            picker.delegate = self
            return picker
        case "Modal":
            return CraftNativeModalView()
        case "Switch":
            let toggle = UISwitch()
            toggle.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
            return toggle
        case "Slider":
            let slider = UISlider()
            slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
            slider.addTarget(self, action: #selector(sliderFinished(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
            return slider
        case "ActivityIndicator":
            return UIActivityIndicatorView(style: .medium)
        case "Image":
            return UIImageView()
        case "ScrollView":
            return CraftNativeScrollView()
        case "FlatList":
            return CraftNativeFlatList()
        case "View", "SafeAreaView":
            return CraftNativeFlowView()
        case "TouchableOpacity", "TouchableHighlight", "Pressable":
            return CraftNativeFlowView()
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
        for modal in stack.arrangedSubviews where modal is CraftNativeModalView {
            stack.removeArrangedSubview(modal)
        }
        let flowChildren = next.filter { $0.type != "Modal" }
        for (index, child) in flowChildren.enumerated() {
            if index < stack.arrangedSubviews.count, stack.arrangedSubviews[index] === child.view {
                stack.setLayoutStyle(child.style, for: child.view)
                continue
            }
            if child.view.superview === stack { stack.removeArrangedSubview(child.view) }
            stack.insertArrangedSubview(child.view, at: min(index, stack.arrangedSubviews.count))
            stack.setLayoutStyle(child.style, for: child.view)
        }
        for child in next where child.type == "Modal" {
            guard let modal = child.view as? CraftNativeModalView else { continue }
            if modal.superview !== stack {
                modal.removeFromSuperview()
                stack.addSubview(modal)
            }
            modal.frame = stack.bounds
            modal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            stack.bringSubviewToFront(modal)
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
        list.bounces = props["bounces"] as? Bool ?? true
        list.keyboardDismissMode = keyboardDismissMode(props["keyboardDismissMode"])
        list.onScrollEvent = nonEmptyHandler(events["onScroll"]).map { handler in
            { [weak self] scrollView in self?.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": self?.scrollEvent(scrollView) ?? [:]]) }
        }
        list.onScrollBeginDrag = nonEmptyHandler(events["onScrollBeginDrag"]).map { handler in
            { [weak self] scrollView in self?.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": self?.scrollEvent(scrollView) ?? [:]]) }
        }
        list.onScrollEndDrag = nonEmptyHandler(events["onScrollEndDrag"]).map { handler in
            { [weak self] scrollView in self?.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": self?.scrollEvent(scrollView) ?? [:]]) }
        }
        list.onMomentumScrollBegin = nonEmptyHandler(events["onMomentumScrollBegin"]).map { handler in
            { [weak self] scrollView in self?.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": self?.scrollEvent(scrollView) ?? [:]]) }
        }
        list.onMomentumScrollEnd = nonEmptyHandler(events["onMomentumScrollEnd"]).map { handler in
            { [weak self] scrollView in self?.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": self?.scrollEvent(scrollView) ?? [:]]) }
        }

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
                if let previous, previous.view !== next.view {
                    self.forgetHandlers(previous)
                }
                self.flatListRows[listKey, default: [:]][identity] = next
                return next.view
            },
            recycleItem: { [weak self] identity in
                guard let self = self,
                      let row = self.flatListRows[listKey]?.removeValue(forKey: identity) else { return }
                self.forgetHandlers(row, preservingInputDrafts: true)
            },
            endReached: nonEmptyHandler(events["onEndReached"]).map { [weak self] handler in
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
        if node.type == "Modal" {
            node.view.removeFromSuperview()
            return
        }
        stack.removeLayoutStyle(for: node.view)
        stack.removeArrangedSubview(node.view)
        node.view.removeFromSuperview()
    }

    private func forgetHandlers(_ node: RenderedNode, preservingInputDrafts: Bool = false) {
        if let list = node.view as? CraftNativeFlatList {
            let listKey = ObjectIdentifier(list)
            list.discardAll()
            flatListRows.removeValue(forKey: listKey)
            if let owner = node.protocolId { flatListOwners = flatListOwners.filter { $0.value != owner } }
        }
        let id = ObjectIdentifier(node.view)
        handlers.removeValue(forKey: id)
        layoutHandlers.removeValue(forKey: id)
        lastLayoutFrames.removeValue(forKey: id)
        focusHandlers.removeValue(forKey: id)
        blurHandlers.removeValue(forKey: id)
        endEditingHandlers.removeValue(forKey: id)
        submitHandlers.removeValue(forKey: id)
        inputIdentities.removeValue(forKey: id)
        if node.type == "TextInput" && !preservingInputDrafts { inputDrafts.removeValue(forKey: node.identity) }
        longPressHandlers.removeValue(forKey: id)
        textMaxLengths.removeValue(forKey: id)
        scrollHandlers.removeValue(forKey: id)
        scrollBeginHandlers.removeValue(forKey: id)
        scrollEndHandlers.removeValue(forKey: id)
        scrollMomentumBeginHandlers.removeValue(forKey: id)
        scrollMomentumEndHandlers.removeValue(forKey: id)
        sliderCompleteHandlers.removeValue(forKey: id)
        sliderSteps.removeValue(forKey: id)
        pickerOptions.removeValue(forKey: id)
        modalVisibility.removeValue(forKey: id)
        if let recognizer = tapRecognizers.removeValue(forKey: id) {
            node.view.removeGestureRecognizer(recognizer)
        }
        if let recognizer = longPressRecognizers.removeValue(forKey: id) {
            node.view.removeGestureRecognizer(recognizer)
        }
        imageSources.removeValue(forKey: id)
        imageTasks.removeValue(forKey: id)?.cancel()
        imageErrors.removeValue(forKey: id)
        tintedImages.remove(id)
        imageLoadStartHandlers.removeValue(forKey: id)
        imageLoadHandlers.removeValue(forKey: id)
        imageLoadEndHandlers.removeValue(forKey: id)
        imageErrorHandlers.removeValue(forKey: id)
        for child in node.children { forgetHandlers(child, preservingInputDrafts: preservingInputDrafts) }
    }

    private func updateHandler(_ handler: String?, for view: UIView) {
        let id = ObjectIdentifier(view)
        if let handler, !handler.isEmpty { handlers[id] = handler }
        else { handlers.removeValue(forKey: id) }
    }

    private func snappedSliderValue(_ value: Float, for slider: UISlider) -> Float {
        let bounded = min(slider.maximumValue, max(slider.minimumValue, value))
        guard let step = sliderSteps[ObjectIdentifier(slider)], step > 0 else { return bounded }
        let steps = ((bounded - slider.minimumValue) / step).rounded()
        return min(slider.maximumValue, max(slider.minimumValue, slider.minimumValue + steps * step))
    }

    private func updateLayoutHandler(_ handler: String?, for view: UIView) {
        let id = ObjectIdentifier(view)
        guard let handler, !handler.isEmpty else {
            layoutHandlers.removeValue(forKey: id)
            lastLayoutFrames.removeValue(forKey: id)
            return
        }
        if layoutHandlers[id] != handler { lastLayoutFrames.removeValue(forKey: id) }
        layoutHandlers[id] = handler
    }

    private func emitLayoutEvents() {
        guard let renderedRoot else { return }
        emitLayoutEvents(for: renderedRoot)
    }

    private func emitLayoutEvents(for node: RenderedNode) {
        let id = ObjectIdentifier(node.view)
        if let handler = layoutHandlers[id], node.view.window != nil {
            let frame = node.view.frame
            if lastLayoutFrames[id] != frame {
                lastLayoutFrames[id] = frame
                send(type: "EVENT", payload: [
                    "handlerName": handler,
                    "nativeEvent": ["layout": [
                        "x": frame.minX,
                        "y": frame.minY,
                        "width": frame.width,
                        "height": frame.height,
                    ]],
                ])
            }
        }
        for child in node.children { emitLayoutEvents(for: child) }
        if let list = node.view as? CraftNativeFlatList {
            flatListRows[ObjectIdentifier(list)]?.values.forEach { emitLayoutEvents(for: $0) }
        }
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

    private func nonEmptyHandler(_ handler: String?) -> String? {
        guard let handler, !handler.isEmpty else { return nil }
        return handler
    }

    private func updatePressHandler(_ handler: String?, for view: UIView) {
        let id = ObjectIdentifier(view)
        let handler = handler?.isEmpty == false ? handler : nil
        updateHandler(handler, for: view)
        if handler != nil, tapRecognizers[id] == nil {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(viewPressed(_:)))
            tapRecognizers[id] = recognizer
            view.addGestureRecognizer(recognizer)
        } else if handler == nil, let recognizer = tapRecognizers.removeValue(forKey: id) {
            view.removeGestureRecognizer(recognizer)
        }
        // A container keeps receiving touches without a handler of its own,
        // or every control inside it (and the screen root) would be dead.
        if !(view is UIScrollView) { view.isUserInteractionEnabled = handler != nil || longPressHandlers[id] != nil || view is CraftNativeFlowView }
    }

    private func updateLongPressHandler(_ handler: String?, for view: UIView) {
        let id = ObjectIdentifier(view)
        if let handler, !handler.isEmpty {
            longPressHandlers[id] = handler
            if !(view is UIScrollView) { view.isUserInteractionEnabled = true }
            if longPressRecognizers[id] == nil {
                let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(viewLongPressed(_:)))
                longPressRecognizers[id] = recognizer
                view.addGestureRecognizer(recognizer)
            }
        } else {
            longPressHandlers.removeValue(forKey: id)
            if let recognizer = longPressRecognizers.removeValue(forKey: id) {
                view.removeGestureRecognizer(recognizer)
            }
            if !(view is UIScrollView) { view.isUserInteractionEnabled = handlers[id] != nil || view is CraftNativeFlowView }
        }
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

    private func updateTextView(_ textView: UITextView, value: String?) {
        guard let value = value, textView.text != value, textView.markedTextRange == nil else { return }
        let selection = textView.selectedTextRange
        let start = selection.map { textView.offset(from: textView.beginningOfDocument, to: $0.start) }
        let end = selection.map { textView.offset(from: textView.beginningOfDocument, to: $0.end) }
        textView.text = value
        if let start = start, let end = end,
           let from = textView.position(from: textView.beginningOfDocument, offset: min(start, value.utf16.count)),
           let to = textView.position(from: textView.beginningOfDocument, offset: min(end, value.utf16.count)) {
            textView.selectedTextRange = textView.textRange(from: from, to: to)
        }
    }

    private func configureTextView(
        _ textView: UITextView,
        props: [String: Any],
        style: [String: Any],
        events: [String: String],
        defaultValue: String?
    ) {
        let id = ObjectIdentifier(textView)
        textView.delegate = self
        textView.textColor = color(style["color"]) ?? .label
        textView.font = textFont(style, default: .systemFont(ofSize: 16))
        textView.textAlignment = textAlignment(style["textAlign"])
        textView.tintColor = color(props["selectionColor"])
        textView.keyboardType = keyboardType(props["keyboardType"])
        textView.returnKeyType = returnKeyType(props["returnKeyType"])
        textView.autocorrectionType = props["autoCorrect"] as? Bool == false ? .no : .default
        textView.autocapitalizationType = capitalizationType(props["autoCapitalize"])
        textView.isSecureTextEntry = props["secureTextEntry"] as? Bool == true
        textView.isEditable = props["editable"] as? Bool != false
        textView.isScrollEnabled = false
        if let numberOfLines = (props["numberOfLines"] as? NSNumber)?.intValue, numberOfLines > 0 {
            textView.textContainer.maximumNumberOfLines = numberOfLines
        } else {
            textView.textContainer.maximumNumberOfLines = 0
        }
        if let maxLength = (props["maxLength"] as? NSNumber)?.intValue, maxLength > 0 {
            textMaxLengths[id] = maxLength
        } else {
            textMaxLengths.removeValue(forKey: id)
        }
        if let craftTextView = textView as? CraftNativeTextView {
            craftTextView.placeholder = props["placeholder"] as? String
            craftTextView.placeholderColor = color(props["placeholderTextColor"])
            craftTextView.placeholderFont = textView.font
        }
        updateTextView(textView, value: (props["value"] as? String) ?? defaultValue)
        let selectedRange = textView.selectedRange
        let attributes = inputTextAttributes(style, font: textView.font ?? .systemFont(ofSize: 16), alignment: textView.textAlignment)
        textView.typingAttributes = attributes
        if !textView.text.isEmpty {
            textView.attributedText = NSAttributedString(string: textView.text, attributes: attributes)
            textView.selectedRange = selectedRange
        }
        (textView as? CraftNativeTextView)?.refreshPlaceholder()
        updateHandler(nonEmptyHandler(events["onChange"]) ?? nonEmptyHandler(events["onChangeText"]), for: textView)
        updateAuxiliaryHandler(events["onFocus"], in: &focusHandlers, for: textView)
        updateAuxiliaryHandler(events["onBlur"], in: &blurHandlers, for: textView)
        updateAuxiliaryHandler(events["onEndEditing"], in: &endEditingHandlers, for: textView)
        updateAuxiliaryHandler(events["onSubmitEditing"], in: &submitHandlers, for: textView)
        if props["autoFocus"] as? Bool == true, !textView.isFirstResponder {
            DispatchQueue.main.async { _ = textView.becomeFirstResponder() }
        }
    }

    private func configureStack(_ stack: CraftNativeFlowView, style: [String: Any]) {
        let direction = style["flexDirection"] as? String
        stack.axis = direction == "row" || direction == "row-reverse" ? .horizontal : .vertical
        stack.wrap = style["flexWrap"] as? String == "wrap" || style["flexWrap"] as? Bool == true
        stack.alignItems = style["alignItems"] as? String ?? "stretch"
        stack.justifyContent = style["justifyContent"] as? String ?? "flex-start"
        let gap = number(style["gap"]) ?? 0
        stack.gap = gap
        stack.rowGap = number(style["rowGap"]) ?? gap
        stack.columnGap = number(style["columnGap"]) ?? gap
        stack.grid = style["display"] as? String == "grid"
        stack.gridColumns = craftNativeGridColumnCount(style["gridTemplateColumns"] ?? style["gridColumns"])
        stack.gridAutoRows = number(style["gridAutoRows"])
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
        let elevation = max(0, number(style["elevation"]) ?? 0)
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = elevation > 0 ? Float(min(0.28, 0.12 + elevation * 0.02)) : 0
        view.layer.shadowRadius = elevation * 0.5
        view.layer.shadowOffset = CGSize(width: 0, height: elevation * 0.25)
        view.clipsToBounds = style["overflow"] as? String == "hidden"
        view.layer.masksToBounds = view.clipsToBounds
    }

    private func configureText(_ label: UILabel, text: String, style: [String: Any]) {
        let transformed = transformedText(text, style: style)
        label.textColor = color(style["color"]) ?? .label
        label.font = textFont(style, default: .systemFont(ofSize: 16))
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

    private func textLineBreakMode(_ value: Any?) -> NSLineBreakMode {
        switch value as? String {
        case "head": return .byTruncatingHead
        case "middle": return .byTruncatingMiddle
        case "tail": return .byTruncatingTail
        case "clip": return .byClipping
        default: return .byTruncatingTail
        }
    }

    private func buttonTitleAttributes(
        _ style: [String: Any],
        color: UIColor,
        font: UIFont,
        forceUnderline: Bool
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: font,
        ]
        if let spacing = number(style["letterSpacing"]) { attributes[.kern] = spacing }
        if let lineHeight = number(style["lineHeight"]) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
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
        if forceUnderline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    private func inputTextAttributes(
        _ style: [String: Any],
        font: UIFont,
        alignment: NSTextAlignment
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color(style["color"]) ?? .label,
            .font: font,
        ]
        if let spacing = number(style["letterSpacing"]) { attributes[.kern] = spacing }
        if let lineHeight = number(style["lineHeight"]) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            paragraph.alignment = alignment
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
        return attributes
    }

    private func transformedText(_ text: String, style: [String: Any]) -> String {
        switch style["textTransform"] as? String {
        case "uppercase": return text.uppercased()
        case "lowercase": return text.lowercased()
        case "capitalize": return text.split(separator: " ", omittingEmptySubsequences: false).map { word in
            guard let first = word.first else { return String(word) }
            return String(first).uppercased() + String(word.dropFirst())
        }.joined(separator: " ")
        default: return text
        }
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

    private func buttonAlignment(_ value: Any?) -> UIControl.ContentHorizontalAlignment {
        switch value as? String {
        case "left": return .left
        case "right": return .right
        case "center": return .center
        default: return .center
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

    private func keyboardDismissMode(_ value: Any?) -> UIScrollView.KeyboardDismissMode {
        switch value as? String {
        case "on-drag": return .onDrag
        case "interactive": return .interactive
        default: return .none
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
        imageErrors.removeValue(forKey: id)
        view.image = nil
        view.accessibilityValue = nil
        emitImageEvent(view, handler: imageLoadStartHandlers[id])

        if uri.hasPrefix("data:image/") {
            guard let comma = uri.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])),
                  let image = UIImage(data: data) else {
                imageFailure(view, uri: uri, message: "Image data is invalid")
                return
            }
            view.image = imageForDisplay(image, view: view)
            emitImageEvent(view, handler: imageLoadHandlers[id])
            emitImageEvent(view, handler: imageLoadEndHandlers[id])
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
                    view.image = self.imageForDisplay(image, view: view)
                    self.emitImageEvent(view, handler: self.imageLoadHandlers[ObjectIdentifier(view)])
                    self.emitImageEvent(view, handler: self.imageLoadEndHandlers[ObjectIdentifier(view)])
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
            view.image = imageForDisplay(image, view: view)
            emitImageEvent(view, handler: imageLoadHandlers[id])
            emitImageEvent(view, handler: imageLoadEndHandlers[id])
            return
        }
        imageFailure(view, uri: uri, message: "Unsupported image source")
    }

    private func imageFailure(_ view: UIImageView, uri: String?, message: String) {
        imageErrors[ObjectIdentifier(view)] = message
        view.image = nil
        view.accessibilityValue = message
        let id = ObjectIdentifier(view)
        emitImageEvent(view, handler: imageErrorHandlers[id], nativeEvent: ["error": ["message": message]])
        emitImageEvent(view, handler: imageLoadEndHandlers[id])
        NSLog("[craft native] %@: %@", message, uri ?? "<missing>")
    }

    private func imageForDisplay(_ image: UIImage, view: UIImageView) -> UIImage {
        image.withRenderingMode(tintedImages.contains(ObjectIdentifier(view)) ? .alwaysTemplate : .alwaysOriginal)
    }

    private func emitImageEvent(
        _ view: UIImageView,
        handler: String?,
        nativeEvent: [String: Any] = [:]
    ) {
        guard let handler, !handler.isEmpty else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": nativeEvent])
    }

    private func applyAccessibility(_ props: [String: Any], type: String, to view: UIView) {
        view.accessibilityLabel = (props["accessibilityLabel"] as? String)
            ?? (type == "Image" ? props["alt"] as? String : nil)
        view.accessibilityHint = props["accessibilityHint"] as? String
        if let value = props["accessibilityValue"] {
            view.accessibilityValue = (value as? String) ?? (value as? NSNumber)?.stringValue
        } else if type != "TextInput" {
            view.accessibilityValue = nil
        }
        let role = props["accessibilityRole"] as? String
        view.isAccessibilityElement = role != "none" && (view.accessibilityLabel != nil || role != nil || ["Text", "Button", "Link", "Image", "TextInput", "Picker", "Switch", "Slider"].contains(type))
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
            if state["disabled"] as? Bool == true {
                traits.insert(.notEnabled)
                if let control = view as? UIControl {
                    control.isEnabled = false
                } else if handlers[ObjectIdentifier(view)] != nil || longPressHandlers[ObjectIdentifier(view)] != nil {
                    view.isUserInteractionEnabled = false
                }
            }
            if state["selected"] as? Bool == true { traits.insert(.selected) }
            if state["checked"] as? Bool == true { traits.insert(.selected) }
        }
        if let control = view as? UIControl, !control.isEnabled { traits.insert(.notEnabled) }
        if type == "Image", let message = imageErrors[ObjectIdentifier(view)] {
            let current = view.accessibilityValue
            if current?.contains(message) != true {
                view.accessibilityValue = [current, message].compactMap { $0 }.joined(separator: ", ")
            }
        }
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
        let focused = firstResponder(in: rootStack) ?? lastFocusedInput
        guard let handler = handlers[ObjectIdentifier(sender)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]])
        restoreFocus(focused)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak focused] in
            self?.restoreFocus(focused)
        }
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard let maxLength = textMaxLengths[ObjectIdentifier(textField)],
              let current = textField.text,
              let stringRange = Range(range, in: current) else { return true }
        return current.replacingCharacters(in: stringRange, with: string).utf16.count <= maxLength
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n", let handler = submitHandlers[ObjectIdentifier(textView)] {
            send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["text": textView.text ?? ""]])
        }
        guard let maxLength = textMaxLengths[ObjectIdentifier(textView)],
              let current = textView.text,
              let stringRange = Range(range, in: current) else { return true }
        return current.replacingCharacters(in: stringRange, with: text).utf16.count <= maxLength
    }

    func textViewDidChange(_ textView: UITextView) {
        lastFocusedInput = textView
        let id = ObjectIdentifier(textView)
        inputIdentities[id].map { inputDrafts[$0] = textView.text ?? "" }
        (textView as? CraftNativeTextView)?.refreshPlaceholder()
        guard let handler = handlers[id] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["text": textView.text ?? ""]])
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        lastFocusedInput = textView
        guard let handler = focusHandlers[ObjectIdentifier(textView)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["text": textView.text ?? ""]])
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        let id = ObjectIdentifier(textView)
        let nativeEvent: [String: Any] = ["text": textView.text ?? ""]
        if let handler = blurHandlers[id] {
            send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": nativeEvent])
        }
        if let handler = endEditingHandlers[id] {
            send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": nativeEvent])
        }
    }

    @objc private func textChanged(_ sender: UITextField) {
        lastFocusedInput = sender
        let id = ObjectIdentifier(sender)
        inputIdentities[id].map { inputDrafts[$0] = sender.text ?? "" }
        let focused = sender.isFirstResponder ? sender : firstResponder(in: rootStack)
        guard let handler = handlers[id] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["text": sender.text ?? ""]])
        restoreFocus(focused)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak focused] in
            self?.restoreFocus(focused)
        }
    }

    @objc private func switchChanged(_ sender: UISwitch) {
        guard let handler = handlers[ObjectIdentifier(sender)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["value": sender.isOn]])
    }

    @objc private func sliderChanged(_ sender: UISlider) {
        let value = snappedSliderValue(sender.value, for: sender)
        if sender.value != value { sender.value = value }
        guard let handler = handlers[ObjectIdentifier(sender)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["value": value]])
    }

    @objc private func sliderFinished(_ sender: UISlider) {
        guard let handler = sliderCompleteHandlers[ObjectIdentifier(sender)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["value": snappedSliderValue(sender.value, for: sender)]])
    }

    func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        pickerOptions[ObjectIdentifier(pickerView)]?.count ?? 0
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        guard let options = pickerOptions[ObjectIdentifier(pickerView)], options.indices.contains(row) else { return nil }
        return options[row].label
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        guard let options = pickerOptions[ObjectIdentifier(pickerView)], options.indices.contains(row),
              let handler = handlers[ObjectIdentifier(pickerView)] else { return }
        let option = options[row]
        send(type: "EVENT", payload: [
            "handlerName": handler,
            "nativeEvent": ["value": option.value, "index": row],
        ])
    }

    @objc private func textFocused(_ sender: UITextField) {
        lastFocusedInput = sender
        guard let handler = focusHandlers[ObjectIdentifier(sender)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["text": sender.text ?? ""]])
    }

    @objc private func textBlurred(_ sender: UITextField) {
        let id = ObjectIdentifier(sender)
        let nativeEvent: [String: Any] = ["text": sender.text ?? ""]
        if let handler = blurHandlers[id] {
            send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": nativeEvent])
        }
        if let handler = endEditingHandlers[id] {
            send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": nativeEvent])
        }
    }

    @objc private func textSubmitted(_ sender: UITextField) {
        guard let handler = submitHandlers[ObjectIdentifier(sender)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["text": sender.text ?? ""]])
    }

    @objc private func viewPressed(_ sender: UITapGestureRecognizer) {
        guard let view = sender.view, let handler = handlers[ObjectIdentifier(view)] else { return }
        if let pressable = view as? CraftNativeFlowView, let activeOpacity = pressable.pressActiveOpacity {
            UIView.animate(withDuration: 0.1, animations: { pressable.alpha = pressable.pressBaseOpacity * activeOpacity }) { _ in
                UIView.animate(withDuration: 0.1) { pressable.alpha = pressable.pressBaseOpacity }
            }
        }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]])
    }

    @objc private func viewLongPressed(_ sender: UILongPressGestureRecognizer) {
        guard sender.state == .began,
              let view = sender.view,
              let handler = longPressHandlers[ObjectIdentifier(view)] else { return }
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

    func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
        guard let handler = scrollMomentumBeginHandlers[ObjectIdentifier(scrollView)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": scrollEvent(scrollView)])
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard let handler = scrollMomentumEndHandlers[ObjectIdentifier(scrollView)] else { return }
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
        case "numeric", "number-pad": return .numberPad
        case "phone-pad": return .phonePad
        case "decimal-pad": return .decimalPad
        case "url": return .URL
        case "web-search": return .webSearch
        case "visible-password": return .asciiCapable
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
