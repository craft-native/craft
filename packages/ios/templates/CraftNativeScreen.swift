import Foundation
import JavaScriptCore
import OSLog
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

/// A WebView-free host for the first stx native vertical slice. The bundled
/// JavaScript sends whole, compiled view trees to UIKit and receives control
/// events and Craft API replies through JavaScriptCore.
struct CraftNativeScreen: UIViewControllerRepresentable {
    let config: CraftConfig

    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: CraftNativeScreenController(config: config))
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

/// A length as a style gives it: points, or a percentage of the parent's
/// content box. A percentage against a size that is not known yet (a column
/// whose height comes from its content) resolves to nothing, as on the web.
private enum CraftNativeLength {
    case points(CGFloat)
    case percent(CGFloat)

    init?(_ value: Any?) {
        if let number = value as? NSNumber {
            self = .points(CGFloat(truncating: number))
            return
        }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasSuffix("%"), let fraction = Double(text.dropLast()) {
            self = .percent(CGFloat(fraction) / 100)
        } else if text.hasSuffix("px"), let points = Double(text.dropLast(2)) {
            self = .points(CGFloat(points))
        } else if let points = Double(text) {
            self = .points(CGFloat(points))
        } else {
            return nil
        }
    }

    func resolve(_ base: CGFloat?) -> CGFloat? {
        switch self {
        case .points(let value): return value
        case .percent(let fraction): return base.map { max(0, $0 * fraction) }
        }
    }
}

/// How a parent lays a child out, read once from the child's style.
private struct CraftNativeLayoutStyle {
    let width: CraftNativeLength?
    let height: CraftNativeLength?
    let minWidth: CraftNativeLength?
    let maxWidth: CraftNativeLength?
    let minHeight: CraftNativeLength?
    let maxHeight: CraftNativeLength?
    let position: String
    let top: CGFloat?
    let right: CGFloat?
    let bottom: CGFloat?
    let left: CGFloat?
    let alignSelf: String?
    let flexGrow: CGFloat
    /// Nil when the style does not say: the parent picks the default for the
    /// kind of view (text shrinks along a row, a box does not).
    let flexShrink: CGFloat?
    let flexBasis: CraftNativeLength?
    let marginTop: CGFloat
    let marginRight: CGFloat
    let marginBottom: CGFloat
    let marginLeft: CGFloat
    let display: String
    let gridColumns: Int
    let gridAutoRows: CGFloat?

    static let empty = CraftNativeLayoutStyle([:])

    init(_ raw: [String: Any]) {
        func number(_ value: Any?) -> CGFloat? { (value as? NSNumber).map { CGFloat(truncating: $0) } }
        width = CraftNativeLength(raw["width"])
        height = CraftNativeLength(raw["height"])
        minWidth = CraftNativeLength(raw["minWidth"])
        maxWidth = CraftNativeLength(raw["maxWidth"])
        minHeight = CraftNativeLength(raw["minHeight"])
        maxHeight = CraftNativeLength(raw["maxHeight"])
        position = raw["position"] as? String ?? "relative"
        top = number(raw["top"])
        right = number(raw["right"])
        bottom = number(raw["bottom"])
        left = number(raw["left"])
        let align = raw["alignSelf"] as? String
        alignSelf = align == "auto" ? nil : align
        // `flex: n` is the web's and React Native's shorthand: a positive
        // number grows by n, shrinks, and starts from nothing, so `flex-1`
        // siblings share a row equally whatever their content.
        let flex = number(raw["flex"])
        flexGrow = number(raw["flexGrow"]) ?? flex.map { max(0, $0) } ?? 0
        flexShrink = number(raw["flexShrink"]) ?? flex.map { $0 != 0 ? 1 : 0 }
        flexBasis = CraftNativeLength(raw["flexBasis"]) ?? flex.flatMap { $0 > 0 ? .points(0) : nil }
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

private final class CraftNativeLayoutStyleBox {
    let style: CraftNativeLayoutStyle
    init(_ style: CraftNativeLayoutStyle) { self.style = style }
}

private var craftNativeLayoutStyleKey: UInt8 = 0
private var craftNativeCornerRadiusKey: UInt8 = 0

extension UIView {
    /// The layout style this view's parent reads. It lives on the view, so an
    /// in-place style update reaches the parent's next layout pass without the
    /// parent being reconciled too.
    fileprivate var craftLayoutStyle: CraftNativeLayoutStyle {
        get { (objc_getAssociatedObject(self, &craftNativeLayoutStyleKey) as? CraftNativeLayoutStyleBox)?.style ?? .empty }
        set { objc_setAssociatedObject(self, &craftNativeLayoutStyleKey, CraftNativeLayoutStyleBox(newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// The corner radius the style asked for. The layer gets at most half the
    /// shortest side: Core Animation draws nothing at all for a radius larger
    /// than the view (`rounded-full` is 9999).
    var craftRequestedCornerRadius: CGFloat? {
        get { (objc_getAssociatedObject(self, &craftNativeCornerRadiusKey) as? NSNumber).map { CGFloat(truncating: $0) } }
        set {
            objc_setAssociatedObject(self, &craftNativeCornerRadiusKey, newValue.map { NSNumber(value: Double($0)) }, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            craftApplyCornerRadius()
        }
    }

    func craftApplyCornerRadius() {
        let requested = craftRequestedCornerRadius ?? 0
        let limit = min(bounds.width, bounds.height) / 2
        let radius = limit > 0 ? min(requested, limit) : min(requested, 9_998)
        if layer.cornerRadius != radius { layer.cornerRadius = radius }
    }
}

/// Measures any native-screen view the way its parent's flex layout needs:
/// at a width (or height) the parent fixes, or at its natural size within the
/// room there is. Shared by the flow views, the scroll view and FlatList rows.
enum CraftNativeFlexLayout {
    static let unbounded: CGFloat = 1_000_000

    static func measure(_ view: UIView, width: CGFloat?, height: CGFloat?, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        let maxWidth = max(0, maxWidth)
        let maxHeight = max(0, maxHeight)
        switch view {
        case let flow as CraftNativeFlowView:
            return flow.measure(width: width, height: height, maxWidth: maxWidth, maxHeight: maxHeight)
        case let scroll as CraftNativeScrollView:
            return scroll.measure(width: width, height: height, maxWidth: maxWidth, maxHeight: maxHeight)
        case let list as CraftNativeFlatList:
            let listWidth = width ?? maxWidth
            return CGSize(width: listWidth, height: height ?? list.fittingHeight(width: listWidth))
        case let label as UILabel:
            // Text takes the width it needs up to the room there is, and
            // wraps or truncates inside it rather than widening its parent.
            let limit = width ?? maxWidth
            let natural = label.sizeThatFits(CGSize(width: limit, height: unbounded))
            let resolvedWidth = width ?? min(ceil(natural.width), limit)
            let resolvedHeight = height ?? ceil(resolvedWidth < limit
                ? label.sizeThatFits(CGSize(width: resolvedWidth, height: unbounded)).height
                : natural.height)
            return CGSize(width: resolvedWidth, height: resolvedHeight)
        case let image as UIImageView where image.image == nil:
            return CGSize(width: width ?? 0, height: height ?? 0)
        default:
            let intrinsic = view.intrinsicContentSize
            let fitted = view.sizeThatFits(CGSize(width: width ?? maxWidth, height: height ?? maxHeight))
            let naturalWidth = intrinsic.width > 0 && intrinsic.width != UIView.noIntrinsicMetric ? intrinsic.width : fitted.width
            let naturalHeight = intrinsic.height > 0 && intrinsic.height != UIView.noIntrinsicMetric ? intrinsic.height : fitted.height
            return CGSize(width: width ?? min(max(0, naturalWidth), maxWidth), height: height ?? max(0, naturalHeight))
        }
    }

    /// Marks every flex container above `view` for measuring again, after a
    /// change inside it that may change its size. A FlatList row stops the
    /// walk: the list measures its rows itself.
    static func invalidateAncestors(of view: UIView) {
        var current = view.superview
        while let ancestor = current, !(ancestor is UICollectionViewCell) {
            if let flow = ancestor as? CraftNativeFlowView { flow.invalidateMeasurements() }
            if let scroll = ancestor as? CraftNativeScrollView { scroll.setContentNeedsLayout() }
            current = ancestor.superview
        }
    }

    /// A size rounded up to whole pixels, never below `atLeast`.
    static func ceiled(_ size: CGSize, scale: CGFloat, atLeast floor: CGSize) -> CGSize {
        let scale = max(1, scale)
        // Less a hair, so a size already on the pixel grid stays put.
        func up(_ value: CGFloat) -> CGFloat { (value * scale - 0.001).rounded(.up) / scale }
        return CGSize(width: max(floor.width, up(size.width)), height: max(floor.height, up(size.height)))
    }

    /// A frame snapped to the screen's pixels edge by edge, so neighbours
    /// neither overlap nor leave a hairline between them.
    static func snapped(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let scale = max(1, scale)
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minX = snap(rect.minX), minY = snap(rect.minY)
        return CGRect(x: minX, y: minY, width: max(0, snap(rect.maxX) - minX), height: max(0, snap(rect.maxY) - minY))
    }
}

/// A flexbox container: rows and columns with grow, shrink and basis, wrap,
/// gaps, alignment, margins, percentages, absolute children and a simple
/// grid. It is a UIStackView in name only, so existing callers and tests keep
/// `axis`, `alignment` and `arrangedSubviews`; the stack view's own
/// constraints are never created, and every frame comes from `layout`.
private final class CraftNativeFlowView: UIStackView {
    var pressActiveOpacity: CGFloat?
    var pressBaseOpacity: CGFloat = 1
    var wrap = false { didSet { if wrap != oldValue { invalidateMeasurements() } } }
    var alignItems = "stretch" { didSet { alignment = alignmentValue; if alignItems != oldValue { invalidateMeasurements() } } }
    var justifyContent = "flex-start" { didSet { distribution = distributionValue; if justifyContent != oldValue { invalidateMeasurements() } } }
    var gap: CGFloat = 0 { didSet { spacing = gap; if gap != oldValue { invalidateMeasurements() } } }
    var rowGap: CGFloat? { didSet { if rowGap != oldValue { invalidateMeasurements() } } }
    var columnGap: CGFloat? { didSet { if columnGap != oldValue { invalidateMeasurements() } } }
    var grid = false { didSet { if grid != oldValue { invalidateMeasurements() } } }
    var gridColumns = 1 { didSet { if gridColumns != oldValue { invalidateMeasurements() } } }
    var gridAutoRows: CGFloat? { didSet { if gridAutoRows != oldValue { invalidateMeasurements() } } }
    var padding = UIEdgeInsets.zero {
        didSet {
            layoutMargins = padding
            isLayoutMarginsRelativeArrangement = true
            if padding != oldValue { invalidateMeasurements() }
        }
    }
    override var axis: NSLayoutConstraint.Axis {
        didSet { if axis != oldValue { invalidateMeasurements() } }
    }

    private var flowChildren: [UIView] = []
    private var measurements: [MeasureKey: CGSize] = [:]

    private struct MeasureKey: Hashable {
        let width: CGFloat?
        let height: CGFloat?
        let maxWidth: CGFloat
        let maxHeight: CGFloat
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        alignment = .fill
        distribution = .fill
        isLayoutMarginsRelativeArrangement = true
        insetsLayoutMarginsFromSafeArea = false
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

    // MARK: Children

    override var arrangedSubviews: [UIView] { flowChildren }

    override func addArrangedSubview(_ view: UIView) {
        insertArrangedSubview(view, at: flowChildren.count)
    }

    override func insertArrangedSubview(_ view: UIView, at stackIndex: Int) {
        flowChildren.removeAll { $0 === view }
        flowChildren.insert(view, at: min(max(0, stackIndex), flowChildren.count))
        if view.superview !== self {
            view.removeFromSuperview()
            addSubview(view)
        }
        view.translatesAutoresizingMaskIntoConstraints = true
        invalidateMeasurements()
    }

    override func removeArrangedSubview(_ view: UIView) {
        flowChildren.removeAll { $0 === view }
        invalidateMeasurements()
    }

    override func willRemoveSubview(_ subview: UIView) {
        flowChildren.removeAll { $0 === subview }
        super.willRemoveSubview(subview)
        invalidateMeasurements()
    }

    func setLayoutStyle(_ raw: [String: Any], for view: UIView) {
        view.craftLayoutStyle = CraftNativeLayoutStyle(raw)
        invalidateMeasurements()
    }

    func removeLayoutStyle(for view: UIView) {
        view.craftLayoutStyle = .empty
    }

    /// Forgets measured sizes and lays out again on the next pass.
    func invalidateMeasurements() {
        measurements.removeAll(keepingCapacity: true)
        setNeedsLayout()
    }

    // MARK: Measuring and layout

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        measure(width: nil, height: nil, maxWidth: size.width, maxHeight: size.height)
    }

    func measure(width: CGFloat?, height: CGFloat?, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        let key = MeasureKey(width: width, height: height, maxWidth: maxWidth, maxHeight: maxHeight)
        if let cached = measurements[key] { return cached }
        let size = layout(width: width, height: height, maxWidth: maxWidth, maxHeight: maxHeight, place: false).size
        measurements[key] = size
        return size
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        craftApplyCornerRadius()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let result = layout(width: bounds.width, height: bounds.height, maxWidth: bounds.width, maxHeight: bounds.height, place: true)
        for (child, frame) in result.frames {
            var snapped = CraftNativeFlexLayout.snapped(frame, scale: scale)
            // Snapping each edge can take a pixel off a label (15.83…33.83
            // becomes 16…33.67), and a label a pixel narrower than its text
            // truncates it ("13" drew as "…"). Text keeps its whole size.
            if child is UILabel {
                snapped.size = CraftNativeFlexLayout.ceiled(frame.size, scale: scale, atLeast: snapped.size)
            }
            if child.transform.isIdentity {
                if child.frame != snapped { child.frame = snapped }
            } else {
                // A transformed child (a sticky header, a scaled spinner) is
                // placed by bounds and center: its frame is undefined then.
                let size = CGRect(origin: child.bounds.origin, size: snapped.size)
                let center = CGPoint(x: snapped.midX, y: snapped.midY)
                if child.bounds != size { child.bounds = size }
                if child.center != center { child.center = center }
            }
            child.craftApplyCornerRadius()
        }
    }

    private struct Item {
        let view: UIView
        let style: CraftNativeLayoutStyle
        let align: String
        let mainLeading: CGFloat
        let mainTrailing: CGFloat
        let crossLeading: CGFloat
        let crossTrailing: CGFloat
        let minMain: CGFloat?
        let maxMain: CGFloat?
        let minCross: CGFloat?
        let maxCross: CGFloat?
        let fixedCross: CGFloat?
        let grow: CGFloat
        let shrink: CGFloat
        var basis: CGFloat
        var main: CGFloat = 0
        var cross: CGFloat = 0

        var mainMargins: CGFloat { mainLeading + mainTrailing }
        var crossMargins: CGFloat { crossLeading + crossTrailing }
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat?, _ upper: CGFloat?) -> CGFloat {
        var result = value
        if let upper { result = min(result, upper) }
        if let lower { result = max(result, lower) }
        return max(0, result)
    }

    /// Children that take part in the flow: shown, not a modal overlay.
    private var visibleChildren: [UIView] {
        flowChildren.filter { $0.superview === self && !$0.isHidden && !($0 is CraftNativeModalView) }
    }

    /// The flexbox algorithm, single pass. `width`/`height` are this view's
    /// outer size when its parent fixes it, nil when it sizes to its content
    /// within `maxWidth`/`maxHeight`. Returns its outer size and, when
    /// placing, every child's frame in its own coordinates.
    private func layout(
        width: CGFloat?,
        height: CGFloat?,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        place: Bool
    ) -> (size: CGSize, frames: [(UIView, CGRect)]) {
        let children = visibleChildren
        let flow = children.filter { $0.craftLayoutStyle.position != "absolute" }
        let horizontal = axis == .horizontal
        let paddingWidth = padding.left + padding.right
        let paddingHeight = padding.top + padding.bottom
        let innerWidth = width.map { max(0, $0 - paddingWidth) }
        let innerHeight = height.map { max(0, $0 - paddingHeight) }
        let roomWidth = max(0, (width ?? maxWidth) - paddingWidth)
        let roomHeight = max(0, (height ?? maxHeight) - paddingHeight)

        var frames: [(UIView, CGRect)] = []
        var contentSize: CGSize
        if grid {
            contentSize = layoutGrid(flow, innerWidth: innerWidth, roomWidth: roomWidth, innerHeight: innerHeight, place: place, frames: &frames)
        } else {
            contentSize = layoutFlex(
                flow,
                horizontal: horizontal,
                innerWidth: innerWidth,
                innerHeight: innerHeight,
                roomWidth: roomWidth,
                roomHeight: roomHeight,
                place: place,
                frames: &frames
            )
        }
        let size = CGSize(width: width ?? contentSize.width + paddingWidth, height: height ?? contentSize.height + paddingHeight)

        if place {
            let content = CGRect(x: padding.left, y: padding.top, width: max(0, size.width - paddingWidth), height: max(0, size.height - paddingHeight))
            for child in children where child.craftLayoutStyle.position == "absolute" {
                let style = child.craftLayoutStyle
                let fixedWidth = style.left != nil && style.right != nil
                    ? max(0, content.width - (style.left ?? 0) - (style.right ?? 0))
                    : style.width?.resolve(content.width)
                let fixedHeight = style.top != nil && style.bottom != nil
                    ? max(0, content.height - (style.top ?? 0) - (style.bottom ?? 0))
                    : style.height?.resolve(content.height)
                let measured = CraftNativeFlexLayout.measure(child, width: fixedWidth, height: fixedHeight, maxWidth: content.width, maxHeight: content.height)
                let x = style.left ?? (style.right.map { content.width - $0 - measured.width } ?? 0)
                let y = style.top ?? (style.bottom.map { content.height - $0 - measured.height } ?? 0)
                frames.append((child, CGRect(x: content.minX + x, y: content.minY + y, width: measured.width, height: measured.height)))
            }
        }
        return (size, frames)
    }

    private func layoutFlex(
        _ children: [UIView],
        horizontal: Bool,
        innerWidth: CGFloat?,
        innerHeight: CGFloat?,
        roomWidth: CGFloat,
        roomHeight: CGFloat,
        place: Bool,
        frames: inout [(UIView, CGRect)]
    ) -> CGSize {
        let definiteMain = horizontal ? innerWidth : innerHeight
        let definiteCross = horizontal ? innerHeight : innerWidth
        let roomMain = horizontal ? roomWidth : roomHeight
        let roomCross = horizontal ? roomHeight : roomWidth
        let mainGap = horizontal ? (columnGap ?? gap) : (rowGap ?? gap)
        let crossGap = horizontal ? (rowGap ?? 0) : (columnGap ?? 0)

        func measure(_ view: UIView, main: CGFloat?, cross: CGFloat?, mainLimit: CGFloat, crossLimit: CGFloat) -> (main: CGFloat, cross: CGFloat) {
            let size = horizontal
                ? CraftNativeFlexLayout.measure(view, width: main, height: cross, maxWidth: mainLimit, maxHeight: crossLimit)
                : CraftNativeFlexLayout.measure(view, width: cross, height: main, maxWidth: crossLimit, maxHeight: mainLimit)
            return horizontal ? (size.width, size.height) : (size.height, size.width)
        }

        var items: [Item] = children.map { view in
            let style = view.craftLayoutStyle
            let mainLeading = horizontal ? style.marginLeft : style.marginTop
            let mainTrailing = horizontal ? style.marginRight : style.marginBottom
            let crossLeading = horizontal ? style.marginTop : style.marginLeft
            let crossTrailing = horizontal ? style.marginBottom : style.marginRight
            let align = style.alignSelf ?? alignItems
            let explicitMain = (horizontal ? style.width : style.height)?.resolve(definiteMain)
            let explicitCross = (horizontal ? style.height : style.width)?.resolve(definiteCross)
            let minMain = (horizontal ? style.minWidth : style.minHeight)?.resolve(definiteMain)
            let maxMain = (horizontal ? style.maxWidth : style.maxHeight)?.resolve(definiteMain)
            let minCross = (horizontal ? style.minHeight : style.minWidth)?.resolve(definiteCross)
            let maxCross = (horizontal ? style.maxHeight : style.maxWidth)?.resolve(definiteCross)
            var fixedCross = explicitCross
            if fixedCross == nil, align == "stretch", !wrap, let definiteCross {
                fixedCross = definiteCross - crossLeading - crossTrailing
            }
            fixedCross = fixedCross.map { clamp($0, minCross, maxCross) }
            let defaultShrink: CGFloat
            if view is UIScrollView {
                defaultShrink = 1
            } else if view is UILabel {
                defaultShrink = horizontal ? 1 : 0
            } else {
                defaultShrink = 0
            }

            // The basis: a flex-basis, else the explicit size, else the
            // content's size. A zero basis (`flex-1`) means "share the free
            // space" only when there is a free space to share; in a container
            // sized by its content, the content is the basis, as on the web.
            let basis: CGFloat
            if let flexBasis = style.flexBasis?.resolve(definiteMain), definiteMain != nil || flexBasis > 0 {
                basis = flexBasis
            } else if let explicitMain {
                basis = explicitMain
            } else {
                basis = measure(
                    view,
                    main: nil,
                    cross: fixedCross,
                    mainLimit: max(0, (maxMain ?? roomMain) - mainLeading - mainTrailing),
                    crossLimit: max(0, (fixedCross ?? (maxCross ?? roomCross - crossLeading - crossTrailing)))
                ).main
            }
            return Item(
                view: view,
                style: style,
                align: align,
                mainLeading: mainLeading,
                mainTrailing: mainTrailing,
                crossLeading: crossLeading,
                crossTrailing: crossTrailing,
                minMain: minMain,
                maxMain: maxMain,
                minCross: minCross,
                maxCross: maxCross,
                fixedCross: fixedCross,
                grow: style.flexGrow,
                shrink: style.flexShrink ?? defaultShrink,
                basis: clamp(basis, minMain, maxMain)
            )
        }

        // Lines: one, or as many as wrapping needs.
        var lines: [Range<Int>] = []
        let lineLimit = definiteMain ?? roomMain
        var start = 0
        var used: CGFloat = 0
        for index in items.indices {
            let size = items[index].basis + items[index].mainMargins
            let next = index == start ? size : used + mainGap + size
            if wrap, index > start, next > lineLimit {
                lines.append(start..<index)
                start = index
                used = size
            } else {
                used = next
            }
        }
        if start < items.count { lines.append(start..<items.count) }

        var lineMains: [CGFloat] = []
        var lineCrosses: [CGFloat] = []
        for line in lines {
            let gaps = CGFloat(max(0, line.count - 1)) * mainGap
            let hypothetical = line.reduce(0) { $0 + items[$1].basis + items[$1].mainMargins } + gaps
            // A row sized by its content is as wide as that content, up to the
            // room it has; a column sized by its content is as tall as it is.
            let lineMain = definiteMain ?? (horizontal ? min(hypothetical, roomMain) : hypothetical)
            let free = lineMain - hypothetical
            if free > 0 {
                let total = line.reduce(0) { $0 + items[$1].grow }
                for index in line {
                    let share = total > 0 ? free * items[index].grow / total : 0
                    items[index].main = clamp(items[index].basis + share, items[index].minMain, items[index].maxMain)
                }
            } else if free < 0 {
                let total = line.reduce(0) { $0 + items[$1].shrink * items[$1].basis }
                for index in line {
                    let share = total > 0 ? -free * items[index].shrink * items[index].basis / total : 0
                    items[index].main = clamp(items[index].basis - share, items[index].minMain, items[index].maxMain)
                }
            } else {
                for index in line { items[index].main = items[index].basis }
            }

            var lineCross: CGFloat = 0
            for index in line {
                let item = items[index]
                if let fixedCross = item.fixedCross {
                    items[index].cross = fixedCross
                } else {
                    let measured = measure(
                        item.view,
                        main: item.main,
                        cross: nil,
                        mainLimit: item.main,
                        crossLimit: max(0, (item.maxCross ?? roomCross) - item.crossMargins)
                    )
                    items[index].cross = clamp(measured.cross, item.minCross, item.maxCross)
                }
                lineCross = max(lineCross, items[index].cross + item.crossMargins)
            }
            // A single line is as thick as the container when the container's
            // size is known: stretched children fill it, others align in it.
            if !wrap, let definiteCross { lineCross = definiteCross }
            for index in line where items[index].fixedCross == nil && items[index].align == "stretch" {
                let item = items[index]
                if case .some = (horizontal ? item.style.height : item.style.width) { continue }
                items[index].cross = clamp(lineCross - item.crossMargins, item.minCross, item.maxCross)
            }
            lineMains.append(line.reduce(0) { $0 + items[$1].main + items[$1].mainMargins } + gaps)
            lineCrosses.append(lineCross)
        }

        let contentMain = definiteMain ?? (lineMains.max() ?? 0)
        let contentCross = definiteCross
            ?? (lineCrosses.reduce(0, +) + CGFloat(max(0, lineCrosses.count - 1)) * crossGap)

        if place {
            var crossOffset: CGFloat = 0
            for (lineIndex, line) in lines.enumerated() {
                let free = max(0, contentMain - lineMains[lineIndex])
                let count = line.count
                let leading: CGFloat
                let between: CGFloat
                switch justifyContent {
                case "center": leading = free / 2; between = 0
                case "flex-end": leading = free; between = 0
                case "space-between": leading = 0; between = count > 1 ? free / CGFloat(count - 1) : 0
                case "space-around": leading = free / CGFloat(count * 2); between = free / CGFloat(count)
                case "space-evenly": leading = free / CGFloat(count + 1); between = free / CGFloat(count + 1)
                default: leading = 0; between = 0
                }
                let lineCross = lineCrosses[lineIndex]
                var mainOffset = leading
                for index in line {
                    let item = items[index]
                    let crossPosition: CGFloat
                    switch item.align {
                    case "center": crossPosition = item.crossLeading + (lineCross - item.crossMargins - item.cross) / 2
                    case "flex-end": crossPosition = lineCross - item.crossTrailing - item.cross
                    default: crossPosition = item.crossLeading
                    }
                    let mainPosition = mainOffset + item.mainLeading
                    let frame = horizontal
                        ? CGRect(x: padding.left + mainPosition, y: padding.top + crossOffset + crossPosition, width: item.main, height: item.cross)
                        : CGRect(x: padding.left + crossOffset + crossPosition, y: padding.top + mainPosition, width: item.cross, height: item.main)
                    frames.append((item.view, frame))
                    mainOffset += item.mainMargins + item.main + mainGap + between
                }
                crossOffset += lineCross + crossGap
            }
        }
        return horizontal ? CGSize(width: contentMain, height: contentCross) : CGSize(width: contentCross, height: contentMain)
    }

    private func layoutGrid(
        _ children: [UIView],
        innerWidth: CGFloat?,
        roomWidth: CGFloat,
        innerHeight: CGFloat?,
        place: Bool,
        frames: inout [(UIView, CGRect)]
    ) -> CGSize {
        let columns = max(1, gridColumns)
        let horizontalGap = columnGap ?? gap
        let verticalGap = rowGap ?? gap
        let gaps = CGFloat(columns - 1) * horizontalGap
        var cellWidth: CGFloat
        if let innerWidth {
            cellWidth = max(0, (innerWidth - gaps) / CGFloat(columns))
        } else {
            // Sized by content: the widest cell, as long as the row fits.
            let widest = children.map { child -> CGFloat in
                let style = child.craftLayoutStyle
                return CraftNativeFlexLayout.measure(child, width: style.width?.resolve(nil), height: nil, maxWidth: roomWidth, maxHeight: CraftNativeFlexLayout.unbounded).width
                    + style.marginLeft + style.marginRight
            }.max() ?? 0
            cellWidth = min(widest, max(0, (roomWidth - gaps) / CGFloat(columns)))
        }
        var rowHeights: [CGFloat] = []
        var sizes: [CGSize] = []
        for (index, child) in children.enumerated() {
            let style = child.craftLayoutStyle
            let available = max(0, cellWidth - style.marginLeft - style.marginRight)
            let align = style.alignSelf ?? alignItems
            let fixedWidth = style.width?.resolve(cellWidth) ?? (align == "stretch" ? available : nil)
            let size = CraftNativeFlexLayout.measure(
                child,
                width: fixedWidth.map { min($0, available) },
                height: style.height?.resolve(nil),
                maxWidth: available,
                maxHeight: CraftNativeFlexLayout.unbounded
            )
            sizes.append(size)
            let row = index / columns
            while rowHeights.count <= row { rowHeights.append(gridAutoRows ?? 0) }
            rowHeights[row] = max(rowHeights[row], size.height + style.marginTop + style.marginBottom)
        }
        let width = innerWidth ?? (CGFloat(columns) * cellWidth + gaps)
        let height = rowHeights.reduce(0, +) + CGFloat(max(0, rowHeights.count - 1)) * verticalGap
        if place {
            var rowTop = padding.top
            for (index, child) in children.enumerated() {
                let style = child.craftLayoutStyle
                let row = index / columns
                let column = index % columns
                let rowHeight = rowHeights[row]
                let size = sizes[index]
                let align = style.alignSelf ?? alignItems
                let availableWidth = max(0, cellWidth - style.marginLeft - style.marginRight)
                let availableHeight = max(0, rowHeight - style.marginTop - style.marginBottom)
                let childWidth = min(availableWidth, size.width)
                let childHeight = align == "stretch" && style.height == nil ? availableHeight : min(availableHeight, size.height)
                let x = padding.left + CGFloat(column) * (cellWidth + horizontalGap) + style.marginLeft
                    + (align == "center" ? (availableWidth - childWidth) / 2 : align == "flex-end" ? availableWidth - childWidth : 0)
                let y = rowTop + style.marginTop
                    + (align == "center" ? (availableHeight - childHeight) / 2 : align == "flex-end" ? availableHeight - childHeight : 0)
                frames.append((child, CGRect(x: x, y: y, width: childWidth, height: childHeight)))
                if column == columns - 1 || index == children.count - 1 { rowTop += rowHeight + verticalGap }
            }
        }
        return CGSize(width: width, height: innerHeight ?? height)
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

    required init?(coder: NSCoder) { nil }

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

private final class CraftNativeScrollView: UIScrollView, UIGestureRecognizerDelegate {
    let contentStack = CraftNativeFlowView()
    private let keyboardTapGesture = UITapGestureRecognizer()
    private var keyboardShouldPersistTaps = "never"
    private var contentNeedsLayout = true
    private var laidOutSize: CGSize = .zero
    private let pullToRefresh = UIRefreshControl()
    private var refreshHandler: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        keyboardTapGesture.cancelsTouchesInView = false
        keyboardTapGesture.delegate = self
        keyboardTapGesture.addTarget(self, action: #selector(keyboardTap))
        addGestureRecognizer(keyboardTapGesture)
        pullToRefresh.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        addSubview(contentStack)
        setAxis(.vertical)
    }

    required init?(coder: NSCoder) { nil }

    var isVertical: Bool { contentStack.axis == .vertical }

    /// Lays the content out again on the next pass. Scrolling alone does not:
    /// a scroll view lays out on every frame of a scroll.
    func setContentNeedsLayout() {
        contentNeedsLayout = true
        setNeedsLayout()
    }

    /// The size of the content laid out across the visible width (or, sideways,
    /// height), which is also the scroll view's own size when nothing fixes it.
    func contentFitting(width: CGFloat?, height: CGFloat?) -> CGSize {
        if isVertical {
            let contentWidth = max(0, (width ?? bounds.width) - adjustedContentInset.left - adjustedContentInset.right)
            return contentStack.measure(width: contentWidth, height: nil, maxWidth: contentWidth, maxHeight: CraftNativeFlexLayout.unbounded)
        }
        let contentHeight = height.map { max(0, $0 - adjustedContentInset.top - adjustedContentInset.bottom) }
        return contentStack.measure(width: nil, height: contentHeight, maxWidth: CraftNativeFlexLayout.unbounded, maxHeight: contentHeight ?? CraftNativeFlexLayout.unbounded)
    }

    func measure(width: CGFloat?, height: CGFloat?, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        if isVertical {
            let resolvedWidth = width ?? maxWidth
            return CGSize(width: resolvedWidth, height: height ?? contentFitting(width: resolvedWidth, height: nil).height)
        }
        let content = contentFitting(width: nil, height: height)
        return CGSize(width: width ?? min(content.width, maxWidth), height: height ?? content.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        craftApplyCornerRadius()
        if contentNeedsLayout || laidOutSize != bounds.size {
            contentNeedsLayout = false
            laidOutSize = bounds.size
            var size = contentFitting(width: bounds.width, height: bounds.height)
            if isVertical {
                size.width = max(0, bounds.width - adjustedContentInset.left - adjustedContentInset.right)
            } else {
                size.height = max(0, bounds.height - adjustedContentInset.top - adjustedContentInset.bottom)
            }
            let frame = CGRect(origin: .zero, size: size)
            if contentStack.frame != frame { contentStack.frame = frame }
            if contentSize != size { contentSize = size }
        }
        // A scroll view lays out on every frame of a scroll: the sticky
        // headers follow it here, over content placed by this same pass.
        if !stickyIndices.isEmpty || pendingScrollTarget != nil { contentStack.layoutIfNeeded() }
        updateStickyHeaders()
        scrollToPendingTarget()
    }

    // MARK: Sticky headers

    private var stickyIndices: [Int] = []
    private var stickyViews: [UIView] = []

    /// `stickyHeaderIndices`, as in React Native: the content's children at
    /// these indices stay at the top of the visible area once scrolled to,
    /// each pushed up by the next. Vertical scroll views only.
    func setStickyHeaderIndices(_ value: Any?) {
        let next = Array(Set(((value as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }.filter { $0 >= 0 })).sorted()
        guard next != stickyIndices else { return }
        stickyIndices = next
        setNeedsLayout()
    }

    /// Where a header sits in the content when it is not stuck.
    private func naturalTop(_ view: UIView) -> CGFloat {
        view.center.y - view.bounds.height / 2
    }

    private func updateStickyHeaders() {
        let children = contentStack.arrangedSubviews
        let headers = isVertical ? stickyIndices.compactMap { $0 < children.count ? children[$0] : nil }.filter { !$0.isHidden } : []
        for view in stickyViews where !headers.contains(where: { $0 === view }) {
            view.transform = .identity
            view.layer.zPosition = 0
        }
        stickyViews = headers
        guard !headers.isEmpty else { return }
        let visibleTop = contentOffset.y + adjustedContentInset.top
        for (index, header) in headers.enumerated() {
            let natural = naturalTop(header)
            var top = max(natural, visibleTop)
            if index + 1 < headers.count {
                top = max(natural, min(top, naturalTop(headers[index + 1]) - header.bounds.height))
            }
            let shift = CGAffineTransform(translationX: 0, y: top - natural)
            if header.transform != shift { header.transform = shift }
            // Above the content it covers, for drawing and for touches.
            header.layer.zPosition = 1
            if contentStack.subviews.last !== header { contentStack.bringSubviewToFront(header) }
        }
    }

    /// The height a stuck header covers above a point of the content.
    private func stickyHeight(above y: CGFloat) -> CGFloat {
        stickyViews.last(where: { naturalTop($0) <= y })?.bounds.height ?? 0
    }

    // MARK: Scroll targets

    private var scrollTargetKey: String?
    private var pendingScrollTarget: (id: String, animated: Bool, attempts: Int)?

    /// `scrollTarget`: `"<testID>"` or `{ id, animated?, key? }`. When it
    /// changes, the content scrolls so the view with that `testID` sits at
    /// the top of the visible area, below any sticky header. A new `key`
    /// scrolls to the same view again; `null` forgets the last target.
    func setScrollTarget(_ value: Any?) {
        var id: String?
        var animated = true
        if let text = value as? String {
            id = text
        } else if let target = value as? [String: Any] {
            id = target["id"] as? String
            animated = target["animated"] as? Bool ?? true
        }
        guard let id, !id.isEmpty else {
            scrollTargetKey = nil
            pendingScrollTarget = nil
            return
        }
        let key: String
        if let object = value as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            key = String(decoding: data, as: UTF8.self)
        } else {
            key = id
        }
        guard key != scrollTargetKey else { return }
        scrollTargetKey = key
        pendingScrollTarget = (id, animated, 0)
        setNeedsLayout()
    }

    private func descendant(withIdentifier id: String, in view: UIView) -> UIView? {
        for child in view.subviews {
            if child.accessibilityIdentifier == id { return child }
            if let match = descendant(withIdentifier: id, in: child) { return match }
        }
        return nil
    }

    private func scrollToPendingTarget() {
        guard let target = pendingScrollTarget, bounds.height > 0 else { return }
        pendingScrollTarget = nil
        let view = descendant(withIdentifier: target.id, in: contentStack)
        // A target the same render created may not be in place yet (this pass
        // can run while the render is applied): try again on the next passes.
        guard let view, view.bounds.size != .zero else {
            if target.attempts < 3 {
                pendingScrollTarget = (target.id, target.animated, target.attempts + 1)
                DispatchQueue.main.async { [weak self] in self?.setNeedsLayout() }
            }
            return
        }
        let rect = view.convert(view.bounds, to: contentStack)
        if isVertical {
            let lowest = -adjustedContentInset.top
            let highest = max(lowest, contentSize.height + adjustedContentInset.bottom - bounds.height)
            let y = min(highest, max(lowest, rect.minY - adjustedContentInset.top - stickyHeight(above: rect.minY)))
            setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: target.animated)
        } else {
            let lowest = -adjustedContentInset.left
            let highest = max(lowest, contentSize.width + adjustedContentInset.right - bounds.width)
            let x = min(highest, max(lowest, rect.minX - adjustedContentInset.left))
            setContentOffset(CGPoint(x: x, y: contentOffset.y), animated: target.animated)
        }
    }

    override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        setContentNeedsLayout()
    }

    private var refreshingProp = false

    /// `onRefresh` and `refreshing`: the system's pull to refresh, controlled
    /// as in React Native. The spinner shows while `refreshing` is true; a
    /// pull that the screen does not answer with `refreshing` true ends at
    /// once instead of spinning forever.
    func setRefreshHandler(_ handler: (() -> Void)?, refreshing: Bool) {
        refreshHandler = handler
        refreshingProp = refreshing
        if handler == nil {
            if pullToRefresh.isRefreshing { pullToRefresh.endRefreshing() }
            if refreshControl === pullToRefresh { refreshControl = nil }
            return
        }
        if refreshControl !== pullToRefresh { refreshControl = pullToRefresh }
        if refreshing, !pullToRefresh.isRefreshing {
            pullToRefresh.beginRefreshing()
        } else if !refreshing, pullToRefresh.isRefreshing {
            pullToRefresh.endRefreshing()
        }
    }

    var isRefreshingNow: Bool { pullToRefresh.isRefreshing }

    @objc private func refreshPulled() {
        refreshHandler?()
        // The handler's synchronous render has landed by now.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.refreshingProp, self.pullToRefresh.isRefreshing else { return }
            self.pullToRefresh.endRefreshing()
        }
    }

    func setKeyboardShouldPersistTaps(_ value: Any?) {
        let requested = value as? String
        keyboardShouldPersistTaps = ["always", "handled", "never"].contains(requested) ? requested! : "never"
        keyboardTapGesture.isEnabled = keyboardShouldPersistTaps != "always"
    }

    @objc private func keyboardTap() {
        guard keyboardShouldPersistTaps != "always" else { return }
        if keyboardShouldPersistTaps == "handled" {
            let point = keyboardTapGesture.location(in: self)
            var hit = hitTest(point, with: nil)
            while let view = hit, view !== self {
                if view is UIControl || !(view.gestureRecognizers ?? []).isEmpty { return }
                hit = view.superview
            }
        }
        window?.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    func setAxis(_ axis: NSLayoutConstraint.Axis) {
        if contentStack.axis != axis { setContentNeedsLayout() }
        contentStack.axis = axis
        alwaysBounceVertical = axis == .vertical
        alwaysBounceHorizontal = axis == .horizontal
    }
}

/// Text with padding of its own: the padding is inside the label, around
/// the text, and counts in its measured size.
private final class CraftNativeLabel: UILabel {
    var insets = UIEdgeInsets.zero {
        didSet {
            guard insets != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        guard insets != .zero else { return super.textRect(forBounds: bounds, limitedToNumberOfLines: numberOfLines) }
        let inner = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
        return CGRect(
            x: inner.minX - insets.left,
            y: inner.minY - insets.top,
            width: inner.width + insets.left + insets.right,
            height: inner.height + insets.top + insets.bottom
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        craftApplyCornerRadius()
    }
}

private final class CraftNativeFlexSpacer: UIView {}

/// An SF Symbol leaf. Its natural size is the symbol's, or a 20 pt square
/// when the style gives it no size at all.
private final class CraftNativeIconView: UIImageView {
    var defaultBox: CGFloat? { didSet { if defaultBox != oldValue { invalidateIntrinsicContentSize() } } }

    override var intrinsicContentSize: CGSize {
        if let defaultBox { return CGSize(width: defaultBox, height: defaultBox) }
        return super.intrinsicContentSize
    }
}

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
    private var pressInHandlers: [ObjectIdentifier: String] = [:]
    private var pressOutHandlers: [ObjectIdentifier: String] = [:]
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
    private var pressFeedbackRecognizers: [ObjectIdentifier: UILongPressGestureRecognizer] = [:]
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
    /// The hybrid shell (CraftHybrid.swift), when this screen is one of a web
    /// app's native screens: told of the first frame, of a first frame that
    /// could not be drawn, and of `craft.navigation.open(path)`.
    weak var hybridEvents: CraftHybridScreenEvents?
    private var hybridRendered = false

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
        rootTopToSafeArea = rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        rootTopToView = rootStack.topAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([
            rootTopToSafeArea!,
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
        send(type: "APPEARANCE", payload: ["colorScheme": colorScheme])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let navigationBarHidden, navigationController?.isNavigationBarHidden != navigationBarHidden {
            navigationController?.setNavigationBarHidden(navigationBarHidden, animated: animated)
        } else if navigationBarHidden == nil, navigationController?.isNavigationBarHidden == true,
                  navigationController?.viewControllers.first !== self || wantsNavigationBar {
            // A screen that did not ask for a hidden bar shows one, even after
            // a screen that hid its own.
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
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

    private static func safeJavaScriptString(_ value: JSValue?) -> String? {
        guard let value, !value.isUndefined, !value.isNull, value.isString else { return nil }
        return value.toString()
    }

    private func setupJavaScript() {
        if let routeName = routeName {
            jsContext.setObject(routeName, forKeyedSubscript: "__stxNativeRoute" as NSString)
        }
        jsContext.setObject(routeParams as NSDictionary, forKeyedSubscript: "__stxNativeParams" as NSString)
        jsContext.exceptionHandler = { [weak self] context, exception in
            // Never stringify an arbitrary JS object here. JavaScriptCore can
            // re-enter this handler while coercing an exception whose
            // `toString` is broken, turning a page error into a native crash.
            let message = Self.safeJavaScriptString(exception?.objectForKeyedSubscript("message"))
                ?? Self.safeJavaScriptString(exception)
                ?? "unknown"
            let stack = Self.safeJavaScriptString(exception?.objectForKeyedSubscript("stack")) ?? ""
            CraftNativeConsole.write("error", category: self?.screenName(in: context) ?? "screen", message: stack.isEmpty || stack == "undefined" ? "Uncaught \(message)" : "Uncaught \(message)\n\(stack)")
            self?.hybridFailed(message)
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
                colorScheme: "\(colorScheme)",
                postMessage: function(message) { craftNativePostMessage(message); },
                onMessage: function(callback) { globalThis.__stxNativeCallback = callback; }
            };
        """)
        installHostAPIs()
        jsContext.evaluateScript("""
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
            // Repeating timers, on the one-shot ones: each tick schedules the
            // next before running, so a callback that throws or clears itself
            // still behaves, and a screen that closes cancels them with the rest.
            if (typeof globalThis.setInterval !== 'function') {
                (function() {
                    var intervals = new Map();
                    var nextInterval = 0;
                    globalThis.setInterval = function(callback, delay) {
                        var args = Array.prototype.slice.call(arguments, 2);
                        var id = ++nextInterval;
                        var ms = Math.max(Number(delay) || 0, 1);
                        var tick = function() {
                            if (!intervals.has(id)) return;
                            intervals.set(id, globalThis.setTimeout(tick, ms));
                            if (typeof callback === 'function') callback.apply(undefined, args);
                        };
                        intervals.set(id, globalThis.setTimeout(tick, ms));
                        return id;
                    };
                    globalThis.clearInterval = function(id) {
                        var timer = intervals.get(id);
                        if (timer === undefined) return;
                        intervals.delete(id);
                        globalThis.clearTimeout(timer);
                    };
                })();
            }
        """)
    }

    /// `"dark"` or `"light"` for the bundle's `dark:` classes (contract A4):
    /// the window's appearance once there is one, else the app's setting.
    private var colorScheme: String {
        let traits = [view.window?.traitCollection, CraftPresenter.keyWindow()?.traitCollection, traitCollection]
        if let style = traits.compactMap({ $0 }).first(where: { $0.userInterfaceStyle != .unspecified })?.userInterfaceStyle {
            return style == .dark ? "dark" : "light"
        }
        return config.appearance == "dark" ? "dark" : "light"
    }

    /// The screen's name as its script knows it: the route the host opened,
    /// else the one a route bundle selected for itself.
    private func screenName(in context: JSContext? = nil) -> String {
        if let routeName, !routeName.isEmpty { return routeName }
        if let selected = (context ?? jsContext).objectForKeyedSubscript("__stxNativeRoute"), selected.isString {
            return selected.toString()
        }
        return "screen"
    }

    /// Host functions every screen script can call synchronously, installed
    /// before the script runs (contract sections 3, 4 and 5):
    ///
    /// - `console.*` writes to the unified log, subsystem `craft.native`,
    ///   category the screen's name.
    /// - `craft.storage.getSync(key)` / `setSync(key, value)`: the store the
    ///   asynchronous `craft.storage` uses. `getSync` answers what `get` would.
    /// - `craft.snapshots.get(name)` (sync) and `set(name, value)` (a
    ///   promise): `Application Support/craft-snapshots/<name>.json`.
    /// - `craft.secureStorage.getSync(key)`: the Keychain item the web page's
    ///   `craft.secureStorage.set` wrote.
    /// - `craft.navigation.setOptions({ title, largeTitle, hidden, backTitle,
    ///   rightButtons })`; a right button's tap is the event `navButton`.
    ///
    /// A runtime that assigns `craft.storage` (or the others) afterwards keeps
    /// these: each namespace is a property whose setter adds them back to the
    /// object it is given.
    private func installHostAPIs() {
        let log: @convention(block) (String, String, String) -> Void = { level, category, message in
            CraftNativeConsole.write(level, category: category, message: message)
        }
        let storageGet: @convention(block) (String) -> String? = { key in
            CraftNativeActions.storageJSON(forKey: key)
        }
        let storageSet: @convention(block) (String, JSValue) -> Bool = { key, value in
            CraftNativeActions.setStorageJSON(value.isNull || value.isUndefined ? nil : value.toString(), forKey: key)
        }
        let snapshotGet: @convention(block) (String) -> String? = { name in
            CraftSnapshots.read(name)
        }
        let snapshotSet: @convention(block) (String, JSValue, JSValue) -> Void = { name, value, done in
            CraftSnapshots.write(name, json: value.isNull || value.isUndefined ? nil : value.toString()) { ok in
                done.call(withArguments: [ok])
            }
        }
        let config = self.config
        let secureGet: @convention(block) (String) -> String? = { key in
            config.enableSecureStorage ? CraftNativeActions.webSecureValue(forKey: key) : nil
        }
        let setOptions: @convention(block) (String) -> Void = { [weak self] json in
            guard let data = json.data(using: .utf8),
                  let options = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self?.applyNavigationOptions(options)
        }
        jsContext.setObject(log, forKeyedSubscript: "craftNativeLog" as NSString)
        jsContext.setObject(storageGet, forKeyedSubscript: "craftNativeStorageGet" as NSString)
        jsContext.setObject(storageSet, forKeyedSubscript: "craftNativeStorageSet" as NSString)
        jsContext.setObject(snapshotGet, forKeyedSubscript: "craftNativeSnapshotGet" as NSString)
        jsContext.setObject(snapshotSet, forKeyedSubscript: "craftNativeSnapshotSet" as NSString)
        jsContext.setObject(secureGet, forKeyedSubscript: "craftNativeSecureGet" as NSString)
        jsContext.setObject(setOptions, forKeyedSubscript: "craftNativeSetOptions" as NSString)
        jsContext.evaluateScript("""
            (function() {
                function text(value) {
                    if (typeof value === 'string') return value;
                    if (value === undefined) return 'undefined';
                    if (value instanceof Error) return value.stack ? value.message + '\\n' + value.stack : String(value);
                    try { var json = JSON.stringify(value); return json === undefined ? String(value) : json; }
                    catch (error) { return String(value); }
                }
                function screen() {
                    var route = globalThis.__stxNativeRoute;
                    return typeof route === 'string' && route ? route : 'screen';
                }
                function writer(level) {
                    return function() {
                        craftNativeLog(level, screen(), Array.prototype.map.call(arguments, text).join(' '));
                    };
                }
                globalThis.console = {
                    log: writer('log'), info: writer('info'), debug: writer('debug'), trace: writer('debug'),
                    warn: writer('warn'), error: writer('error')
                };

                function parsed(json) {
                    if (json === null || json === undefined) return null;
                    try { return JSON.parse(json); } catch (error) { return null; }
                }
                function encoded(value) {
                    return value === null || value === undefined ? null : JSON.stringify(value);
                }
                var craft = globalThis.craft = globalThis.craft || {};
                function keep(name, extras) {
                    var current = {};
                    function adopt(next) {
                        current = next && typeof next === 'object' ? next : {};
                        Object.keys(extras).forEach(function(key) {
                            if (!(key in current)) current[key] = extras[key];
                        });
                    }
                    adopt(craft[name]);
                    Object.defineProperty(craft, name, {
                        configurable: true,
                        enumerable: true,
                        get: function() { return current; },
                        set: adopt
                    });
                }
                keep('storage', {
                    getSync: function(key) { return parsed(craftNativeStorageGet(String(key))); },
                    setSync: function(key, value) {
                        if (!craftNativeStorageSet(String(key), encoded(value))) throw new Error('craft.storage.setSync could not store ' + key);
                    }
                });
                keep('snapshots', {
                    get: function(name) { return parsed(craftNativeSnapshotGet(String(name))); },
                    set: function(name, value) {
                        return new Promise(function(resolve, reject) {
                            craftNativeSnapshotSet(String(name), encoded(value), function(ok) {
                                if (ok) resolve();
                                else reject(new Error('craft.snapshots.set could not write ' + name));
                            });
                        });
                    }
                });
                keep('secureStorage', {
                    getSync: function(key) {
                        var value = craftNativeSecureGet(String(key));
                        return value === undefined ? null : value;
                    }
                });
                keep('navigation', {
                    setOptions: function(options) { craftNativeSetOptions(JSON.stringify(options || {})); }
                });
            })();
        """)
    }

    private func loadBundle() {
        guard let url = Bundle.main.url(forResource: "native-screen", withExtension: "js", subdirectory: "dist")
            ?? Bundle.main.url(forResource: "native-screen", withExtension: "js"),
            let script = try? String(contentsOf: url, encoding: .utf8) else {
            showError("Missing dist/native-screen.js. Compile a .stx screen with `stx native compile` first.")
            return
        }
        jsContext.evaluateScript(script)
        // A bundle that names no route leaves `__stxNativeRoute` undefined;
        // its title is the app's, not the word "undefined". A title the
        // script set with `navigation.setOptions` wins over both.
        if routeName == nil, !titleFromOptions,
           let selected = jsContext.objectForKeyedSubscript("__stxNativeRoute"), selected.isString,
           let name = selected.toString(), !name.isEmpty {
            navigationItem.title = name
        }
    }

    // MARK: Navigation bar options

    private var titleFromOptions = false
    private var rootTopToSafeArea: NSLayoutConstraint?
    private var rootTopToView: NSLayoutConstraint?
    private var navigationBarHidden: Bool?
    private var prefersLargeTitle: Bool?

    /// Whether this screen asked for a bar of its own through `setOptions`: a
    /// title, a large title or buttons, and not `hidden`. A tab's root screen
    /// in a hybrid app is shown bare unless it did.
    var wantsNavigationBar: Bool {
        if let navigationBarHidden { return !navigationBarHidden }
        return titleFromOptions || prefersLargeTitle == true || !(navigationItem.rightBarButtonItems ?? []).isEmpty
    }
    private weak var trackedScrollView: UIScrollView?

    /// `craft.navigation.setOptions`: this screen's bar. Every key is
    /// optional and only the keys given change.
    private func applyNavigationOptions(_ options: [String: Any]) {
        if options.keys.contains("title") {
            navigationItem.title = options["title"] as? String
            titleFromOptions = true
        }
        if options.keys.contains("backTitle") {
            navigationItem.backButtonTitle = options["backTitle"] as? String
        }
        if let largeTitle = options["largeTitle"] as? Bool {
            prefersLargeTitle = largeTitle
            navigationItem.largeTitleDisplayMode = largeTitle ? .always : .never
            if largeTitle { navigationController?.navigationBar.prefersLargeTitles = true }
            trackContentScrollView()
        }
        if let hidden = options["hidden"] as? Bool {
            navigationBarHidden = hidden
            if navigationController?.topViewController === self {
                navigationController?.setNavigationBarHidden(hidden, animated: view.window != nil)
            }
        }
        if options.keys.contains("rightButtons") {
            let buttons = (options["rightButtons"] as? [[String: Any]]) ?? []
            navigationItem.rightBarButtonItems = buttons.compactMap(navigationButton).reversed()
        }
        // Asked for after the bar was hidden for a bare root screen.
        if navigationBarHidden == nil, wantsNavigationBar, navigationController?.topViewController === self,
           navigationController?.isNavigationBarHidden == true {
            navigationController?.setNavigationBarHidden(false, animated: view.window != nil)
        }
    }

    /// A bar button from `{ id, symbol | title }`. Its tap is the event
    /// `navButton` with `{ id }`.
    private func navigationButton(_ spec: [String: Any]) -> UIBarButtonItem? {
        guard let id = spec["id"] as? String, !id.isEmpty else { return nil }
        let action = UIAction { [weak self] _ in
            self?.send(type: "EVENT", payload: ["handlerName": "navButton", "nativeEvent": ["id": id]])
        }
        let item: UIBarButtonItem
        if let symbol = spec["symbol"] as? String, let image = UIImage(systemName: symbol) {
            item = UIBarButtonItem(image: image, primaryAction: action)
        } else if let title = spec["title"] as? String {
            item = UIBarButtonItem(title: title, primaryAction: action)
        } else {
            return nil
        }
        item.accessibilityIdentifier = "nav-\(id)"
        if let label = (spec["accessibilityLabel"] as? String) ?? (spec["title"] as? String) {
            item.accessibilityLabel = label
        } else {
            item.accessibilityLabel = id
        }
        if let tint = (spec["color"] as? String).flatMap({ UIColor(hex: $0) }) { item.tintColor = tint }
        // `image`: a picture (an https URL, the account's own photo), drawn
        // round as iOS draws an account button. The symbol or title shows
        // until it has loaded, and stays if it cannot be.
        if let source = spec["image"] as? String, let url = URL(string: source), url.scheme == "https" {
            loadBarImage(url) { [weak item] image in
                guard let item, let image else { return }
                let size = CGSize(width: 32, height: 32)
                let round = UIGraphicsImageRenderer(size: size).image { _ in
                    UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).addClip()
                    let scale = max(size.width / image.size.width, size.height / image.size.height)
                    let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
                }
                item.title = nil
                item.image = round.withRenderingMode(.alwaysOriginal)
            }
        }
        return item
    }

    /// A bar picture, kept for the app's life so each screen does not fetch it again.
    private static let barImages = NSCache<NSURL, UIImage>()

    private func loadBarImage(_ url: URL, _ done: @escaping (UIImage?) -> Void) {
        if let cached = Self.barImages.object(forKey: url as NSURL) { done(cached); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap(UIImage.init(data:))
            if let image { Self.barImages.setObject(image, forKey: url as NSURL) }
            DispatchQueue.main.async { done(image) }
        }.resume()
    }

    /// The first vertical scroll view of the screen drives the bar: a large
    /// title collapses as it scrolls, and the bar's background follows it.
    private func trackContentScrollView() {
        guard let renderedRoot else { return }
        func find(_ node: RenderedNode) -> UIScrollView? {
            if let scroll = node.view as? CraftNativeScrollView, scroll.isVertical, scroll.isScrollEnabled { return scroll }
            if let list = node.view as? CraftNativeFlatList, list.isScrollEnabled,
               (list.collectionViewLayout as? UICollectionViewFlowLayout)?.scrollDirection != .horizontal { return list }
            for child in node.children {
                if let match = find(child) { return match }
            }
            return nil
        }
        let scroll = find(renderedRoot)
        // Under a large title the screen runs edge to edge, as UIKit's own
        // screens do: the scroll view starts under the bar and insets its
        // content by it, so the title collapses and pull to refresh draws
        // in the bar's space. Other screens stay inside the safe area.
        let edgeToEdge = scroll != nil && prefersLargeTitle == true
        if rootTopToView?.isActive != edgeToEdge {
            rootTopToSafeArea?.isActive = !edgeToEdge
            rootTopToView?.isActive = edgeToEdge
        }
        guard scroll !== trackedScrollView else { return }
        trackedScrollView = scroll
        setContentScrollView(scroll, for: .top)
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
        hybridFailed(message)
    }

    /// Only before the first frame: later exceptions belong to a screen that
    /// is up, and are logged.
    private func hybridFailed(_ message: String) {
        guard !hybridRendered else { return }
        hybridEvents?.nativeScreen(self, didFail: message)
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
            next.hybridEvents = hybridEvents
            if type == "NAVIGATE" {
                navigation.pushViewController(next, animated: true)
            } else {
                navigation.setViewControllers(Array(navigation.viewControllers.dropLast()) + [next], animated: true)
            }
        case "NAVIGATION_SET_OPTIONS":
            applyNavigationOptions(payload)
        case "NAVIGATE_OPEN":
            // A path rather than a screen: the hybrid shell opens it, natively
            // or in the web view.
            guard let path = payload["path"] as? String, !path.isEmpty else { return }
            hybridEvents?.nativeScreen(self, open: path)
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

    /// Runs script in the screen's JavaScript context. Internal for
    /// simulator-hosted XCTest of the host APIs.
    @discardableResult
    func evaluateScript(_ script: String) -> JSValue? {
        jsContext.evaluateScript(script)
    }

    // Internal so simulator-hosted XCTest can assert actual UIView identity.
    func render(_ document: [String: Any]) {
        mutationDocument.replace(with: document)
        renderCommitted(document)
        if !hybridRendered {
            hybridRendered = true
            hybridEvents?.nativeScreenDidRender(self)
        }
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
            let next = reconcile(document, identity: previous.identity, path: target, previous: previous)
            // A style patch is applied in place, layout included: the parent
            // reads the node's new layout style on its next pass.
            CraftNativeFlexLayout.invalidateAncestors(of: next.view)
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
        }
        // A failed or interrupted reconciliation can leave an older root
        // attached even though `renderedRoot` points at the latest tree. Keep
        // the host single-rooted so accessibility queries and event routing
        // never see stale copies of the native screen.
        for child in rootStack.arrangedSubviews where child !== next.view {
            rootStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        if next.view.superview !== rootStack { rootStack.addArrangedSubview(next.view) }
        rootStack.setLayoutStyle(next.style, for: next.view)
        rootStack.invalidateMeasurements()
        renderedRoot = next
        trackContentScrollView()
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
            (label as? CraftNativeLabel)?.insets = paddingInsets(style)
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
            // The plain title too, so `title(for:)` and accessibility read it.
            if button.title(for: .normal) != transformedTitle { button.setTitle(transformedTitle, for: .normal) }
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
            // Secure entry first: turning it on resets the capitalization.
            let desiredSecureEntry = props["secureTextEntry"] as? Bool == true
            if field.isSecureTextEntry != desiredSecureEntry { field.isSecureTextEntry = desiredSecureEntry }
            let desiredCapitalization = capitalizationType(props["autoCapitalize"])
            if field.autocapitalizationType != desiredCapitalization { field.autocapitalizationType = desiredCapitalization }
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
        case "Icon":
            configureIcon(result as! UIImageView, props: props, style: style)
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
            scroll.setKeyboardShouldPersistTaps(props["keyboardShouldPersistTaps"])
            scroll.showsVerticalScrollIndicator = props["showsVerticalScrollIndicator"] as? Bool != false
            scroll.showsHorizontalScrollIndicator = props["showsHorizontalScrollIndicator"] as? Bool != false
            scroll.alwaysBounceVertical = props["alwaysBounceVertical"] as? Bool ?? (direction == .vertical)
            scroll.alwaysBounceHorizontal = props["alwaysBounceHorizontal"] as? Bool ?? (direction == .horizontal)
            scroll.setStickyHeaderIndices(props["stickyHeaderIndices"])
            scroll.setScrollTarget(props["scrollTarget"])
            updateAuxiliaryHandler(events["onScroll"], in: &scrollHandlers, for: scroll)
            updateAuxiliaryHandler(events["onScrollBeginDrag"], in: &scrollBeginHandlers, for: scroll)
            updateAuxiliaryHandler(events["onScrollEndDrag"], in: &scrollEndHandlers, for: scroll)
            updateAuxiliaryHandler(events["onMomentumScrollBegin"], in: &scrollMomentumBeginHandlers, for: scroll)
            updateAuxiliaryHandler(events["onMomentumScrollEnd"], in: &scrollMomentumEndHandlers, for: scroll)
            scroll.setRefreshHandler(nonEmptyHandler(events["onRefresh"]).map { [weak self] handler in
                { self?.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]]) }
            }, refreshing: props["refreshing"] as? Bool == true)
            var contentStyle = style
            if let override = props["contentContainerStyle"] as? [String: Any] {
                contentStyle.merge(override) { _, next in next }
            }
            configureStack(scroll.contentStack, style: contentStyle)
            reconcileChildren(children, in: scroll.contentStack, parent: current, path: path, style: contentStyle)
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
            updatePressFeedback(
                disabled ? nil : nonEmptyHandler(events["onPressIn"]),
                disabled ? nil : nonEmptyHandler(events["onPressOut"]),
                for: result
            )
            if disabled { result.isUserInteractionEnabled = false }
        }
        applyAccessibility(props, type: type, to: result)
        return current
    }

    private func makeView(_ type: String, props: [String: Any]) -> UIView {
        switch type {
        case "Text":
            let label = CraftNativeLabel()
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
        case "Icon":
            let icon = CraftNativeIconView()
            icon.contentMode = .scaleAspectFit
            return icon
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
        // The current stx native compiler emits key in props; accept the IR
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
        list.isScrollEnabled = props["scrollEnabled"] as? Bool != false
        list.onFittingHeightChanged = { [weak list] in
            guard let list else { return }
            CraftNativeFlexLayout.invalidateAncestors(of: list)
        }
        list.setKeyboardShouldPersistTaps(props["keyboardShouldPersistTaps"])
        list.setContentContainerStyle(props["contentContainerStyle"] as? [String: Any])
        list.setRefreshHandler(nonEmptyHandler(events["onRefresh"]).map { [weak self] handler in
            { self?.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]]) }
        }, refreshing: props["refreshing"] as? Bool == true)
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
        (node.view as? CraftNativeScrollView)?.setRefreshHandler(nil, refreshing: false)
        if let list = node.view as? CraftNativeFlatList {
            let listKey = ObjectIdentifier(list)
            list.setRefreshHandler(nil, refreshing: false)
            list.discardAll()
            flatListRows.removeValue(forKey: listKey)
            if let owner = node.protocolId { flatListOwners = flatListOwners.filter { $0.value != owner } }
        }
        let id = ObjectIdentifier(node.view)
        handlers.removeValue(forKey: id)
        pressInHandlers.removeValue(forKey: id)
        pressOutHandlers.removeValue(forKey: id)
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
        if let recognizer = pressFeedbackRecognizers.removeValue(forKey: id) {
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

    private func updatePressFeedback(_ pressIn: String?, _ pressOut: String?, for view: UIView) {
        let id = ObjectIdentifier(view)
        if let pressIn, !pressIn.isEmpty { pressInHandlers[id] = pressIn } else { pressInHandlers.removeValue(forKey: id) }
        if let pressOut, !pressOut.isEmpty { pressOutHandlers[id] = pressOut } else { pressOutHandlers.removeValue(forKey: id) }
        guard pressInHandlers[id] != nil || pressOutHandlers[id] != nil else {
            if let recognizer = pressFeedbackRecognizers.removeValue(forKey: id) { view.removeGestureRecognizer(recognizer) }
            if !(view is UIScrollView) { view.isUserInteractionEnabled = handlers[id] != nil || longPressHandlers[id] != nil || view is CraftNativeFlowView }
            return
        }
        if pressFeedbackRecognizers[id] == nil {
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(viewPressFeedback(_:)))
            recognizer.minimumPressDuration = 0
            recognizer.allowableMovement = 10
            recognizer.cancelsTouchesInView = false
            pressFeedbackRecognizers[id] = recognizer
            view.addGestureRecognizer(recognizer)
        }
        if !(view is UIScrollView) { view.isUserInteractionEnabled = true }
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

    /// `<Icon symbol="sun.max">`: an SF Symbol, tinted by `color`, sized by
    /// `fontSize` or else the icon's box, weighted by `fontWeight`. A name
    /// the system does not have draws `circle`, so a typo shows rather than
    /// leaving a hole.
    private func configureIcon(_ icon: UIImageView, props: [String: Any], style: [String: Any]) {
        let name = (props["symbol"] as? String) ?? (props["name"] as? String) ?? ""
        let box = [number(style["width"]), number(style["height"])].compactMap { $0 }.min()
        let fontSize = number(style["fontSize"])
        // Without a size of its own an icon is a 20 pt square (contract A2).
        (icon as? CraftNativeIconView)?.defaultBox = box == nil && fontSize == nil ? 20 : nil
        let pointSize = fontSize ?? (box ?? 20) * 0.84
        let weight: UIImage.SymbolWeight
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
        let scale: UIImage.SymbolScale
        switch props["scale"] as? String {
        case "small": scale = .small
        case "large": scale = .large
        default: scale = .medium
        }
        let configuration = UIImage.SymbolConfiguration(pointSize: max(1, pointSize), weight: weight, scale: scale)
        let image = UIImage(systemName: name, withConfiguration: configuration)
            ?? UIImage(systemName: "circle", withConfiguration: configuration)
        if icon.image != image { icon.image = image }
        icon.preferredSymbolConfiguration = configuration
        icon.tintColor = color(style["color"]) ?? color(props["color"]) ?? .label
        icon.contentMode = .scaleAspectFit
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
        stack.padding = paddingInsets(style)
        stack.invalidateMeasurements()
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
        view.craftRequestedCornerRadius = number(style["borderRadius"])
        view.layer.borderWidth = number(style["borderWidth"]) ?? 0
        view.layer.borderColor = (color(style["borderColor"]) ?? .clear).cgColor
        let elevation = max(0, number(style["elevation"]) ?? 0)
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = elevation > 0 ? Float(min(0.28, 0.12 + elevation * 0.02)) : 0
        view.layer.shadowRadius = elevation * 0.5
        view.layer.shadowOffset = CGSize(width: 0, height: elevation * 0.25)
        // A label paints its background inside its own bounds, so a rounded
        // chip of text clips to its corners.
        view.clipsToBounds = style["overflow"] as? String == "hidden"
            || (view is UILabel && (view.craftRequestedCornerRadius ?? 0) > 0)
        view.layer.masksToBounds = view.clipsToBounds
        view.craftLayoutStyle = CraftNativeLayoutStyle(style)
        (view as? CraftNativeFlowView)?.invalidateMeasurements()
        (view as? CraftNativeScrollView)?.setContentNeedsLayout()
    }

    private func paddingInsets(_ style: [String: Any]) -> UIEdgeInsets {
        let padding = number(style["padding"]) ?? 0
        let horizontal = number(style["paddingHorizontal"]) ?? padding
        let vertical = number(style["paddingVertical"]) ?? padding
        return UIEdgeInsets(
            top: number(style["paddingTop"]) ?? vertical,
            left: number(style["paddingLeft"]) ?? horizontal,
            bottom: number(style["paddingBottom"]) ?? vertical,
            right: number(style["paddingRight"]) ?? horizontal
        )
    }

    private func configureText(_ label: UILabel, text: String, style: [String: Any]) {
        let transformed = transformedText(text, style: style)
        label.textColor = color(style["color"]) ?? .label
        label.font = textFont(style, default: .systemFont(ofSize: 16))
        label.textAlignment = textAlignment(style["textAlign"])
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let spacing = number(style["letterSpacing"]) { attributes[.kern] = spacing }
        switch style["textDecorationLine"] as? String {
        case "underline": attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        case "line-through": attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        case "underline line-through":
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        default: break
        }
        if let lineHeight = number(style["lineHeight"]) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            paragraph.alignment = label.textAlignment
            attributes[.paragraphStyle] = paragraph
        }
        let alignment = label.textAlignment
        let lineBreakMode = label.lineBreakMode
        label.attributedText = attributes.isEmpty ? nil : NSAttributedString(string: transformed, attributes: attributes)
        if attributes.isEmpty { label.text = transformed }
        // Attributed text brings its own paragraph style, which resets the
        // label's alignment and truncation; set them again over the whole text.
        label.textAlignment = alignment
        label.lineBreakMode = lineBreakMode
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
                // Below required: the flex layout owns frames, and a width
                // the layout stretches or shrinks must not log a conflict.
                constraint = anchor.constraint(equalToConstant: value)
                constraint?.priority = UILayoutPriority(999)
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
        let id = ObjectIdentifier(view)
        if pressInHandlers[id] == nil, pressOutHandlers[id] == nil,
           let pressable = view as? CraftNativeFlowView, let activeOpacity = pressable.pressActiveOpacity {
            UIView.animate(withDuration: 0.1, animations: { pressable.alpha = pressable.pressBaseOpacity * activeOpacity }) { _ in
                UIView.animate(withDuration: 0.1) { pressable.alpha = pressable.pressBaseOpacity }
            }
        }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]])
    }

    @objc private func viewPressFeedback(_ sender: UILongPressGestureRecognizer) {
        guard let view = sender.view else { return }
        let id = ObjectIdentifier(view)
        switch sender.state {
        case .began:
            if let pressable = view as? CraftNativeFlowView, let activeOpacity = pressable.pressActiveOpacity {
                UIView.animate(withDuration: 0.1) { pressable.alpha = pressable.pressBaseOpacity * activeOpacity }
            }
            if let handler = pressInHandlers[id] { send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]]) }
        case .ended, .cancelled, .failed:
            if let pressable = view as? CraftNativeFlowView { UIView.animate(withDuration: 0.1) { pressable.alpha = pressable.pressBaseOpacity } }
            if let handler = pressOutHandlers[id] { send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]]) }
        default:
            break
        }
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

    /// A style colour: CSS hex with or without alpha (`#10b9811a` is
    /// emerald at 10%), `rgb()`/`rgba()` and the few names; `UIColor(hex:)`
    /// for anything else it has always read.
    private func color(_ value: Any?) -> UIColor? {
        guard let text = value as? String else { return nil }
        return UIColor(css: text) ?? UIColor(hex: text)
    }
}

/// `console` for native screens: the unified log, subsystem `craft.native`,
/// category the screen's name. Read it with
/// `log stream --predicate 'subsystem == "craft.native"'`.
enum CraftNativeConsole {
    private static var loggers: [String: Logger] = [:]
    private static let lock = NSLock()

    static func write(_ level: String, category: String, message: String) {
        lock.lock()
        let logger = loggers[category] ?? Logger(subsystem: "craft.native", category: category)
        loggers[category] = logger
        lock.unlock()
        switch level {
        case "debug": logger.debug("\(message, privacy: .public)")
        case "info": logger.info("\(message, privacy: .public)")
        case "warn": logger.warning("\(message, privacy: .public)")
        case "error": logger.error("\(message, privacy: .public)")
        default: logger.notice("\(message, privacy: .public)")
        }
    }
}
