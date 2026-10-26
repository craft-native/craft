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
        if let panel = renderer.sheets["sheet"] { window.endSheet(panel); panel.close() }
        window.close()
        require(runtime.errors.isEmpty, "The renderer reported an unsupported control")
        print("PASS native component sizing, text limits, overlays, borders, toolbar actions and filtered scrolling")
    }
}
