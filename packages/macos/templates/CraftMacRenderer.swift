import AppKit
import AVKit
import Darwin

enum CraftMacColor {
    static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    static func parse(_ value: Any?, fallback: NSColor = .labelColor) -> NSColor {
        guard let text = value as? String else { return fallback }
        if text == "transparent" { return .clear }
        let named: [String: NSColor] = ["label": .labelColor, "secondaryLabel": .secondaryLabelColor, "separator": .separatorColor,
            "controlBackground": .controlBackgroundColor, "windowBackground": .windowBackgroundColor, "textBackground": .textBackgroundColor,
            "accent": .controlAccentColor, "white": .white, "black": .black]
        if let color = named[text] { return color }
        let hex = text.replacingOccurrences(of: "#", with: "")
        if let n = UInt64(hex, radix: 16), hex.count == 6 || hex.count == 8 {
            let rgb = hex.count == 8 ? n >> 8 : n
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255,
                           alpha: hex.count == 8 ? CGFloat(n & 255) / 255 : 1)
        }
        return fallback
    }
}

/// The same C ABI used by Craft's mobile hosts. AppKit supplies text metrics;
/// Zig supplies flex sizing and justification, without a second layout rule.
enum CraftMacFlex {
    struct Item { var basis: Float; var grow: Float; var shrink: Float; var min: Float; var max: Float; var start: Float; var end: Float }
    typealias Function = @convention(c) (Float, Float, UInt32, UnsafeRawPointer, Int, UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    static let function: Function = {
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "craft_native_flex_row_justified") else { fatalError("Craft's shared native layout library is missing") }
        return unsafeBitCast(address, to: Function.self)
    }()
    static func layout(_ items: [Item], available: CGFloat, gap: CGFloat, justify: String) -> [(CGFloat, CGFloat)] {
        guard !items.isEmpty else { return [] }
        let code: UInt32 = ["flex-start": 0, "center": 1, "flex-end": 2, "space-between": 3, "space-around": 4, "space-evenly": 5][justify] ?? 0
        var widths = [Float](repeating: 0, count: items.count), positions = widths
        let status = items.withUnsafeBufferPointer { input in widths.withUnsafeMutableBufferPointer { output in positions.withUnsafeMutableBufferPointer { offsets in
            function(Float(available), Float(gap), code, UnsafeRawPointer(input.baseAddress!), items.count, UnsafeMutableRawPointer(output.baseAddress!), UnsafeMutableRawPointer(offsets.baseAddress!))
        } } }
        precondition(status == 0, "Shared native layout rejected finite dimensions")
        return zip(widths, positions).map { (CGFloat($0), CGFloat($1)) }
    }
}

final class CraftMacFlow: NSView {
    var boxes: [CraftMacBox] = []
    var style: [String: Any] = [:]
    var componentScope = false
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        layoutBoxes(in: bounds.size)
    }
    func layoutBoxes(in size: CGSize) {
        // AppKit can lay out this inner flow after its owning box. Component
        // scopes must preserve the root's allocation on that later pass too.
        if componentScope, boxes.count == 1, boxes[0].kind != "Modal", boxes[0].superview === self {
            boxes[0].frame = CGRect(origin: .zero, size: size)
            boxes[0].layoutSubtreeIfNeeded()
            return
        }
        let horizontal = style["flexDirection"] as? String == "row"
        let padding = dimension(style["padding"], base: size.width) ?? 0
        let left = dimension(style["paddingLeft"], base: size.width) ?? dimension(style["paddingHorizontal"], base: size.width) ?? padding
        let right = dimension(style["paddingRight"], base: size.width) ?? dimension(style["paddingHorizontal"], base: size.width) ?? padding
        let top = dimension(style["paddingTop"], base: size.height) ?? dimension(style["paddingVertical"], base: size.height) ?? padding
        let bottom = dimension(style["paddingBottom"], base: size.height) ?? dimension(style["paddingVertical"], base: size.height) ?? padding
        let inner = CGSize(width: max(0, size.width - left - right), height: max(0, size.height - top - bottom))
        let visible = boxes.filter { !$0.isHidden && $0.kind != "Modal" && $0.layoutStyle["position"] as? String != "absolute" }
        let gap = dimension(style["gap"], base: inner.width) ?? 0
        // Margins on the cross axis (left and right in a column, top and bottom in a row) shrink what a child may fill and offset it.
        func crossMargins(_ box: CraftMacBox) -> (start: CGFloat, end: CGFloat) {
            let layout = box.layoutStyle
            let margin = number(layout["margin"]) ?? 0
            let axis = number(layout[horizontal ? "marginVertical" : "marginHorizontal"]) ?? margin
            return (number(layout[horizontal ? "marginTop" : "marginLeft"]) ?? axis, number(layout[horizontal ? "marginBottom" : "marginRight"]) ?? axis)
        }
        let sizes = visible.map { box in
            let alignment = box.layoutStyle["alignSelf"] as? String ?? style["alignItems"] as? String ?? "stretch"
            let margins = crossMargins(box)
            return box.measure(width: horizontal ? inner.width : max(0, inner.width - margins.start - margins.end), stretch: !horizontal && alignment == "stretch")
        }
        let items = visible.enumerated().map { index, box -> CraftMacFlex.Item in
            let main = horizontal ? sizes[index].width : sizes[index].height
            let layout = box.layoutStyle
            let grow = number(layout["flexGrow"]) ?? number(layout["flex"]) ?? 0
            let basis = dimension(layout["flexBasis"], base: horizontal ? inner.width : inner.height) ?? (number(layout["flex"]) != nil ? 0 : main)
            let shrink = number(layout["flexShrink"]) ?? (grow > 0 ? 1 : 0)
            let minimum = dimension(layout[horizontal ? "minWidth" : "minHeight"], base: horizontal ? inner.width : inner.height)
            let maximum = dimension(layout[horizontal ? "maxWidth" : "maxHeight"], base: horizontal ? inner.width : inner.height)
            let margin = number(layout["margin"]) ?? 0
            let start = number(layout[horizontal ? "marginLeft" : "marginTop"]) ?? number(layout[horizontal ? "marginHorizontal" : "marginVertical"]) ?? margin
            let end = number(layout[horizontal ? "marginRight" : "marginBottom"]) ?? number(layout[horizontal ? "marginHorizontal" : "marginVertical"]) ?? margin
            return .init(basis: Float(basis), grow: Float(grow), shrink: Float(shrink), min: minimum.map(Float.init) ?? .nan, max: maximum.map(Float.init) ?? .nan, start: Float(start), end: Float(end))
        }
        let frames = CraftMacFlex.layout(items, available: horizontal ? inner.width : inner.height, gap: gap, justify: style["justifyContent"] as? String ?? "flex-start")
        for (index, box) in visible.enumerated() {
            let margins = crossMargins(box)
            let crossAvailable = max(0, (horizontal ? inner.height : inner.width) - margins.start - margins.end)
            let crossExplicit = dimension(box.layoutStyle[horizontal ? "height" : "width"], base: crossAvailable)
            let alignment = box.layoutStyle["alignSelf"] as? String ?? style["alignItems"] as? String ?? "stretch"
            let measured = horizontal ? box.measure(width: frames[index].0, stretch: true) : sizes[index]
            let cross = min(crossAvailable, crossExplicit ?? (alignment == "stretch" ? crossAvailable : (horizontal ? measured.height : measured.width)))
            let offset = margins.start + (alignment == "center" ? (crossAvailable - cross) / 2 : alignment == "flex-end" ? crossAvailable - cross : 0)
            box.frame = horizontal ? CGRect(x: left + frames[index].1, y: top + offset, width: frames[index].0, height: cross)
                : CGRect(x: left + offset, y: top + frames[index].1, width: cross, height: frames[index].0)
            box.layoutSubtreeIfNeeded()
        }
        for box in boxes where !box.isHidden && box.layoutStyle["position"] as? String == "absolute" {
            let measured = box.measure(width: size.width)
            let leading = dimension(box.layoutStyle["left"], base: size.width), trailing = dimension(box.layoutStyle["right"], base: size.width)
            let above = dimension(box.layoutStyle["top"], base: size.height), below = dimension(box.layoutStyle["bottom"], base: size.height)
            let width = dimension(box.layoutStyle["width"], base: size.width) ?? (leading != nil && trailing != nil ? max(0, size.width - leading! - trailing!) : measured.width)
            let height = dimension(box.layoutStyle["height"], base: size.height) ?? (above != nil && below != nil ? max(0, size.height - above! - below!) : measured.height)
            box.frame = CGRect(x: (leading ?? (trailing.map { size.width - $0 - width } ?? 0)), y: (above ?? (below.map { size.height - $0 - height } ?? 0)), width: width, height: height)
            box.layoutSubtreeIfNeeded()
        }
    }
    func fitting(width: CGFloat, stretchChildren: Bool = true) -> CGSize {
        let padding = number(style["padding"]) ?? 0
        let horizontalPadding = (number(style["paddingLeft"]) ?? number(style["paddingHorizontal"]) ?? padding) + (number(style["paddingRight"]) ?? number(style["paddingHorizontal"]) ?? padding)
        let verticalPadding = (number(style["paddingTop"]) ?? number(style["paddingVertical"]) ?? padding) + (number(style["paddingBottom"]) ?? number(style["paddingVertical"]) ?? padding)
        let visible = boxes.filter { !$0.isHidden && $0.kind != "Modal" && $0.layoutStyle["position"] as? String != "absolute" }
        let available = max(0, width - horizontalPadding)
        var sizes = visible.map { box in
            let alignment = box.layoutStyle["alignSelf"] as? String ?? style["alignItems"] as? String ?? "stretch"
            return box.measure(width: available, stretch: stretchChildren && style["flexDirection"] as? String != "row" && alignment == "stretch")
        }
        let gaps = CGFloat(max(0, sizes.count - 1)) * (number(style["gap"]) ?? 0)
        if style["flexDirection"] as? String == "row" {
            let items = visible.enumerated().map { index, box -> CraftMacFlex.Item in
                let layout = box.layoutStyle
                let grow = number(layout["flexGrow"]) ?? number(layout["flex"]) ?? 0
                let basis = dimension(layout["flexBasis"], base: available) ?? (number(layout["flex"]) != nil ? 0 : sizes[index].width)
                return .init(basis: Float(basis), grow: Float(grow), shrink: Float(number(layout["flexShrink"]) ?? (grow > 0 ? 1 : 0)), min: dimension(layout["minWidth"], base: available).map(Float.init) ?? .nan, max: dimension(layout["maxWidth"], base: available).map(Float.init) ?? .nan, start: 0, end: 0)
            }
            let frames = CraftMacFlex.layout(items, available: available, gap: number(style["gap"]) ?? 0, justify: "flex-start")
            sizes = visible.enumerated().map { index, box in box.measure(width: frames[index].0, stretch: stretchChildren) }
            return CGSize(width: sizes.reduce(0) { $0 + $1.width } + horizontalPadding + gaps, height: (sizes.map(\.height).max() ?? 0) + verticalPadding)
        }
        let margins = visible.reduce(CGFloat(0)) { total, box in
            let layout = box.layoutStyle
            let margin = number(layout["marginVertical"]) ?? number(layout["margin"]) ?? 0
            return total + (number(layout["marginTop"]) ?? margin) + (number(layout["marginBottom"]) ?? margin)
        }
        let crossMargins = zip(visible, sizes).map { box, size -> CGFloat in
            let layout = box.layoutStyle
            let margin = number(layout["marginHorizontal"]) ?? number(layout["margin"]) ?? 0
            return size.width + (number(layout["marginLeft"]) ?? margin) + (number(layout["marginRight"]) ?? margin)
        }
        return CGSize(width: (crossMargins.max() ?? 0) + horizontalPadding, height: sizes.reduce(0) { $0 + $1.height } + verticalPadding + gaps + margins)
    }
}

func number(_ value: Any?) -> CGFloat? { (value as? NSNumber).map { CGFloat(truncating: $0) } }
func dimension(_ value: Any?, base: CGFloat) -> CGFloat? {
    if let number = number(value), number.isFinite { return max(0, number) }
    if let text = value as? String, text.hasSuffix("%"), let percent = Double(text.dropLast()), percent.isFinite { return max(0, base * CGFloat(percent) / 100) }
    return nil
}
func nativeText(_ node: [String: Any]) -> String {
    (node["children"] as? [Any] ?? []).map { child -> String in
        if let text = child as? String { return text }
        if let node = child as? [String: Any] { return nativeText(node) }
        return ""
    }.joined()
}

/// Each node owns an AppKit control. IDs survive STX mutations, so editing,
/// selection, and scroll position survive updates instead of being recreated.
final class CraftMacTextView: NSTextView {
    var placeholder = ""
    /// An inline completion drawn after the caret in the placeholder color
    /// (`ghostText`); Tab accepts it (`onAcceptCompletion`), any edit drops it.
    var ghost = ""
    /// `markdown` prop: the text stays plain markdown, drawn the way Notes would show it (headings, bold, italic,
    /// code, quotes, checklists with the done ones struck through), restyled after every edit.
    var markdown = false
    var lastStyled = ""
    /// The font the markdown styling is built from. NSTextView's own `font` answers the font at the caret, which a heading changes.
    var baseFont: NSFont?
    override func didChangeText() { ghost = ""; super.didChangeText(); restyle() }
    func restyle() {
        guard markdown, let storage = textStorage else { return }
        let base = baseFont ?? font ?? NSFont.systemFont(ofSize: 13)
        let text = string as NSString
        let full = NSRange(location: 0, length: text.length)
        // The dynamic system font does not answer NSFontManager's trait conversion, so weight and slant are built directly.
        enum Trait { case bold, italic }
        func traits(_ font: NSFont, _ trait: Trait) -> NSFont {
            switch trait {
            case .bold:
                let heavier = NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
                return font.fontDescriptor.symbolicTraits.contains(.italic) ? (NSFont(descriptor: heavier.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) ?? heavier) : heavier
            case .italic:
                return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits([.italic]), size: font.pointSize) ?? font
            }
        }
        let dim: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.tertiaryLabelColor]
        storage.beginEditing()
        storage.setAttributes([.font: base, .foregroundColor: NSColor.labelColor], range: full)
        text.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let line = text.substring(with: range)
            if let hashes = line.prefix(while: { $0 == "#" }) as Substring?, (1...3).contains(hashes.count), line.dropFirst(hashes.count).hasPrefix(" ") {
                let size: CGFloat = [1: base.pointSize + 11, 2: base.pointSize + 6, 3: base.pointSize + 3][hashes.count]!
                storage.addAttribute(.font, value: traits(NSFont.systemFont(ofSize: size), .bold), range: range)
                storage.addAttributes(dim, range: NSRange(location: range.location, length: hashes.count + 1))
            }
            else if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                storage.addAttributes(dim, range: NSRange(location: range.location, length: 6))
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor], range: NSRange(location: range.location + 6, length: range.length - 6))
            }
            else if line.hasPrefix("- [ ] ") { storage.addAttributes([.foregroundColor: NSColor.controlAccentColor], range: NSRange(location: range.location, length: 5)) }
            else if line.hasPrefix("> ") {
                storage.addAttributes(dim, range: NSRange(location: range.location, length: 2))
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: range.location + 2, length: range.length - 2))
            }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor], range: NSRange(location: range.location, length: 2)) }
        }
        func inline(_ pattern: String, _ apply: (NSRange, NSRange) -> Void) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
            for match in expression.matches(in: string, range: full) where match.numberOfRanges > 1 { apply(match.range, match.range(at: 1)) }
        }
        inline("\\*\\*(?!\\s)(.+?)(?<!\\s)\\*\\*") { whole, inner in
            storage.enumerateAttribute(.font, in: inner) { value, range, _ in storage.addAttribute(.font, value: traits(value as? NSFont ?? base, .bold), range: range) }
            storage.addAttributes(dim, range: NSRange(location: whole.location, length: 2)); storage.addAttributes(dim, range: NSRange(location: whole.location + whole.length - 2, length: 2))
        }
        inline("(?<![\\*\\w])\\*(?![\\*\\s])(.+?)(?<![\\*\\s])\\*(?![\\*\\w])") { whole, inner in
            storage.enumerateAttribute(.font, in: inner) { value, range, _ in storage.addAttribute(.font, value: traits(value as? NSFont ?? base, .italic), range: range) }
            storage.addAttributes(dim, range: NSRange(location: whole.location, length: 1)); storage.addAttributes(dim, range: NSRange(location: whole.location + whole.length - 1, length: 1))
        }
        inline("`([^`\\n]+)`") { whole, inner in
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular), .backgroundColor: NSColor.quaternaryLabelColor], range: inner)
            storage.addAttributes(dim, range: NSRange(location: whole.location, length: 1)); storage.addAttributes(dim, range: NSRange(location: whole.location + whole.length - 1, length: 1))
        }
        storage.endEditing()
        typingAttributes = [.font: base, .foregroundColor: NSColor.labelColor]
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if !ghost.isEmpty, selectedRange().length == 0, let window {
            let screen = firstRect(forCharacterRange: NSRange(location: selectedRange().location, length: 0), actualRange: nil)
            let point = convert(window.convertFromScreen(screen), from: nil)
            let left = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5)
            (ghost as NSString).draw(with: CGRect(x: point.minX, y: point.minY, width: max(20, bounds.width - point.minX - left), height: 100_000), options: [.usesLineFragmentOrigin],
                attributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor])
        }
        if string.isEmpty && !placeholder.isEmpty {
            (placeholder as NSString).draw(at: CGPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height),
                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor])
        }
    }
}

final class CraftMacBox: NSView, NSTextFieldDelegate, NSTextViewDelegate, NSDraggingSource {
    let id: String
    let kind: String
    weak var renderer: CraftMacRenderer?
    var props: [String: Any] = [:], style: [String: Any] = [:], events: [String: String] = [:]
    var flow: CraftMacFlow?
    var control: NSView?
    var imageTask: URLSessionDataTask?
    var imageSource = ""
    var scrollKey = ""
    var modal: NSPanel?
    var material: NSVisualEffectView?
    var edgeBorders: [String: CALayer] = [:]
    var lastSelection = ""
    /// The pointer is over the box, or pressing it: `hoverStyle` and `pressStyle` apply on top of `style`.
    var hovering = false, pressing = false
    var hoverArea: NSTrackingArea?
    var gradient: CAGradientLayer?
    var configuredOnce = false
    /// Drag and drop: where a press started (a drag begins 3pt away), and the last position reported to a drop target.
    static let dragType = NSPasteboard.PasteboardType("org.craft-native.drag")
    var downPoint: NSPoint?
    var lastDropPosition = ""
    var acceptsDrops = false
    var wantedFocus = false
    var componentRoot: CraftMacBox? { props["data-stx-component-wrapper"] != nil && flow?.boxes.count == 1 && flow?.boxes.first?.kind != "Modal" ? flow?.boxes.first : nil }
    var layoutStyle: [String: Any] {
        guard let child = componentRoot else { return style }
        let keys = ["width", "height", "minWidth", "minHeight", "maxWidth", "maxHeight", "flex", "flexGrow", "flexShrink", "flexBasis", "alignSelf", "position", "left", "right", "top", "bottom", "margin", "marginTop", "marginRight", "marginBottom", "marginLeft", "marginHorizontal", "marginVertical"]
        var result = style
        for key in keys where result[key] == nil { result[key] = child.layoutStyle[key] }
        return result
    }
    override var isFlipped: Bool { true }

    init(id: String, kind: String, renderer: CraftMacRenderer) {
        self.id = id; self.kind = kind; self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        setAccessibilityElement(false)
        switch kind {
        case "Text":
            let text = NSTextField(wrappingLabelWithString: "")
            text.isSelectable = true; text.maximumNumberOfLines = 0
            control = text
        case "Button", "Link":
            let button = NSButton(title: "", target: self, action: #selector(pressed))
            button.bezelStyle = .rounded; control = button
        case "TextInput":
            let input = NSTextField(); input.delegate = self; control = input
        case "Picker":
            let picker = NSPopUpButton(frame: .zero, pullsDown: false)
            picker.target = self; picker.action = #selector(changed); control = picker
        case "Switch", "Checkbox":
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(changed)); control = button
        case "Icon", "Image":
            let image = NSImageView(); image.imageScaling = .scaleProportionallyUpOrDown; control = image
        case "Video": control = AVPlayerView()
        case "ActivityIndicator": let indicator = NSProgressIndicator(); indicator.style = .spinning; indicator.startAnimation(nil); control = indicator
        case "ScrollView", "FlatList", "SectionList":
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
            let content = CraftMacFlow(); content.style = ["flexDirection": "column"]
            scroll.documentView = content; flow = content; control = scroll
        case "Sidebar": control = CraftMacSidebar(box: self)
        #if CRAFT_WEBKIT
        case "WebView": control = CraftMacWebHost(box: self)
        #endif
        case "View", "SafeAreaView", "Pressable", "TouchableOpacity", "TouchableHighlight", "KeyboardAvoidingView", "Modal", "SplitView":
            let container = CraftMacFlow(); flow = container; control = container
        default:
            let text = NSTextField(labelWithString: "Unsupported native control: \(kind)"); control = text
            renderer.runtime.errors.append("Unsupported native control: \(kind)")
        }
        if let control { control.clipsToBounds = true; addSubview(control) }
    }
    required init?(coder: NSCoder) { fatalError("Native controls are created from STX") }

    func configure(_ node: [String: Any]) {
        props = node["props"] as? [String: Any] ?? [:]
        flow?.componentScope = props["data-stx-component-wrapper"] != nil
        style = node["style"] as? [String: Any] ?? [:]
        events = node["events"] as? [String: String] ?? [:]
        isHidden = style["display"] as? String == "none" || props["hidden"] as? Bool == true
        layer?.cornerRadius = number(style["borderRadius"]) ?? 0
        layer?.borderWidth = number(style["borderWidth"]) ?? 0
        // AppKit views may draw their entire visibleRect, which can extend
        // through adjacent panes on newer macOS releases. Native controls
        // stay inside their authored boxes unless overflow is explicit.
        clipsToBounds = style["overflow"] as? String != "visible"
        if let container = control as? CraftMacFlow { container.clipsToBounds = clipsToBounds }
        layer?.masksToBounds = clipsToBounds || (number(style["borderRadius"]) ?? 0) > 0
        // `shadow-*` classes: a box with a shadow cannot clip its own layer, or the shadow is cut off.
        if let opacity = number(style["shadowOpacity"]), opacity > 0 {
            let offset = style["shadowOffset"] as? [String: Any] ?? [:]
            // The shadow needs the box's own layer unclipped, so a rounded box that also clips
            // (`rounded-xl overflow-hidden shadow-lg`, a card holding a web page) clips one level in.
            let clipsContent = style["overflow"] as? String != "visible" && (number(style["borderRadius"]) ?? 0) > 0
            layer?.masksToBounds = false; clipsToBounds = false
            if let inner = control, clipsContent {
                inner.wantsLayer = true; inner.layer?.masksToBounds = true; inner.layer?.cornerCurve = .continuous
                inner.layer?.cornerRadius = number(style["borderRadius"]) ?? 0
            }
            layer?.shadowOpacity = Float(opacity); layer?.shadowRadius = number(style["shadowRadius"]) ?? 3
            layer?.shadowOffset = CGSize(width: number(offset["width"]) ?? 0, height: -(number(offset["height"]) ?? 1))
            layer?.shadowColor = CraftMacColor.parse(style["shadowColor"], fallback: .black).cgColor
        } else { layer?.shadowOpacity = 0; layer?.shadowPath = nil; control?.layer?.cornerRadius = 0 }
        layer?.cornerCurve = .continuous
        for edge in ["Top", "Right", "Bottom", "Left"] {
            let border = edgeBorders[edge] ?? CALayer()
            if edgeBorders[edge] == nil { edgeBorders[edge] = border; layer?.addSublayer(border) }
            border.backgroundColor = CraftMacColor.parse(style["borderColor"], fallback: .separatorColor).cgColor
            border.isHidden = (number(style["border\(edge)Width"]) ?? 0) <= 0
        }
        if let name = props["material"] as? String {
            if material == nil { let effect = NSVisualEffectView(); effect.state = .followsWindowActiveState; addSubview(effect, positioned: .below, relativeTo: control); material = effect }
            // Chrome shows the desktop through it; a floating surface (a command bar, a popover) blurs the window's own content.
            let materials: [String: NSVisualEffectView.Material] = ["sidebar": .sidebar, "header": .headerView, "window": .windowBackground, "titlebar": .titlebar,
                "popover": .popover, "menu": .menu, "hud": .hudWindow, "sheet": .sheet, "underPage": .underPageBackground]
            material?.material = materials[name] ?? .headerView
            material?.blendingMode = ["popover", "menu", "hud", "sheet"].contains(name) ? .withinWindow : .behindWindow
            if name == "hud" { material?.state = .active }
        } else { material?.removeFromSuperview(); material = nil }
        let identifier = props["testID"] as? String ?? props["testId"] as? String ?? props["accessibilityIdentifier"] as? String ?? id
        control?.setAccessibilityIdentifier(identifier)
        let label = props["accessibilityLabel"] as? String ?? props["aria-label"] as? String ?? props["title"] as? String
        if let label { control?.setAccessibilityLabel(label) }
        control?.toolTip = props["title"] as? String
        let fontSize = number(style["fontSize"]) ?? 13
        let weightValue = number(style["fontWeight"]) ?? CGFloat(Double(style["fontWeight"] as? String ?? "") ?? 0)
        let weight: NSFont.Weight = (style["fontWeight"] as? String == "bold" || weightValue >= 600) ? .semibold : .regular
        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        if let text = control as? NSTextField, kind == "Text" {
            text.stringValue = props["text"] as? String ?? nativeText(node)
            text.font = font; text.textColor = CraftMacColor.parse(style["color"])
            if let line = style["textDecorationLine"] as? String, line == "line-through" || line == "underline" {
                let attributed = NSMutableAttributedString(string: text.stringValue, attributes: [.font: font, .foregroundColor: CraftMacColor.parse(style["color"]), line == "underline" ? .underlineStyle : .strikethroughStyle: NSUnderlineStyle.single.rawValue])
                text.attributedStringValue = attributed
            }
            text.alignment = style["textAlign"] as? String == "center" ? .center : style["textAlign"] as? String == "right" ? .right : .left
            text.maximumNumberOfLines = (props["numberOfLines"] as? NSNumber)?.intValue ?? 0
            text.lineBreakMode = text.maximumNumberOfLines == 1 ? .byTruncatingTail : .byWordWrapping
        }
        if let button = control as? NSButton {
            let title = props["title"] as? String ?? nativeText(node)
            button.title = props["iconOnly"] as? Bool == true ? "" : title
            button.setAccessibilityLabel(label ?? title)
            button.font = font
            button.alignment = style["textAlign"] as? String == "left" ? .left : style["textAlign"] as? String == "right" ? .right : .center
            button.isEnabled = props["disabled"] as? Bool != true
            if kind == "Switch" || kind == "Checkbox" { button.state = (props["value"] as? Bool ?? props["checked"] as? Bool ?? false) ? .on : .off }
            button.bezelStyle = props["variant"] as? String == "toolbar" ? .texturedRounded : .rounded
            button.isBordered = !["toolbar", "ghost"].contains(props["variant"] as? String ?? "")
            button.contentTintColor = CraftMacColor.parse(style["color"], fallback: .controlAccentColor)
            if let symbol = props["symbol"] as? String { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.title); button.imagePosition = button.title.isEmpty ? .imageOnly : .imageLeading }
            if button.image != nil { button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: number(style["fontSize"]) ?? 16, weight: .regular) }
            if props["variant"] as? String == "primary" { button.bezelColor = .controlAccentColor }
            if props["variant"] as? String == "danger" { button.contentTintColor = .systemRed }
        }
        if kind == "TextInput" {
            configureInput(font: font)
            // `autoFocus` takes the keyboard when it turns on (a command bar opening); `selectTextOnFocus` then selects it all.
            let focus = props["autoFocus"] as? Bool == true
            if focus && !wantedFocus {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window, let target = (self.control as? NSScrollView)?.documentView ?? self.control else { return }
                    window.makeFirstResponder(target)
                    if self.props["selectTextOnFocus"] as? Bool == true { (target as? NSTextField)?.currentEditor()?.selectAll(nil) ?? (target as? NSTextView)?.selectAll(nil) }
                }
            }
            wantedFocus = focus
        }
        if let picker = control as? NSPopUpButton {
            let rawOptions = props["options"] as? [[String: Any]] ?? (node["children"] as? [[String: Any]] ?? []).map { child in
                ["value": (child["props"] as? [String: Any])?["value"] ?? nativeText(child), "label": nativeText(child)]
            }
            let old = picker.itemArray.map { $0.representedObject as? String ?? "" }
            let new = rawOptions.map { String(describing: $0["value"] ?? "") }
            if old != new { picker.removeAllItems(); for option in rawOptions { picker.addItem(withTitle: option["label"] as? String ?? ""); picker.lastItem?.representedObject = String(describing: option["value"] ?? "") } }
            if let value = props["value"] ?? props["selectedValue"], let index = new.firstIndex(of: String(describing: value)) { picker.selectItem(at: index) }
            picker.isEnabled = props["disabled"] as? Bool != true
        }
        if let image = control as? NSImageView {
            if kind == "Icon" { image.image = NSImage(systemSymbolName: props["symbol"] as? String ?? props["name"] as? String ?? "questionmark", accessibilityDescription: label); image.contentTintColor = CraftMacColor.parse(style["color"]) }
            else { configureImage(image) }
        }
        if let video = control as? AVPlayerView, let source = (props["source"] as? String ?? props["src"] as? String), source != imageSource {
            imageSource = source
            if let url = renderer?.runtime.network.request(["url": source])?.url {
                video.player = AVPlayer(url: url); video.controlsStyle = .inline
                if props["autoplay"] as? Bool == true { video.player?.play() }
            }
        }
        if let sidebar = control as? CraftMacSidebar { sidebar.configure(props) }
        let dropTarget = events["onDrop"] != nil || events["onDragOver"] != nil
        if dropTarget != acceptsDrops {
            acceptsDrops = dropTarget
            if dropTarget { registerForDraggedTypes([Self.dragType, .URL, .fileURL]) } else { unregisterDraggedTypes() }
        }
        updateTrackingAreas()
        applyAppearance(animated: configuredOnce)
        configuredOnce = true
        #if CRAFT_WEBKIT
        if let web = control as? CraftMacWebHost { web.show(props["tab"] as? String) }
        #endif
        flow?.style = style
        needsLayout = true
    }

    private func configureInput(font: NSFont) {
        let multiline = props["multiline"] as? Bool == true
        if multiline, !(control is NSScrollView) {
            control?.removeFromSuperview()
            let scroll = NSScrollView(); scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor; scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let text = CraftMacTextView(); text.isRichText = false; text.delegate = self; text.font = font; text.isVerticallyResizable = true; text.isHorizontallyResizable = false
            text.textContainerInset = CGSize(width: 5, height: 6)
            text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
            scroll.documentView = text; control = scroll; addSubview(scroll)
        } else if !multiline, let current = control as? NSTextField {
            let search = props["type"] as? String == "search"
            let secure = props["secureTextEntry"] as? Bool == true || props["type"] as? String == "password"
            if (search && !(current is NSSearchField)) || (secure && !(current is NSSecureTextField)) {
                current.removeFromSuperview()
                let field: NSTextField = search ? NSSearchField() : NSSecureTextField()
                field.delegate = self; control = field; addSubview(field)
            }
        }
        let value = props["value"] as? String ?? ""
        if let text = (control as? NSScrollView)?.documentView as? NSTextView {
            if let scroll = control as? NSScrollView {
                let bordered = props["bordered"] as? Bool ?? true
                scroll.borderType = bordered ? .bezelBorder : .noBorder
                scroll.drawsBackground = bordered
                text.drawsBackground = bordered
            }
            if text.string != value { text.string = value }
            // `selection` ({ start, end }) moves the caret, e.g. after a formatting action changed the text.
            if let want = props["selection"] as? [String: Any], let start = number(want["start"]), let end = number(want["end"]) {
                let length = (text.string as NSString).length
                let range = NSRange(location: min(Int(start), length), length: max(0, min(Int(end), length) - min(Int(start), length)))
                if text.selectedRange() != range { lastSelection = "\(range.location):\(range.length)"; text.setSelectedRange(range) }
            }
            text.isEditable = props["disabled"] as? Bool != true
            // Assigning `font` restyles the whole text, so a markdown editor only does it when the base font changes.
            if let editor = text as? CraftMacTextView, props["markdown"] as? Bool == true {
                if editor.baseFont != font { editor.baseFont = font; editor.font = font; editor.lastStyled = "\u{0}" }
            } else { (text as? CraftMacTextView)?.baseFont = nil; text.font = font }
            if let editor = text as? CraftMacTextView { let markdown = props["markdown"] as? Bool == true
                if editor.markdown != markdown || (markdown && editor.string != editor.lastStyled) { editor.markdown = markdown; editor.restyle(); editor.lastStyled = editor.string }
                editor.placeholder = props["placeholder"] as? String ?? ""; editor.ghost = props["ghostText"] as? String ?? ""; editor.needsDisplay = true }
            text.setAccessibilityIdentifier(props["testID"] as? String ?? props["testId"] as? String ?? id)
            text.setAccessibilityLabel(props["placeholder"] as? String ?? "Message")
        } else if let field = control as? NSTextField {
            if field.stringValue != value { field.stringValue = value }
            field.placeholderString = props["placeholder"] as? String
            field.font = font; field.isEnabled = props["disabled"] as? Bool != true
            if let bordered = props["bordered"] as? Bool { field.isBordered = bordered; field.drawsBackground = bordered }
            field.setAccessibilityIdentifier(props["testID"] as? String ?? props["testId"] as? String ?? id)
        }
    }

    private func configureImage(_ image: NSImageView) {
        let source = props["source"] as? String ?? props["src"] as? String ?? (props["source"] as? [String: Any])?["uri"] as? String ?? ""
        guard source != imageSource else { return }
        imageSource = source; imageTask?.cancel(); image.image = nil
        if source.hasPrefix("data:"), let encoded = source.split(separator: ",", maxSplits: 1).last, let data = Data(base64Encoded: String(encoded)) { image.image = NSImage(data: data); return }
        guard !source.isEmpty, let request = renderer?.runtime.network.request(["url": source]), let session = renderer?.runtime.network.session else { return }
        imageTask = session.dataTask(with: request) { [weak self, weak image] data, _, _ in
            DispatchQueue.main.async {
                guard let self, self.imageSource == source else { return }
                image?.image = data.flatMap(NSImage.init(data:))
                self.fire(image?.image == nil ? "onError" : "onLoad")
            }
        }; imageTask?.resume()
    }

    /// `style` with the pointer's layers on top: `hoverStyle` while hovered, `pressStyle` while pressed.
    var appearanceStyle: [String: Any] {
        var look = style
        if hovering, let hover = style["hoverStyle"] as? [String: Any] { hover.forEach { look[$0.key] = $0.value } }
        if pressing, let press = style["pressStyle"] as? [String: Any] { press.forEach { look[$0.key] = $0.value } }
        return look
    }

    /// Background, border, opacity, gradient and text colour, eased over `transitionDuration` (ms) when it changes.
    func applyAppearance(animated: Bool) {
        let look = appearanceStyle
        let duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? (number(style["transitionDuration"]) ?? 0) / 1000 : 0
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            ease("backgroundColor", to: CraftMacColor.parse(look["backgroundColor"], fallback: .clear).cgColor, duration)
            ease("borderColor", to: CraftMacColor.parse(look["borderColor"], fallback: .separatorColor).cgColor, duration)
            applyGradient(look, duration)
            if kind == "Text", let text = control as? NSTextField, style["hoverStyle"] != nil || style["pressStyle"] != nil {
                text.textColor = CraftMacColor.parse(look["color"])
            }
        }
        let opacity = number(look["opacity"]) ?? 1
        if duration > 0, abs(alphaValue - opacity) > 0.001 {
            NSAnimationContext.runAnimationGroup { context in context.duration = duration; animator().alphaValue = opacity }
        } else { alphaValue = opacity }
    }

    private func ease(_ key: String, to value: CGColor, _ duration: CFTimeInterval) {
        guard let layer else { return }
        if duration > 0, let from = (layer.presentation() ?? layer).value(forKey: key) {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from; animation.toValue = value; animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: key)
        }
        layer.setValue(value, forKey: key)
    }

    /// `bg-gradient-to-*` with `from-`, `via-` and `to-` colours, under the box's content as on the phone hosts.
    private func applyGradient(_ look: [String: Any], _ duration: CFTimeInterval) {
        guard let direction = look["gradientDirection"] as? String, look["gradientFrom"] != nil, look["gradientTo"] != nil else {
            gradient?.removeFromSuperlayer(); gradient = nil; return
        }
        let layer = gradient ?? CAGradientLayer()
        if gradient == nil { self.layer?.insertSublayer(layer, at: 0); gradient = layer; layer.frame = bounds }
        let colors = [look["gradientFrom"], look["gradientVia"], look["gradientTo"]].compactMap { $0 }.map { CraftMacColor.parse($0, fallback: .clear).cgColor }
        if duration > 0, let from = (layer.presentation() ?? layer).colors {
            let animation = CABasicAnimation(keyPath: "colors")
            animation.fromValue = from; animation.toValue = colors; animation.duration = duration
            layer.add(animation, forKey: "colors")
        }
        layer.colors = colors
        // The box is flipped (y grows downward), as UIKit is, so the phone hosts' points carry over.
        let points: (CGPoint, CGPoint)
        switch direction {
        case "to-t": points = (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0))
        case "to-tr": points = (CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0))
        case "to-r": points = (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))
        case "to-br": points = (CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1))
        case "to-bl": points = (CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1))
        case "to-l": points = (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))
        case "to-tl": points = (CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 0))
        default: points = (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1))
        }
        layer.startPoint = points.0; layer.endPoint = points.1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let wanted = style["hoverStyle"] is [String: Any] || style["pressStyle"] is [String: Any] || events["onHoverChange"] != nil
        if !wanted, let area = hoverArea { removeTrackingArea(area); hoverArea = nil; hovering = false; pressing = false }
        if wanted, hoverArea == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
            addTrackingArea(area); hoverArea = area
        }
    }
    override func mouseEntered(with event: NSEvent) {
        guard hoverArea != nil, !hovering else { return }
        hovering = true; applyAppearance(animated: true)
        fire("onHoverChange", ["hovered": true])
    }
    override func mouseExited(with event: NSEvent) {
        guard hovering || pressing else { return }
        let was = hovering
        hovering = false; pressing = false; applyAppearance(animated: true)
        if was { fire("onHoverChange", ["hovered": false]) }
    }

    // MARK: drag and drop
    // A `draggable` box starts a drag 3pt from where it was pressed, carrying `dragData` (and `dragURL`
    // for other apps). A box with `onDrop`/`onDragOver` hears drags pass over it as `before`/`after`
    // (or `inside`, with `dropInside`), with the data, links or files they carry.

    override func mouseDragged(with event: NSEvent) {
        guard props["draggable"] as? Bool == true, let start = downPoint,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 3 else { super.mouseDragged(with: event); return }
        downPoint = nil
        if pressing { pressing = false; applyAppearance(animated: false) }
        let item = NSPasteboardItem()
        let data = props["dragData"] ?? NSNull()
        if let encoded = try? JSONSerialization.data(withJSONObject: ["data": data], options: [.fragmentsAllowed]) { item.setData(encoded, forType: Self.dragType) }
        if let url = props["dragURL"] as? String, !url.isEmpty { item.setString(url, forType: .URL); item.setString(url, forType: .string) }
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [dragging], event: event, source: self)
        fire("onDragStart", ["data": data])
    }

    private func snapshot() -> NSImage {
        guard bounds.width > 0, bounds.height > 0, let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage() }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size); image.addRepresentation(rep)
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : .copy
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        fire("onDragEnd", ["dropped": operation != []])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragMoved(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragMoved(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { lastDropPosition = ""; fire("onDragLeave") }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let position = dropPosition(at: convert(sender.draggingLocation, from: nil))
        lastDropPosition = ""
        fire("onDrop", dropPayload(sender.draggingPasteboard, position: position))
        return true
    }

    /// Reported once per change of position, not on every pointer move.
    private func dragMoved(_ sender: NSDraggingInfo) -> NSDragOperation {
        let position = dropPosition(at: convert(sender.draggingLocation, from: nil))
        if position != lastDropPosition { lastDropPosition = position; fire("onDragOver", dropPayload(sender.draggingPasteboard, position: position)) }
        return sender.draggingPasteboard.types?.contains(Self.dragType) == true ? .move : .copy
    }

    /// The box is flipped, so y runs down: the top half is `before`; with `dropInside`, the middle half is `inside`.
    func dropPosition(at point: NSPoint) -> String {
        let fraction = bounds.height > 0 ? point.y / bounds.height : 0.5
        if props["dropInside"] as? Bool == true { return fraction < 0.25 ? "before" : fraction > 0.75 ? "after" : "inside" }
        return fraction < 0.5 ? "before" : "after"
    }

    func dropPayload(_ board: NSPasteboard, position: String) -> [String: Any] {
        var payload: [String: Any] = ["position": position]
        if let raw = board.data(forType: Self.dragType), let object = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) as? [String: Any] {
            payload["data"] = object["data"] ?? NSNull(); payload["internal"] = true
        }
        let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        let files = urls.filter(\.isFileURL).map(\.path), links = urls.filter { !$0.isFileURL }.map(\.absoluteString)
        if !files.isEmpty { payload["files"] = files }
        if !links.isEmpty { payload["urls"] = links }
        return payload
    }
    override func mouseUp(with event: NSEvent) {
        if pressing { pressing = false; applyAppearance(animated: true) }
        super.mouseUp(with: event)
    }

    var textPadding: NSEdgeInsets {
        let all = number(style["padding"]) ?? 0
        let horizontal = number(style["paddingHorizontal"]) ?? all
        let vertical = number(style["paddingVertical"]) ?? all
        return NSEdgeInsets(top: number(style["paddingTop"]) ?? vertical, left: number(style["paddingLeft"]) ?? horizontal, bottom: number(style["paddingBottom"]) ?? vertical, right: number(style["paddingRight"]) ?? horizontal)
    }
    func measure(width: CGFloat, stretch: Bool = false) -> CGSize {
        if isHidden { return .zero }
        if let child = componentRoot { return child.measure(width: width, stretch: stretch) }
        let specifiedWidth = dimension(style["width"], base: width)
        let limit = min(specifiedWidth ?? width, dimension(style["maxWidth"], base: width) ?? width)
        var size = CGSize(width: limit, height: 0)
        if let text = control as? NSTextField, kind == "Text" {
            let rect = (text.stringValue as NSString).boundingRect(with: CGSize(width: max(1, limit - 6 - textPadding.left - textPadding.right), height: 1_000_000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: text.font ?? NSFont.systemFont(ofSize: 13)])
            size = CGSize(width: min(limit, ceil(rect.width) + 9 + textPadding.left + textPadding.right), height: max(18, ceil(rect.height) + 2))
            if text.maximumNumberOfLines > 0 { size.height = min(size.height, ceil((text.font?.ascender ?? 13) - (text.font?.descender ?? -3) + (text.font?.leading ?? 0)) * CGFloat(text.maximumNumberOfLines) + 2) }
            if text.maximumNumberOfLines == 1 { size.height = max(18, (text.font?.pointSize ?? 13) + 5) }
            size.height += textPadding.top + textPadding.bottom
        } else if kind == "ScrollView" || kind == "FlatList" || kind == "Sidebar" { size = CGSize(width: limit, height: 100) }
        else if kind == "WebView" { size = CGSize(width: limit, height: 300) }
        else if kind == "Icon" { size = CGSize(width: 18, height: 18) }
        else if kind == "Image" || kind == "Video" { size = CGSize(width: limit, height: 160) }
        else if kind == "TextInput" { size = CGSize(width: limit, height: props["multiline"] as? Bool == true ? 48 : 28) }
        else if let control = control as? NSControl { size = control.intrinsicContentSize; size.width = max(24, size.width); size.height = max(26, size.height) }
        else if let flow { size = flow.fitting(width: limit, stretchChildren: false) }
        size.width = specifiedWidth ?? (flow != nil && stretch ? limit : min(limit, size.width))
        if let maximum = dimension(style["maxWidth"], base: width) { size.width = min(size.width, maximum) }
        // A naturally sized column can be narrower than its measurement limit.
        // Measure its wrapped children again at the width it will actually get.
        if let flow, !(control is NSScrollView), style["flexDirection"] as? String != "row" {
            size.height = flow.fitting(width: size.width).height
        }
        size.height = dimension(style["height"], base: 1000) ?? size.height
        size.width = max(size.width, dimension(style["minWidth"], base: width) ?? 0)
        size.height = max(size.height, dimension(style["minHeight"], base: 1000) ?? 0)
        if let maxHeight = dimension(style["maxHeight"], base: 1000) { size.height = min(size.height, maxHeight) }
        return size
    }
    override func layout() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        super.layout()
        layer?.cornerRadius = min(number(style["borderRadius"]) ?? 0, min(bounds.width, bounds.height) / 2)
        if kind == "Text" {
            let padding = textPadding
            control?.frame = CGRect(x: padding.left, y: padding.top, width: max(0, bounds.width - padding.left - padding.right), height: max(0, bounds.height - padding.top - padding.bottom))
        } else { control?.frame = bounds }
        material?.frame = bounds
        // A visual effect view ignores its layer's corner radius; a stretchable mask rounds it (as the tray popover does).
        if let material {
            let radius = layer?.cornerRadius ?? 0
            if radius > 0, material.maskImage?.capInsets.top != radius {
                let edge = radius * 2 + 1
                let mask = NSImage(size: CGSize(width: edge, height: edge), flipped: false) { rect in NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill(); return true }
                mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius); mask.resizingMode = .stretch
                material.maskImage = mask
            } else if radius == 0 { material.maskImage = nil }
        }
        gradient?.frame = bounds
        gradient?.cornerRadius = layer?.cornerRadius ?? 0
        // An explicit path spares Core Animation an offscreen pass to find the shadow's shape, every frame.
        if let layer, layer.shadowOpacity > 0 {
            layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: layer.cornerRadius, cornerHeight: layer.cornerRadius, transform: nil)
            if let inner = control?.layer, inner.masksToBounds { inner.cornerRadius = layer.cornerRadius }
        }
        for (edge, border) in edgeBorders {
            let thickness = number(style["border\(edge)Width"]) ?? 0
            switch edge {
            case "Top": border.frame = CGRect(x: 0, y: 0, width: bounds.width, height: thickness)
            case "Bottom": border.frame = CGRect(x: 0, y: bounds.height - thickness, width: bounds.width, height: thickness)
            case "Left": border.frame = CGRect(x: 0, y: 0, width: thickness, height: bounds.height)
            default: border.frame = CGRect(x: bounds.width - thickness, y: 0, width: thickness, height: bounds.height)
            }
        }
        if let child = componentRoot {
            child.frame = bounds; child.layoutSubtreeIfNeeded()
        } else if let scroll = control as? NSScrollView {
            if let flow {
                let width = scroll.contentSize.width
                flow.frame = CGRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, flow.fitting(width: width).height))
                flow.layoutBoxes(in: flow.bounds.size)
            }
            if let text = scroll.documentView as? NSTextView { text.frame.size.width = scroll.contentSize.width; text.textContainer?.containerSize = CGSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude) }
        } else if let flow { flow.layoutBoxes(in: bounds.size) }
    }
    func fire(_ name: String, _ payload: [String: Any] = [:]) { renderer?.runtime.event(events[name], payload: payload) }
    @objc func pressed() { fire("onPress") }
    @objc func changed() {
        let value: Any = (control as? NSPopUpButton)?.selectedItem?.representedObject ?? ((control as? NSButton)?.state == .on)
        fire("onValueChange", ["value": value, "nativeEvent": ["value": value]])
    }
    func controlTextDidChange(_ notification: Notification) { if let field = notification.object as? NSTextField { input(field.stringValue) } }
    func textDidChange(_ notification: Notification) { if let text = notification.object as? NSTextView { input(text.string) } }
    /// The caret and selection, as UTF-16 offsets (JavaScript string indices): `onSelectionChange`.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let text = notification.object as? NSTextView, events["onSelectionChange"] != nil else { return }
        let range = text.selectedRange()
        let key = "\(range.location):\(range.length)"
        guard key != lastSelection else { return }
        lastSelection = key
        fire("onSelectionChange", ["start": range.location, "end": range.location + range.length, "selection": ["start": range.location, "end": range.location + range.length], "nativeEvent": ["selection": ["start": range.location, "end": range.location + range.length]]])
    }
    func input(_ value: String) { fire("onChangeText", ["text": value, "value": value, "nativeEvent": ["text": value, "value": value]]) }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), (textView as? CraftMacTextView)?.ghost.isEmpty ?? true {
            // Escape in an editor is the screen's too (it closes the open to-do), unless a completion is showing.
            renderer?.runtime.send("CRAFT_EVENT", ["event": "craftDesktopCommand", "detail": ["id": "escape"]]); return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)), let editor = textView as? CraftMacTextView, !editor.ghost.isEmpty, events["onAcceptCompletion"] != nil {
            let accepted = editor.ghost; editor.ghost = ""; fire("onAcceptCompletion", ["text": accepted, "value": accepted]); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)), !NSEvent.modifierFlags.contains(.shift), events["onSubmitEditing"] != nil { fire("onSubmitEditing", ["text": textView.string]); return true }
        return false
    }
    /// Single-line fields: Return submits, and leaving the field blurs it, as on the web.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            renderer?.runtime.send("CRAFT_EVENT", ["event": "craftDesktopCommand", "detail": ["id": "escape"]]); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)), events["onSubmitEditing"] != nil { fire("onSubmitEditing", ["text": textView.string, "value": textView.string, "nativeEvent": ["text": textView.string]]); return true }
        // The keys a list driven from a field needs (a command bar, an address bar's suggestions), in the web's names.
        let keys: [Selector: String] = [#selector(NSResponder.moveUp(_:)): "ArrowUp", #selector(NSResponder.moveDown(_:)): "ArrowDown",
            #selector(NSResponder.insertTab(_:)): "Tab", #selector(NSResponder.insertBacktab(_:)): "Tab"]
        if let key = keys[commandSelector], events["onKeyPress"] != nil {
            fire("onKeyPress", ["key": key, "shiftKey": commandSelector == #selector(NSResponder.insertBacktab(_:)), "text": textView.string]); return true
        }
        return false
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        fire("onEndEditing", ["text": field.stringValue, "value": field.stringValue]); fire("onBlur", ["text": field.stringValue, "value": field.stringValue])
    }
    func textDidEndEditing(_ notification: Notification) {
        guard let text = notification.object as? NSTextView else { return }
        fire("onEndEditing", ["text": text.string, "value": text.string]); fire("onBlur", ["text": text.string, "value": text.string])
    }
    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        if style["pressStyle"] is [String: Any] { pressing = true; applyAppearance(animated: false) }
        if events["onPress"] != nil { fire("onPress") } else { super.mouseDown(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) { fire("onLongPress", ["x": event.locationInWindow.x, "y": event.locationInWindow.y]) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        // Rows handle the whole click. Transcript text keeps AppKit selection,
        // while a right click is routed to the STX conversation/message menu.
        if kind == "Pressable", events["onPress"] != nil || (events["onLongPress"] != nil && NSApp.currentEvent?.type == .rightMouseDown) { return self }
        // A draggable row takes the whole press, or its label would start a text selection instead of a drag.
        if props["draggable"] as? Bool == true, NSApp.currentEvent?.type == .leftMouseDown { return self }
        return super.hitTest(point)
    }
}

final class CraftMacSidebarRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
    }
}

final class CraftMacSidebar: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Item { let id: String; let label: String; let icon: String; let badge: String; let color: NSColor; let children: [Item]
        init(_ raw: [String: Any]) { id = raw["id"] as? String ?? ""; label = raw["label"] as? String ?? raw["header"] as? String ?? ""; icon = raw["icon"] as? String ?? ""; badge = raw["badge"].map { $0 is NSNull ? "" : String(describing: $0) } ?? ""; color = CraftMacColor.parse(raw["color"], fallback: .controlAccentColor); children = (raw["items"] as? [[String: Any]] ?? []).map(Item.init) }
    }
    weak var box: CraftMacBox?
    let outline = NSOutlineView()
    var sections: [Item] = []
    var fingerprint = ""
    /// `rowHeight` and `labelFontSize` props: a Things-like sidebar is 24 points tall at 15.
    var rowHeight: CGFloat = 32
    var labelSize: CGFloat = 13
    init(box: CraftMacBox) {
        self.box = box; super.init(frame: .zero)
        hasVerticalScroller = true; drawsBackground = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("label")); outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.headerView = nil; outline.style = .plain; outline.backgroundColor = .clear
        outline.rowSizeStyle = .default; outline.indentationPerLevel = 0
        outline.dataSource = self; outline.delegate = self; outline.autoresizesOutlineColumn = true; documentView = outline
    }
    required init?(coder: NSCoder) { fatalError("Native sidebar is created from STX") }
    func configure(_ props: [String: Any]) {
        let raw = props["sections"] as? [[String: Any]] ?? []
        let data = (try? JSONSerialization.data(withJSONObject: raw, options: .sortedKeys)) ?? Data()
        // Written as attributes (`rowHeight="24"`) they arrive as text.
        func size(_ key: String) -> CGFloat? { number(props[key]) ?? (props[key] as? String).flatMap(Double.init).map { CGFloat($0) } }
        rowHeight = size("rowHeight") ?? 32
        labelSize = size("labelFontSize") ?? 13
        let next = String(decoding: data, as: UTF8.self) + "|\(rowHeight)|\(labelSize)"
        if next != fingerprint { fingerprint = next; sections = raw.map(Item.init); outline.reloadData(); outline.expandItem(nil, expandChildren: true) }
        if let selected = props["selected"] as? String { for index in 0..<outline.numberOfRows { if (outline.item(atRow: index) as? Item)?.id == selected { outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); break } } }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Item)?.children.count ?? sections.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? Item)?.children[index] ?? sections[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! Item).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { !(item as! Item).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as! Item).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        let item = item as! Item
        return item.children.isEmpty ? rowHeight : item.label.isEmpty ? 12 : max(24, rowHeight - 4)
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = CraftMacSidebarRow(); row.isEmphasized = false; return row
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let item = item as! Item
        let cell = NSTableCellView(); let label = NSTextField(labelWithString: item.label)
        label.font = NSFont.systemFont(ofSize: labelSize); label.lineBreakMode = .byTruncatingTail; cell.textField = label; cell.addSubview(label)
        if !item.children.isEmpty { label.font = NSFont.systemFont(ofSize: 11, weight: .semibold); label.textColor = .secondaryLabelColor }
        label.translatesAutoresizingMaskIntoConstraints = false
        let badge = NSTextField(labelWithString: item.badge); badge.font = NSFont.systemFont(ofSize: 11); badge.textColor = .secondaryLabelColor
        badge.translatesAutoresizingMaskIntoConstraints = false; badge.setContentHuggingPriority(.required, for: .horizontal); cell.addSubview(badge)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: item.icon.isEmpty ? 16 : 39), label.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor), badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16), badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        if !item.icon.isEmpty { let image = NSImageView(image: NSImage(systemSymbolName: item.icon, accessibilityDescription: nil) ?? NSImage()); image.contentTintColor = item.color; image.frame = CGRect(x: 16, y: (rowHeight - 16) / 2, width: 16, height: 16); cell.imageView = image; cell.addSubview(image) }
        cell.setAccessibilityIdentifier(item.id); cell.setAccessibilityLabel(item.label)
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let item = outline.item(atRow: outline.selectedRow) as? Item, item.children.isEmpty, item.id != box?.props["selected"] as? String else { return }
        box?.fire("onValueChange", ["value": item.id, "nativeEvent": ["value": item.id]])
    }
    override func layout() { super.layout(); outline.frame.size.width = contentSize.width }
}

final class CraftMacRenderer {
    let runtime: CraftMacRuntime
    let root = CraftMacFlow()
    var boxes: [String: CraftMacBox] = [:]
    weak var window: NSWindow?
    var sheets: [String: NSPanel] = [:]
    init(runtime: CraftMacRuntime) { self.runtime = runtime }
    func render(_ document: [String: Any]) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var retained = Set<String>()
        var scrolls: [(CraftMacBox, CGPoint, Bool)] = []
        for box in boxes.values { if let scroll = box.control as? NSScrollView, box.kind != "Sidebar" {
            let bounds = scroll.contentView.bounds
            let bottom = bounds.maxY >= (scroll.documentView?.bounds.height ?? 0) - 8
            scrolls.append((box, bounds.origin, bottom))
        } }
        func reconcile(_ node: [String: Any]) -> CraftMacBox {
            let id = node["id"] as? String ?? "root", kind = node["type"] as? String ?? "View"
            retained.insert(id)
            let box = boxes[id] ?? CraftMacBox(id: id, kind: kind, renderer: self)
            boxes[id] = box; box.configure(node)
            if let flow = box.flow, kind != "Button" {
                let children = (node["children"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.map(reconcile)
                for child in flow.boxes where !children.contains(where: { $0 === child }) { child.removeFromSuperview() }
                flow.boxes = children
                for child in children where child.superview !== flow && sheets[child.id] == nil { flow.addSubview(child) }
            }
            return box
        }
        let box = reconcile(document)
        for (id, box) in boxes where !retained.contains(id) {
            box.imageTask?.cancel(); box.removeFromSuperview(); boxes.removeValue(forKey: id)
            if let sheet = sheets.removeValue(forKey: id) { window?.endSheet(sheet); sheet.close() }
        }
        root.style = ["flexDirection": "column"]
        root.boxes = [box]; if box.superview !== root { root.addSubview(box) }
        box.frame = root.bounds; box.layoutSubtreeIfNeeded(); root.layoutBoxes(in: root.bounds.size)
        for modal in boxes.values where modal.kind == "Modal" {
            guard let window else { continue }
            if modal.props["visible"] as? Bool == false {
                if let sheet = sheets.removeValue(forKey: modal.id) { window.endSheet(sheet); sheet.close() }
                continue
            }
            if sheets[modal.id] == nil {
                let size = modal.measure(width: 480)
                let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: min(650, max(200, size.height))), styleMask: [.titled], backing: .buffered, defer: false)
                panel.title = modal.props["title"] as? String ?? ""; panel.isReleasedWhenClosed = false
                modal.removeFromSuperview(); panel.contentView = modal; sheets[modal.id] = panel
                window.beginSheet(panel)
            }
            if let panel = sheets[modal.id] {
                // A sheet follows its content: rows loaded after it opened grow it, up to the screen's comfort.
                let wanted = min(650, max(200, modal.measure(width: 480).height))
                if abs(panel.contentRect(forFrameRect: panel.frame).height - wanted) > 1 { panel.setContentSize(CGSize(width: 480, height: wanted)) }
            }
            modal.frame = sheets[modal.id]!.contentView!.bounds; modal.needsLayout = true; modal.layoutSubtreeIfNeeded()
        }
        for (box, origin, bottom) in scrolls {
            guard let scroll = box.control as? NSScrollView, box.kind != "TextInput" else { continue }
            let key = box.props["scrollKey"] as? String ?? ""
            let changed = key != box.scrollKey; box.scrollKey = key
            let maximum = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentSize.height)
            let y = (bottom || changed) && box.props["autoScrollBottom"] as? Bool == true ? maximum : min(maximum, max(0, origin.y))
            scroll.contentView.scroll(to: CGPoint(x: origin.x, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        root.needsLayout = true
    }
}
