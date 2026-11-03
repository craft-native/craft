import AppKit

// The renderer's external network/event boundary. These checks exercise real
// AppKit controls and the real Zig layout ABI without a script engine or data.
final class FixtureNetwork {
    let session = URLSession.shared
    func request(_ options: [String: Any]) -> URLRequest? { nil }
}
final class CraftMacRuntime {
    var errors: [String] = []
    let network = FixtureNetwork()
    func event(_ handler: String?, payload: [String: Any]) {}
    func send(_ type: String, _ payload: [String: Any], correlation: String? = nil) {}
}

@main struct LayoutChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func node(_ id: String, _ type: String = "View", _ style: [String: Any] = [:], _ children: [[String: Any]] = [], props: [String: Any] = [:]) -> [String: Any] {
        ["id": id, "type": type, "style": style, "props": props, "children": children]
    }
    static func main() {
        _ = NSApplication.shared
        let runtime = CraftMacRuntime()
        let renderer = CraftMacRenderer(runtime: runtime)
        renderer.root.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        let scoped = node("scope", "View", [:], [node("fill", "ScrollView", ["flexGrow": 1])], props: ["data-stx-component-wrapper": true])
        renderer.render(node("root", "View", ["flexGrow": 1], [node("header", "View", ["height": 40]), scoped, node("footer", "View", ["height": 30])]))
        require(abs(renderer.boxes["scope"]!.frame.height - 230) < 1, "A component scope lost its root's flex space")
        require(abs(renderer.boxes["fill"]!.frame.height - 230) < 1, "The native control did not fill its component scope")
        renderer.boxes["scope"]!.control!.layout()
        require(abs(renderer.boxes["fill"]!.frame.height - 230) < 1, "A deferred AppKit flow pass shrank the component root")
        require(renderer.boxes["scope"]!.clipsToBounds && renderer.boxes["fill"]!.control!.clipsToBounds, "A native pane can paint into its neighbor")
        let sidebarScope = node("sidebarScope", "View", [:], [node("sidebarRoot", "View", ["width": 120], [node("sidebar", "ScrollView", ["flexGrow": 1]), node("settings", "View", ["height": 30])])], props: ["data-stx-component-wrapper": true])
        renderer.render(node("root", "View", ["flexGrow": 1, "flexDirection": "row"], [sidebarScope]))
        renderer.boxes["sidebarScope"]!.control!.layout()
        require(abs(renderer.boxes["sidebarRoot"]!.frame.height - 300) < 1, "A deferred AppKit pass shrank a stretched component root")
        renderer.render(node("root", "View", ["flexGrow": 1], [node("overlay", "View", ["overflow": "visible"]), node("viewport", "ScrollView", ["overflow": "visible"])]))
        require(!renderer.boxes["overlay"]!.clipsToBounds && !renderer.boxes["overlay"]!.control!.clipsToBounds, "Explicit overflow was clipped by the inner flow")
        require(renderer.boxes["viewport"]!.control!.clipsToBounds, "A scroll viewport stopped clipping its content")

        renderer.render(node("root", "View", ["flexGrow": 1], [node("first", "View", ["height": 100, "flexGrow": 1]), node("second", "View", ["height": 0, "flexGrow": 1])]))
        require(abs(renderer.boxes["first"]!.frame.height - 200) < 1 && abs(renderer.boxes["second"]!.frame.height - 100) < 1, "Explicit flexGrow discarded its auto basis")

        let bubbleScope = node("bubbleScope", "View", [:], [node("bubble", "View", ["height": 32, "marginTop": 8])], props: ["data-stx-component-wrapper": true])
        renderer.render(node("root", "View", ["flexGrow": 1], [node("message", "View", [:], [bubbleScope])]))
        require(renderer.boxes["message"]!.measure(width: 320).height == 40, "A component's outer margin was omitted from its parent's height")

        // Margins on the cross axis offset and narrow a child, in a column and in a row.
        renderer.render(node("root", "View", ["flexGrow": 1], [node("inset", "View", ["height": 20, "marginLeft": 16, "marginRight": 24])]))
        require(renderer.boxes["inset"]!.frame.minX == 16 && abs(renderer.boxes["inset"]!.frame.width - 280) < 1, "Cross-axis margins of a column child were ignored")
        renderer.render(node("root", "View", ["flexGrow": 1, "flexDirection": "row"], [node("rowInset", "View", ["width": 50, "marginTop": 10, "marginBottom": 30])]))
        require(renderer.boxes["rowInset"]!.frame.minY == 10 && abs(renderer.boxes["rowInset"]!.frame.height - 260) < 1, "Cross-axis margins of a row child were ignored")

        // A shrink-wrapped text is measured wide enough that its last word does not wrap.
        let sized = node("title", "Text", ["fontSize": 22, "fontWeight": "600"], props: ["text": "Sign in to Library"])
        renderer.render(node("root", "View", ["flexGrow": 1, "alignItems": "center"], [sized]))
        require(renderer.boxes["title"]!.frame.height < 40, "A shrink-wrapped title wrapped its last word")

        // A wrapped paragraph gets the height its text field needs to draw every line, insets included:
        // a frame one inset short makes AppKit drop the last line rather than draw part of it.
        for size in [13, 15, 17] as [CGFloat] {
            let paragraph = node("paragraph", "Text", ["fontSize": size], props: ["text": "Your tabs live in the sidebar, sorted into spaces. Pin what you keep, and let Today tidy itself. Ads and trackers are blocked from the start."])
            renderer.render(node("root", "View", ["flexGrow": 1, "padding": 20], [paragraph]))
            let field = renderer.boxes["paragraph"]!.control as! NSTextField
            let needed = field.cell!.cellSize(forBounds: CGRect(x: 0, y: 0, width: field.frame.width, height: 1_000_000)).height
            require(field.frame.height >= needed, "A \(size)pt paragraph was \(field.frame.height)pt tall but needs \(needed)pt, so its last line was not drawn")
        }

        let body = node("body", "Text", ["fontSize": 13], props: ["text": String(repeating: "A long preview ", count: 30), "numberOfLines": 2])
        renderer.render(node("root", "View", ["flexGrow": 1], [body]))
        require(renderer.boxes["body"]!.measure(width: 120).height <= 36, "A two-line preview measured its hidden lines")

        let avatar = node("avatar", "View", ["width": 40, "height": 40, "padding": 4, "borderBottomWidth": 1], [
            node("face", "View", ["width": 32, "height": 32]),
            node("badgeScope", "View", [:], [node("badge", "View", ["position": "absolute", "right": 0, "bottom": 0, "width": 16, "height": 16])], props: ["data-stx-component-wrapper": true])
        ])
        renderer.render(node("root", "View", ["flexGrow": 1], [avatar]))
        require(renderer.boxes["avatar"]!.measure(width: 100).height == 40, "An overlay changed the avatar's natural height")
        require(renderer.boxes["badgeScope"]!.frame == CGRect(x: 24, y: 24, width: 16, height: 16), "An anchored badge was put in the normal flow")
        require(renderer.boxes["avatar"]!.edgeBorders["Bottom"]!.frame.height == 1, "The authored edge border was dropped")

        renderer.render(node("root", "View", ["flexGrow": 1], [node("archive", "Button", ["width": 30, "height": 30], props: ["title": "Archive", "symbol": "archivebox", "variant": "toolbar", "iconOnly": true])]))
        let button = renderer.boxes["archive"]!.control as! NSButton
        require(button.title.isEmpty && !button.isBordered && button.image != nil, "An icon toolbar action used a labelled bezel")

        func list(_ count: Int) -> [String: Any] {
            node("root", "View", ["flexGrow": 1], [node("scroll", "ScrollView", ["flexGrow": 1], (0..<count).map { node("row\($0)", "View", ["height": 30]) })])
        }
        renderer.render(list(40))
        let scroll = renderer.boxes["scroll"]!.control as! NSScrollView
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 800))
        renderer.render(list(1))
        require(scroll.contentView.bounds.origin.y == 0, "Filtering a list left its rows above the viewport")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = renderer.root; renderer.window = window
        let sheetScope = node("sheetScope", "View", [:], [node("sheet", "Modal", ["height": 200], props: ["visible": true])], props: ["data-stx-component-wrapper": true])
        renderer.render(node("root", "View", ["flexGrow": 1], [sheetScope]))
        renderer.boxes["sheetScope"]!.control!.layout()
        require(renderer.boxes["sheet"]!.frame.size == CGSize(width: 480, height: 200), "A deferred component pass resized sheet-owned content")
        // Content that arrives after the sheet opened grows it.
        let before = renderer.sheets["sheet"]!.contentRect(forFrameRect: renderer.sheets["sheet"]!.frame).height
        let grown = node("sheetScope", "View", [:], [node("sheet", "Modal", [:], [node("a", "View", ["height": 300]), node("b", "View", ["height": 200])], props: ["visible": true])], props: ["data-stx-component-wrapper": true])
        renderer.render(node("root", "View", ["flexGrow": 1], [grown]))
        let after = renderer.sheets["sheet"]!.contentRect(forFrameRect: renderer.sheets["sheet"]!.frame).height
        require(after > before + 100, "A sheet stayed the size it opened at after its content grew")
        if let panel = renderer.sheets["sheet"] { window.endSheet(panel); panel.close() }
        window.close()

        // Gradients, and the pointer's layers: hover and press apply on top of the style and come off again.
        renderer.root.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        let rowStyle: [String: Any] = ["height": 40, "backgroundColor": "#00000000", "borderRadius": 8, "transitionDuration": 120,
            "hoverStyle": ["backgroundColor": "#ffffff66"], "pressStyle": ["opacity": 0.7]]
        renderer.render(node("root", "View", ["flexGrow": 1, "gradientDirection": "to-br", "gradientFrom": "#3b5bfd", "gradientVia": "#5b6cff", "gradientTo": "#2a3bd8"], [node("row", "View", rowStyle)]))
        let painted = renderer.boxes["root"]!
        require(painted.gradient?.colors?.count == 3, "A gradient lost a stop")
        require(painted.gradient?.startPoint == CGPoint(x: 0, y: 0) && painted.gradient?.endPoint == CGPoint(x: 1, y: 1), "A to-br gradient runs the wrong way")
        require(painted.layer?.sublayers?.first === painted.gradient, "A gradient is not under the box's content")
        let row = renderer.boxes["row"]!
        require(row.hoverArea != nil, "A box with hover styles does not track the pointer")
        func alpha(_ color: CGColor?) -> CGFloat { NSColor(cgColor: color!)!.alphaComponent }
        require(alpha(row.layer?.backgroundColor) < 0.01, "The resting background is wrong")
        row.hovering = true; row.applyAppearance(animated: false)
        require(abs(alpha(row.layer?.backgroundColor) - 0.4) < 0.01, "Hovering did not apply hoverStyle")
        row.pressing = true; row.applyAppearance(animated: false)
        require(abs(row.alphaValue - 0.7) < 0.01, "Pressing did not apply pressStyle")
        row.hovering = false; row.pressing = false; row.applyAppearance(animated: true)
        require(alpha(row.layer?.backgroundColor) < 0.01, "Leaving did not restore the background")
        // A rounded card that clips its content and casts a shadow clips one level in.
        renderer.render(node("root", "View", ["flexGrow": 1], [node("card", "View", ["flexGrow": 1, "borderRadius": 12, "overflow": "hidden", "shadowOpacity": 0.2, "shadowRadius": 10], [node("page", "View", ["flexGrow": 1])])]))
        renderer.boxes["root"]!.layoutSubtreeIfNeeded()
        let card = renderer.boxes["card"]!
        require(card.layer?.masksToBounds == false && card.layer?.shadowOpacity ?? 0 > 0, "A card clipped away its own shadow")
        require(card.control?.layer?.masksToBounds == true && abs((card.control?.layer?.cornerRadius ?? 0) - 12) < 0.5, "A card with a shadow no longer clips its content to its corners")
        require(card.layer?.shadowPath != nil, "A shadow has no explicit path")
        // Drag and drop: a drop target registers, reports before/after/inside, and reads what a drag carries.
        var rowNode = node("dropRow", "Pressable", ["height": 40], props: ["draggable": true, "dragData": ["id": "t1"], "dropInside": true])
        rowNode["events"] = ["onDrop": "h1", "onDragOver": "h2", "onHoverChange": "h3", "onPress": "h4"]
        renderer.render(node("root", "View", ["flexGrow": 1], [rowNode]))
        renderer.boxes["root"]!.layoutSubtreeIfNeeded()
        let target = renderer.boxes["dropRow"]!
        require(target.registeredDraggedTypes.contains(CraftMacBox.dragType) && target.registeredDraggedTypes.contains(.URL), "A drop target did not register for drags")
        require(target.hoverArea != nil, "onHoverChange does not track the pointer")
        require(target.dropPosition(at: CGPoint(x: 5, y: 2)) == "before" && target.dropPosition(at: CGPoint(x: 5, y: 20)) == "inside" && target.dropPosition(at: CGPoint(x: 5, y: 38)) == "after", "Drop positions are wrong")
        let board = NSPasteboard(name: NSPasteboard.Name("org.craft-native.fixture.\(ProcessInfo.processInfo.processIdentifier)"))
        board.clearContents()
        let item = NSPasteboardItem()
        item.setData(try! JSONSerialization.data(withJSONObject: ["data": ["id": "t1"]]), forType: CraftMacBox.dragType)
        item.setString("https://stacksjs.com/", forType: .URL)
        board.writeObjects([item])
        let payload = target.dropPayload(board, position: "after")
        require((payload["data"] as? [String: Any])?["id"] as? String == "t1" && payload["internal"] as? Bool == true, "A drop lost the drag's data")
        require((payload["urls"] as? [String])?.first == "https://stacksjs.com/", "A drop lost the link it carried")
        board.releaseGlobally()
        renderer.render(node("root", "View", ["flexGrow": 1], [node("dropRow", "Pressable", ["height": 40])]))
        require(renderer.boxes["dropRow"]!.registeredDraggedTypes.isEmpty, "A box kept accepting drops after its drop handlers went")

        renderer.render(node("root", "View", ["flexGrow": 1], [node("row", "View", ["height": 40])]))
        require(renderer.boxes["root"]!.gradient == nil, "A gradient stayed after its classes went")
        require(renderer.boxes["row"]!.hoverArea == nil, "A box kept tracking the pointer after its hover styles went")

        // A measurement is remembered through a layout pass and forgotten when anything changes.
        renderer.render(node("root", "View", ["flexGrow": 1], [node("column", "View", [:], [node("grow", "Text", ["fontSize": 13], props: ["text": "Short"])])]))
        let shortHeight = renderer.boxes["column"]!.frame.height
        renderer.render(node("root", "View", ["flexGrow": 1], [node("column", "View", [:], [node("grow", "Text", ["fontSize": 13], props: ["text": String(repeating: "Much longer words that wrap ", count: 12)])])]))
        require(renderer.boxes["column"]!.frame.height > shortHeight * 2, "A remembered measurement outlived a change of text")
        renderer.render(node("root", "View", ["flexGrow": 1], [node("column", "View", [:], [node("a", "View", ["height": 20]), node("b", "View", ["height": 20]), node("c", "View", ["height": 20])])]))
        require(abs(renderer.boxes["column"]!.frame.height - 60) < 1, "A remembered measurement outlived new children")
        renderer.render(node("root", "View", ["flexGrow": 1], [node("column", "View", [:], [node("a", "View", ["height": 20]), node("b", "View", ["height": 20, "display": "none"])])]))
        require(abs(renderer.boxes["column"]!.frame.height - 20) < 1, "A remembered measurement outlived a hidden child")
        // Rows inside columns inside rows: each box is measured a few times per pass, not once per path through its ancestors.
        func nested(_ depth: Int) -> [String: Any] {
            depth == 0 ? node("leaf", "Text", [:], props: ["text": "Leaf"])
                : node("level\(depth)", "View", depth % 2 == 0 ? ["flexDirection": "row"] : [:], [nested(depth - 1), node("side\(depth)", "Text", [:], props: ["text": "Side \(depth)"])])
        }
        CraftMacBox.measuredCount = 0
        renderer.render(node("root", "View", ["flexGrow": 1], [nested(14)]))
        require(CraftMacBox.measuredCount < 30 * 12, "A 30-box tree took \(CraftMacBox.measuredCount) measurements")
        require(renderer.boxes["leaf"]!.frame.width > 0 && renderer.boxes["side14"]!.frame.height > 0, "The nested tree was not laid out")

        // A batch is drawn where it changed: the changed row and the rows inserted under a list,
        // and nothing else reconfigured or measured again.
        var tree: [String: [String: Any]] = [:]
        var parents: [String: String] = [:]
        func listNode(_ ids: [String], label: (String) -> String) -> [String: Any] {
            let rows = ids.map { node($0, "Text", ["height": 20], props: ["text": label($0)]) }
            for row in rows { tree[row["id"] as! String] = row; parents[row["id"] as! String] = "list" }
            let list = node("list", "View", [:], rows); tree["list"] = list; parents["list"] = "root"
            let root = node("root", "View", ["flexGrow": 1], [node("header", "View", ["height": 30]), list]); tree["root"] = root
            return root
        }
        renderer.render(listNode(["r1", "r2", "r3"]) { "Row \($0)" })
        let untouched = renderer.boxes["header"]!
        CraftMacBox.measuredCount = 0
        _ = listNode(["r1", "r2", "r3"]) { $0 == "r2" ? "Changed" : "Row \($0)" }
        require(renderer.update(["r2"], parentOf: { parents[$0] }, node: { tree[$0] }), "A row's change could not be drawn in place")
        require((renderer.boxes["r2"]!.control as? NSTextField)?.stringValue == "Changed", "An in-place update did not reach the row")
        require(renderer.boxes["header"] === untouched && CraftMacBox.measuredCount < 12, "An in-place update measured \(CraftMacBox.measuredCount) boxes")
        _ = listNode(["r1", "r2", "r3", "r4"]) { "Row \($0)" }
        require(renderer.update(["r4", "list"], parentOf: { parents[$0] }, node: { tree[$0] }), "An inserted row could not be drawn in place")
        require(abs(renderer.boxes["r4"]!.frame.minY - renderer.boxes["r3"]!.frame.minY - 20) < 1, "An inserted row was not laid out after its siblings")
        _ = listNode(["r1", "r4"]) { "Row \($0)" }
        require(renderer.update(["list"], parentOf: { parents[$0] }, node: { tree[$0] }), "Removed rows could not be drawn in place")
        require(renderer.boxes["r2"] == nil && renderer.boxes["r3"] == nil && abs(renderer.boxes["r4"]!.frame.minY - renderer.boxes["r1"]!.frame.minY - 20) < 1, "Removed rows stayed drawn")
        let empty = CraftMacRenderer(runtime: runtime)
        require(!empty.update(["r1"], parentOf: { parents[$0] }, node: { tree[$0] }), "An update with nothing drawn did not ask for a full render")

        // Flows inside flows are laid out in AppKit's one pass, not a nested pass per box: after a render
        // and after the window resizes, the innermost box has the space its ancestors leave it.
        renderer.root.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        renderer.render(node("root", "View", ["flexGrow": 1, "flexDirection": "row"], [
            node("pane", "View", ["flexGrow": 1], [node("inner", "View", ["flexGrow": 1, "padding": 10], [node("deep", "View", ["flexGrow": 1])])]),
            node("rail", "View", ["width": 20])
        ]))
        require(renderer.boxes["deep"]!.frame.size == CGSize(width: 280, height: 280), "A nested flow was not laid out with its parents")
        renderer.root.frame = CGRect(x: 0, y: 0, width: 420, height: 200); renderer.root.layoutSubtreeIfNeeded()
        require(renderer.boxes["deep"]!.frame.size == CGSize(width: 380, height: 180), "A resize left a nested flow at its old size")
        renderer.root.frame = CGRect(x: 0, y: 0, width: 320, height: 300); renderer.root.layoutSubtreeIfNeeded()

        // A button is set up as NSButton(title:target:action:) sets one up, without the sizeToFit it ends with.
        func archived(_ view: NSView) -> String {
            let coder = NSKeyedArchiver(requiringSecureCoding: false); view.encode(with: coder); coder.finishEncoding()
            let plist = try! PropertyListSerialization.propertyList(from: coder.encodedData, format: nil)
            return "\(plist)".replacingOccurrences(of: "0x[0-9a-f]+", with: "0x", options: .regularExpression)
        }
        let freshButton = CraftMacBox(id: "fresh", kind: "Button", renderer: renderer)
        let madeButton = freshButton.control as! NSButton; madeButton.removeFromSuperview()
        let referenceButton = NSButton(title: "", target: freshButton, action: #selector(CraftMacBox.pressed)); referenceButton.bezelStyle = .rounded
        referenceButton.clipsToBounds = true // as the box sets every control
        referenceButton.frame = madeButton.frame
        require(archived(madeButton) == archived(referenceButton), "A button was not set up as NSButton(title:target:action:) sets one up")

        require(runtime.errors.isEmpty, "The renderer reported an unsupported control")
        print("PASS native component sizing, text limits, overlays, borders, toolbar actions, filtered scrolling, gradients, pointer styles, remembered measurements, in-place updates, one-pass nested layout and buttons")
    }
}
