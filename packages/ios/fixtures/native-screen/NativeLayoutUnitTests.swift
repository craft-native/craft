import JavaScriptCore
import Security
import UIKit
import XCTest
@testable import NativeRender

/// The flex layout and the host APIs native screens rely on for HQ's Today:
/// each test is one gap the 2026-10-09 prototype found.
@MainActor
final class NativeLayoutUnitTests: XCTestCase {
    private func screen(_ root: [String: Any], config: CraftConfig = CraftConfig(), width: CGFloat = 390) -> CraftNativeScreenController {
        let controller = CraftNativeScreenController(config: config)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 844)
        controller.render(root)
        controller.view.layoutIfNeeded()
        return controller
    }

    func testNativeScreenUsesConfiguredUIKitAppearance() {
        var config = CraftConfig()
        config.appearance = "light"
        let light = CraftNativeScreenController(config: config)
        light.loadViewIfNeeded()
        XCTAssertEqual(light.overrideUserInterfaceStyle, .light)

        config.appearance = "dark"
        let dark = CraftNativeScreenController(config: config)
        dark.loadViewIfNeeded()
        XCTAssertEqual(dark.overrideUserInterfaceStyle, .dark)

        config.appearance = "system"
        let system = CraftNativeScreenController(config: config)
        system.loadViewIfNeeded()
        XCTAssertEqual(system.overrideUserInterfaceStyle, .unspecified)
    }

    func testReturningToAnUnchangedThemeRetainsTextAndScrollGeometry() throws {
        let rows: [[String: Any]] = (0..<100).map { index in
            ["id": "row-\(index)", "type": "Text", "props": ["testID": "row-\(index)"],
             "style": ["fontSize": 17, "letterSpacing": 0.3, "padding": 12], "children": ["Training session \(index)"]]
        }
        let controller = screen(["id": "root", "type": "ScrollView", "style": ["flex": 1], "children": rows])
        controller.viewWillAppear(false)
        controller.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(controller.view.subviews.first?.subviews.first as? UIScrollView)
        let label = try XCTUnwrap(find("row-0", below: controller.view) as? UILabel)
        let text = label.attributedText
        scroll.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        let size = scroll.contentSize
        let start = CACurrentMediaTime()
        for _ in 0..<20 {
            controller.viewWillAppear(false)
            controller.view.layoutIfNeeded()
        }
        NSLog("PERF unchanged tab appearance 100 rows: %.3f ms per visit", (CACurrentMediaTime() - start) * 1000 / 20)
        XCTAssertTrue(label.attributedText === text, "unchanged appearance must not restyle every label")
        XCTAssertEqual(scroll.contentOffset.y, 400, accuracy: 0.5)
        XCTAssertEqual(scroll.contentSize, size)
        controller.overrideUserInterfaceStyle = .dark
        controller.viewWillAppear(false)
        XCTAssertEqual(label.text, "Training session 0")
    }

    func testSnapshotCacheTracksPendingWritesDeletionAndRecreation() async throws {
        let name = "cache-test-" + UUID().uuidString
        func write(_ json: String?) async -> Bool {
            await withCheckedContinuation { continuation in
                CraftSnapshots.write(name, json: json) { continuation.resume(returning: $0) }
            }
        }
        let created = await write("{\"count\":1}")
        XCTAssertTrue(created)
        for _ in 0..<100 { XCTAssertEqual(CraftSnapshots.read(name), "{\"count\":1}") }
        let finished = expectation(description: "queued snapshot writes completed")
        CraftSnapshots.write(name, json: "{\"count\":2}")
        CraftSnapshots.write(name, json: "{\"count\":3}")
        CraftSnapshots.write(name, json: "{\"count\":2}") { ok in
            XCTAssertTrue(ok)
            finished.fulfill()
        }
        XCTAssertEqual(CraftSnapshots.read(name), "{\"count\":2}")
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(CraftSnapshots.read(name), "{\"count\":2}")
        let removed = await write(nil)
        XCTAssertTrue(removed)
        XCTAssertNil(CraftSnapshots.read(name))
        let recreated = await write("{\"count\":4}")
        XCTAssertTrue(recreated)
        XCTAssertEqual(CraftSnapshots.read(name), "{\"count\":4}")
        let cleaned = await write(nil)
        XCTAssertTrue(cleaned)
    }

    func testAccountScopedSnapshotNamesPersistAndClearIndependently() async throws {
        let names = ["larq-bottle:116", "larq-bottle:117"]
        for (index, name) in names.enumerated() {
            let kept = await withCheckedContinuation { continuation in
                CraftSnapshots.write(name, json: "{\"account\":\(index)}") { continuation.resume(returning: $0) }
            }
            XCTAssertTrue(kept)
            XCTAssertEqual(CraftSnapshots.read(name), "{\"account\":\(index)}")
            XCTAssertTrue(CraftSnapshots.names().contains(name))
        }
        XCTAssertNil(CraftSnapshots.url(for: "../larq-bottle:116"))
        XCTAssertNil(CraftSnapshots.url(for: "bottle/116"))
        let cleared = await withCheckedContinuation { continuation in
            CraftSnapshots.clear(keeping: Set(CraftSnapshots.names()).subtracting([names[0]])) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(cleared)
        XCTAssertNil(CraftSnapshots.read(names[0]))
        XCTAssertNotNil(CraftSnapshots.read(names[1]))
        let removed = await withCheckedContinuation { continuation in
            CraftSnapshots.write(names[1], json: nil) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(removed)
    }

    func testCompiledFlexibleScrollingWrappersReachTheLastControl() async throws {
        let rows = (0..<20).map { box("card-\($0)", style: ["height": 100], [text("label-\($0)", "Bottle detail \($0)")]) }
        let controller = screen(box("root", [
          box("empty-header"),
          box("wrapper", style: ["maxWidth": 768, "flex": 1, "flexGrow": 1, "flexShrink": 1, "flexBasis": 0], [
            box("screen", style: ["flex": 1, "flexGrow": 1, "flexShrink": 1, "flexBasis": 0], [
                ["id": "form", "type": "ScrollView", "props": ["testID": "form"],
                 "style": ["flex": 1, "flexGrow": 1, "flexShrink": 1, "flexBasis": 0], "children": rows],
            ]),
          ]),
        ]))
        await settle(controller)
        let scroll = try XCTUnwrap(find("form", below: controller.view) as? UIScrollView)
        XCTAssertGreaterThan(scroll.bounds.height, 600)
        XCTAssertLessThanOrEqual(scroll.bounds.height, controller.view.bounds.height)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 1000)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
        scroll.layoutIfNeeded()
        let last = try XCTUnwrap(find("card-19", below: controller.view))
        XCTAssertEqual(last.convert(last.bounds, to: scroll).maxY, scroll.contentSize.height, accuracy: 1)
        XCTAssertGreaterThan(scroll.contentOffset.y, 1000)
    }

    func testContainerFillsSurvivePressFeedbackReconciliation() throws {
        func document(_ fill: String?) -> [String: Any] {
            var style: [String: Any] = ["width": 100, "height": 44, "borderRadius": 12]
            if let fill { style["backgroundColor"] = fill }
            return box("root", [
                box("avatar", style: style),
                ["id": "follow", "type": "View", "props": ["testID": "follow"],
                 "style": style, "events": ["onPress": "follow"]],
                ["id": "feedback", "type": "View", "props": ["testID": "feedback"],
                 "style": style, "events": fill == "#ff0000" ? ["onPressIn": "pressed"] : [:]],
                ["id": "touchable", "type": "TouchableHighlight", "props": ["testID": "touchable"],
                 "style": style],
            ])
        }
        let controller = screen(document("#ff0000"))
        for key in ["avatar", "follow", "feedback", "touchable"] {
            try assertColor(try XCTUnwrap(find(key, below: controller.view)).backgroundColor, red: 1, green: 0, blue: 0)
        }
        controller.render(document("#0000ff"))
        for key in ["avatar", "follow", "feedback", "touchable"] {
            try assertColor(try XCTUnwrap(find(key, below: controller.view)).backgroundColor, red: 0, green: 0, blue: 1)
        }
        controller.render(document(nil))
        for key in ["avatar", "follow", "feedback", "touchable"] {
            XCTAssertEqual(try XCTUnwrap(find(key, below: controller.view)).backgroundColor?.cgColor.alpha, 0)
        }
    }

    func testOnlyLeadingScrollContentEscapesItsViewport() throws {
        func scroll(_ key: String, overflow: String? = nil) -> [String: Any] {
            var style: [String: Any] = ["height": 80]
            if let overflow { style["overflow"] = overflow }
            return ["type": "ScrollView", "props": ["testID": key], "style": style,
                    "children": [box("content", style: ["height": 240])]]
        }
        let nested = screen(box("form", style: ["paddingTop": 16], [scroll("nested")]))
        XCTAssertTrue(try XCTUnwrap(find("nested", below: nested.view)).clipsToBounds)
        let leading = screen(scroll("leading"))
        XCTAssertFalse(try XCTUnwrap(find("leading", below: leading.view)).clipsToBounds)
        let hidden = screen(scroll("hidden", overflow: "hidden"))
        XCTAssertTrue(try XCTUnwrap(find("hidden", below: hidden.view)).clipsToBounds)
        let visible = screen(box("form", style: ["paddingTop": 16], [scroll("visible", overflow: "visible")]))
        XCTAssertFalse(try XCTUnwrap(find("visible", below: visible.view)).clipsToBounds)
    }

    func testUncontrolledInputReceivesTouchesWithoutEventHandlers() throws {
        let controller = screen(box("root", [
            ["type": "TextInput", "props": ["testID": "draft", "placeholder": "Note"]],
        ]))
        let input = try XCTUnwrap(find("draft", below: controller.view) as? UITextField)
        XCTAssertTrue(input.isUserInteractionEnabled)
        XCTAssertTrue(input.isEnabled)
        let point = input.convert(CGPoint(x: input.bounds.midX, y: input.bounds.midY), to: controller.view)
        let hit = controller.view.hitTest(point, with: nil)
        XCTAssertTrue(hit === input || hit?.isDescendant(of: input) == true)
        controller.render(box("root", [
            ["type": "TextInput", "props": ["testID": "draft", "placeholder": "Updated"]],
        ]))
        XCTAssertTrue(find("draft", below: controller.view) === input)
        XCTAssertTrue(input.isUserInteractionEnabled)
    }

    func testInputAlignmentSurvivesDefaultAttributesAndControlledValueUpdates() throws {
        for (alignment, expected) in [("right", NSTextAlignment.right), ("center", .center), ("left", .left)] {
            func document(_ value: String) -> [String: Any] {
                box("root", style: ["flexDirection": "row", "alignItems": "center"], [
                    text("label", "Weight (kg)", style: ["flex": 1]),
                    ["id": "value", "type": "TextInput",
                     "props": ["testID": "weight", "value": value, "placeholder": "—", "placeholderTextColor": "#8e8e93"],
                     "style": ["width": 80, "minHeight": 44, "fontSize": 17, "textAlign": alignment]],
                ])
            }
            let controller = screen(document("70.6"))
            let input = try XCTUnwrap(find("weight", below: controller.view) as? UITextField)
            XCTAssertEqual(input.textAlignment, expected, alignment)
            controller.render(document("71.2"))
            XCTAssertTrue(find("weight", below: controller.view) === input)
            XCTAssertEqual(input.text, "71.2")
            XCTAssertEqual(input.textAlignment, expected, alignment)
            controller.render(document(""))
            XCTAssertEqual(input.placeholder, "—")
            XCTAssertEqual(input.textAlignment, expected, alignment)
        }
    }

    func testRawContainerTextRendersAndNamesNativeLinks() throws {
        func document(_ title: String) -> [String: Any] {
            ["type": "TouchableOpacity", "props": ["testID": "route-link", "href": "/details"],
             "style": ["fontSize": 22, "color": "#ff0000", "padding": 12], "children": [title]]
        }
        let controller = screen(document("Open details"))
        let link = try XCTUnwrap(find("route-link", below: controller.view))
        let label = try XCTUnwrap(link.subviews.compactMap { $0 as? UILabel }.first)
        XCTAssertEqual(label.text, "Open details")
        XCTAssertGreaterThan(label.frame.height, 0)
        XCTAssertEqual(label.font.pointSize, 22, accuracy: 0.01)
        try assertColor(label.textColor, red: 1, green: 0, blue: 0)
        XCTAssertTrue(link.isAccessibilityElement)
        XCTAssertTrue(link.accessibilityTraits.contains(.link))
        XCTAssertEqual(link.accessibilityLabel, "Open details")
        let tap = try XCTUnwrap(link.gestureRecognizers?.first { $0 is UITapGestureRecognizer })
        controller.render(document("Updated details"))
        XCTAssertTrue(link.gestureRecognizers?.contains(where: { $0 === tap }) == true)
        XCTAssertTrue(find("route-link", below: controller.view) === link)
        XCTAssertEqual(link.accessibilityLabel, "Updated details")
    }

    func testActivityIndicatorSizeSurvivesStyleReconciliation() throws {
        func document(_ size: Any, transform: [[String: Any]]? = nil) -> [String: Any] {
            var style: [String: Any] = [:]
            if let transform { style["transform"] = transform }
            return ["type": "ActivityIndicator", "props": ["key": "indicator", "size": size], "style": style]
        }
        let controller = screen(document("small"))
        let indicator = try XCTUnwrap(find("indicator", below: controller.view) as? UIActivityIndicatorView)
        XCTAssertEqual(indicator.transform.a, 0.75, accuracy: 0.001)
        XCTAssertEqual(indicator.transform.d, 0.75, accuracy: 0.001)
        controller.render(document("large"))
        XCTAssertTrue(find("indicator", below: controller.view) === indicator)
        XCTAssertEqual(indicator.transform.a, 1, accuracy: 0.001)
        controller.render(document(40, transform: [["scale": 0.5], ["translateX": 4]]))
        XCTAssertEqual(indicator.transform.a, 1, accuracy: 0.001)
        XCTAssertEqual(indicator.transform.d, 1, accuracy: 0.001)
        XCTAssertEqual(indicator.transform.tx, 2, accuracy: 0.001)
        controller.render(document("small"))
        XCTAssertEqual(indicator.transform.a, 0.75, accuracy: 0.001)
        XCTAssertEqual(indicator.transform.tx, 0, accuracy: 0.001)
    }

    func testActivityIndicatorDisplayNoneWinsOverAnimationAndStoppedVisibility() throws {
        func document(hidden: Bool, animating: Bool = true, hidesWhenStopped: Bool = true) -> [String: Any] {
            ["type": "ActivityIndicator", "props": ["key": "indicator", "animating": animating, "hidesWhenStopped": hidesWhenStopped],
             "style": hidden ? ["display": "none"] : [:]]
        }
        let controller = screen(document(hidden: true))
        let indicator = try XCTUnwrap(find("indicator", below: controller.view) as? UIActivityIndicatorView)
        XCTAssertTrue(indicator.isAnimating)
        XCTAssertTrue(indicator.isHidden, "starting animation must not override authored display:none")
        controller.render(document(hidden: false))
        XCTAssertTrue(find("indicator", below: controller.view) === indicator)
        XCTAssertFalse(indicator.isHidden)
        controller.render(document(hidden: true, animating: false, hidesWhenStopped: false))
        XCTAssertFalse(indicator.isAnimating)
        XCTAssertTrue(indicator.isHidden, "display:none also wins over a stopped indicator that normally stays visible")
        controller.render(document(hidden: false, animating: false, hidesWhenStopped: false))
        XCTAssertFalse(indicator.isHidden)
        controller.render(document(hidden: false, animating: false))
        XCTAssertTrue(indicator.isHidden)
        controller.render(document(hidden: false))
        XCTAssertFalse(indicator.isHidden)
        XCTAssertTrue(indicator.isAnimating)
    }

    private func settle(_ controller: CraftNativeScreenController) async {
        // These fixtures measure committed geometry, not main-queue timer
        // latency. Lay out the containing window/navigation bar before the
        // screen so safe-area and large-title changes reach its scroll views.
        // Diffable snapshots finish on the main queue and may coalesce another
        // render. Release the main actor between the existing four passes,
        // then resume only after actual ancestor/screen layout completes.
        // This is a completion barrier, not a timer-latency measurement.
        for _ in 0..<4 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async {
                    UIView.performWithoutAnimation {
                        controller.view.window?.setNeedsLayout()
                        controller.view.window?.layoutIfNeeded()
                        controller.navigationController?.view.setNeedsLayout()
                        controller.navigationController?.view.layoutIfNeeded()
                        controller.view.setNeedsLayout()
                        controller.view.layoutIfNeeded()
                        CATransaction.flush()
                    }
                    continuation.resume()
                }
            }
        }
    }

    private func waitForSnapshotFile(
        _ name: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        guard let file = CraftSnapshots.url(for: name) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if FileManager.default.fileExists(atPath: file.path) { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        } while Date() < deadline
        return false
    }

    private func find(_ key: String, below view: UIView) -> UIView? {
        if view.accessibilityIdentifier == key { return view }
        for child in view.subviews {
            if let match = find(key, below: child) { return match }
        }
        return nil
    }

    private func frame(_ key: String, in controller: CraftNativeScreenController) throws -> CGRect {
        let view = try XCTUnwrap(find(key, below: controller.view), "no view \(key)")
        return view.convert(view.bounds, to: controller.view)
    }

    private func assertColor(_ color: UIColor?, red: CGFloat, green: CGFloat, blue: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        let color = try XCTUnwrap(color, file: file, line: line)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a), file: file, line: line)
        XCTAssertEqual(r, red, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(g, green, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(b, blue, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a, 1, accuracy: 0.001, file: file, line: line)
    }

    private func text(_ key: String, _ value: String, style: [String: Any] = [:], props: [String: Any] = [:]) -> [String: Any] {
        ["id": key, "type": "Text", "props": props.merging(["testID": key]) { $1 }, "style": style, "children": [value]]
    }

    private func box(_ key: String, style: [String: Any] = [:], props: [String: Any] = [:], _ children: [[String: Any]] = []) -> [String: Any] {
        ["id": key, "type": "View", "props": props.merging(["testID": key]) { $1 }, "style": style, "children": children]
    }

    func testFlexOneSharesARowEquallyWhateverTheContent() throws {
        let controller = screen(box("root", style: ["flex": 1], [
            box("row", style: ["flexDirection": "row", "gap": 8, "padding": 16], [
                box("a", style: ["flex": 1, "padding": 8], [text("a-text", "Short")]),
                box("b", style: ["flex": 1, "padding": 8], [text("b-text", "A much longer label that wraps inside its third of the row")]),
                box("c", style: ["flex": 1, "padding": 8], [text("c-text", "Mid label")]),
            ]),
        ]))
        let a = try frame("a", in: controller), b = try frame("b", in: controller), c = try frame("c", in: controller)
        XCTAssertEqual(a.width, b.width, accuracy: 1)
        XCTAssertEqual(b.width, c.width, accuracy: 1)
        XCTAssertEqual(a.minX, 16, accuracy: 0.5)
        XCTAssertEqual(c.maxX, 390 - 16, accuracy: 1)
        let wrapped = try frame("b-text", in: controller)
        XCTAssertLessThanOrEqual(wrapped.width, b.width - 16 + 0.5)
        XCTAssertGreaterThan(wrapped.height, try frame("a-text", in: controller).height * 2)
        // Siblings stretch to the tallest one.
        XCTAssertEqual(a.height, b.height, accuracy: 0.5)
    }

    func testTextTruncatesInsideItsParentInsteadOfWideningIt() throws {
        let long = "This single line is far too long for the card it sits in and must end with an ellipsis"
        let controller = screen(box("root", style: ["padding": 16, "gap": 12], [
            box("card", style: ["padding": 12], [text("line", long, props: ["numberOfLines": 1])]),
            box("row", style: ["flexDirection": "row", "gap": 12, "alignItems": "center"], [
                box("avatar", style: ["width": 40, "height": 40]),
                text("beside", long, props: ["numberOfLines": 1]),
            ]),
            text("centered", "Centred", style: ["textAlign": "center"]),
        ]))
        XCTAssertEqual(try frame("card", in: controller).width, 390 - 32, accuracy: 0.5)
        XCTAssertEqual(try frame("line", in: controller).width, 390 - 32 - 24, accuracy: 0.5)
        let beside = try frame("beside", in: controller)
        XCTAssertEqual(beside.maxX, 390 - 16, accuracy: 1)
        XCTAssertEqual(beside.minX, 16 + 40 + 12, accuracy: 1)
        // text-center: the label spans the column, so centring shows.
        let centered = try XCTUnwrap(find("centered", below: controller.view) as? UILabel)
        XCTAssertEqual(centered.frame.width, 390 - 32, accuracy: 0.5)
        XCTAssertEqual(centered.textAlignment, .center)
    }

    func testAShrinkToFitBubbleWithAPercentageMaxWidthTakesItsTextsWidth() throws {
        // HQ's chat thread: a justify-end row holding a padded bubble with
        // max-w-[78%]. stx once sent that bound as 78 points, and "See you
        // Thursday" broke as "See / you / Thurs / day" (2026-10-13).
        func bubble(_ key: String, _ body: String) -> [String: Any] {
            box("\(key)-row", style: ["flexDirection": "row", "justifyContent": "flex-end"], [
                box(key, style: ["paddingHorizontal": 14, "paddingVertical": 8, "maxWidth": "78%", "borderRadius": 18], [
                    text("\(key)-text", body, style: ["fontSize": 17]),
                ]),
            ])
        }
        let long = "A longer reply that has to wrap inside the bubble, between its words and nowhere else"
        let controller = screen(box("root", style: ["flex": 1, "paddingHorizontal": 12, "gap": 8], [
            bubble("short", "See you Thursday"),
            bubble("long", long),
        ]))
        let row = try frame("short-row", in: controller)
        let short = try frame("short", in: controller), shortText = try frame("short-text", in: controller)
        let font = UIFont.systemFont(ofSize: 17)
        let oneLine = ceil(("See you Thursday" as NSString).size(withAttributes: [.font: font]).width)
        // As wide as its text on one line, plus padding, and right-aligned.
        XCTAssertEqual(short.width, oneLine + 28, accuracy: 1.5)
        XCTAssertGreaterThanOrEqual(shortText.width, oneLine - 0.5)
        XCTAssertLessThan(shortText.height, font.lineHeight * 1.5)
        XCTAssertEqual(short.maxX, row.maxX, accuracy: 1)

        // A long one stops at 78% of the row and wraps between words.
        let longBubble = try frame("long", in: controller), longText = try frame("long-text", in: controller)
        XCTAssertEqual(longBubble.width, row.width * 0.78, accuracy: 1)
        XCTAssertGreaterThan(longText.height, font.lineHeight * 1.5)
        let widestWord = long.split(separator: " ").map { ceil((String($0) as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        // Every word fits a line, so none is broken mid-way.
        XCTAssertGreaterThanOrEqual(longText.width, widestWord)
    }

    func testKeyboardFrameUpdatesAndRestoresTheAdditionalSafeArea() {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        let keyboardFrame = CGRect(x: 0, y: 500, width: 390, height: 344)
        let userInfo: [AnyHashable: Any] = [
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: keyboardFrame),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0,
            UIResponder.keyboardAnimationCurveUserInfoKey: 0,
        ]

        NotificationCenter.default.post(
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            userInfo: userInfo
        )
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.additionalSafeAreaInsets.bottom, 344, accuracy: 0.5)

        NotificationCenter.default.post(
            name: UIResponder.keyboardWillHideNotification,
            object: nil,
            userInfo: userInfo
        )
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.additionalSafeAreaInsets.bottom, 0, accuracy: 0.5)
    }

    func testRoundedFullIsClampedToHalfTheShortestSide() throws {
        let controller = screen(box("root", style: ["flexDirection": "row", "alignItems": "center", "gap": 8], [
            box("circle", style: ["width": 48, "height": 48, "borderRadius": 9999]),
            box("pill", style: ["width": 96, "height": 32, "borderRadius": 9999]),
            box("arbitrary", style: ["width": 48, "height": 48, "borderRadius": 6]),
        ]))
        XCTAssertEqual(try XCTUnwrap(find("circle", below: controller.view)).layer.cornerRadius, 24)
        XCTAssertEqual(try XCTUnwrap(find("pill", below: controller.view)).layer.cornerRadius, 16)
        XCTAssertEqual(try XCTUnwrap(find("arbitrary", below: controller.view)).layer.cornerRadius, 6)
    }

    func testTextPaddingAndLetterSpacing() throws {
        let controller = screen(box("root", style: ["flexDirection": "row", "alignItems": "flex-start", "gap": 8], [
            text("plain", "Planned", style: ["fontSize": 12]),
            text("chip", "Planned", style: ["fontSize": 12, "paddingHorizontal": 12, "paddingVertical": 4, "borderRadius": 9999]),
            text("tracked", "Tracked", style: ["letterSpacing": 4.2, "textAlign": "center"]),
        ]))
        let plain = try frame("plain", in: controller)
        let chip = try frame("chip", in: controller)
        XCTAssertEqual(chip.width - plain.width, 24, accuracy: 1)
        XCTAssertEqual(chip.height - plain.height, 8, accuracy: 1)
        let label = try XCTUnwrap(find("chip", below: controller.view) as? UILabel)
        XCTAssertTrue(label.clipsToBounds)
        XCTAssertEqual(label.layer.cornerRadius, chip.height / 2, accuracy: 0.5)
        let tracked = try XCTUnwrap(find("tracked", below: controller.view) as? UILabel)
        XCTAssertEqual(tracked.attributedText?.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat, 4.2)
        XCTAssertEqual(tracked.textAlignment, .center)
    }

    func testImagePixelsHonorRoundedCornersWithoutHiddenOverflow() throws {
        for kind in ["Image", "ImageBackground"] {
            func document(_ radius: CGFloat) -> [String: Any] {
                box("root", [
                    ["id": "avatar", "type": kind, "props": ["testID": "avatar", "resizeMode": "contain"],
                     "style": ["width": 48, "height": 48, "borderRadius": radius, "overflow": "visible"]],
                ])
            }
            let controller = screen(document(9999))
            let image = try XCTUnwrap(find("avatar", below: controller.view) as? UIImageView)
            XCTAssertTrue(image.clipsToBounds, kind)
            XCTAssertTrue(image.layer.masksToBounds, kind)
            XCTAssertEqual(image.layer.cornerRadius, 24, accuracy: 0.5, kind)
            controller.render(document(6))
            controller.view.layoutIfNeeded()
            XCTAssertTrue(image === find("avatar", below: controller.view), kind)
            XCTAssertTrue(image.clipsToBounds, kind)
            XCTAssertEqual(image.layer.cornerRadius, 6, accuracy: 0.5, kind)
            controller.render(document(0))
            controller.view.layoutIfNeeded()
            XCTAssertFalse(image.clipsToBounds, kind)
            XCTAssertEqual(image.layer.cornerRadius, 0, accuracy: 0.5, kind)
        }
    }

    func testButtonHonoursAlignSelfStretch() throws {
        let controller = screen(box("root", style: ["padding": 16, "alignItems": "center"], [
            ["id": "start", "type": "Button", "props": ["testID": "start"], "style": ["height": 44, "alignSelf": "stretch"], "children": ["Start"]],
            ["id": "small", "type": "Button", "props": ["testID": "small"], "style": ["height": 44], "children": ["Small"]],
        ]))
        XCTAssertEqual(try frame("start", in: controller).width, 390 - 32, accuracy: 0.5)
        XCTAssertLessThan(try frame("small", in: controller).width, 200)
    }

    func testAlignContentStretchExpandsAutoCrossSizes() throws {
        let controller = screen(box("root", style: [
            "width": 120, "height": 96, "flexDirection": "row", "flexWrap": "wrap", "alignContent": "stretch"
        ], [
            text("first", "first", style: ["width": 60]),
            text("second", "second", style: ["width": 60]),
            text("third", "third", style: ["width": 60]),
            text("fourth", "fourth", style: ["width": 60]),
        ]), width: 120)
        let first = try frame("first", in: controller)
        let third = try frame("third", in: controller)
        XCTAssertGreaterThan(first.height, 35)
        XCTAssertEqual(first.height, third.height, accuracy: 1)
        XCTAssertGreaterThan(third.minY, first.minY + 35)
    }

    func testFractionalGridSwatchesFillTheirColumnsAtAFixedHeight() throws {
        let controller = screen(box("root", style: [
            "display": "grid", "gridTemplateColumns": "repeat(3, 1fr)", "columnGap": 4, "width": 121, "height": 32
        ], [
            box("first", style: ["height": 20]),
            box("second", style: ["height": 20]),
            box("third", style: ["height": 20]),
            // An aspect ratio still derives the width from the height.
            box("square", style: ["height": 20, "aspectRatio": 1]),
        ]), width: 121)
        let first = try frame("first", in: controller)
        let second = try frame("second", in: controller)
        let third = try frame("third", in: controller)
        XCTAssertEqual(first.width, 37.67, accuracy: 0.5)
        XCTAssertEqual(second.width, first.width, accuracy: 0.5)
        XCTAssertEqual(first.height, 20, accuracy: 0.5)
        XCTAssertEqual(second.minX - first.maxX, 4, accuracy: 0.5)
        XCTAssertLessThanOrEqual(third.maxX, try frame("root", in: controller).maxX + 0.5)
        XCTAssertEqual(try frame("square", in: controller).width, 20, accuracy: 0.5)
    }

    func testGridAutoRowsSetsTheSharedMinimumForEachGeneratedRow() throws {
        let controller = screen(box("root", style: [
            "display": "grid", "gridTemplateColumns": "repeat(2, 1fr)",
            "gridAutoRows": 24, "rowGap": 4, "width": 120, "height": 90
        ], [
            box("first", style: ["height": 8]),
            box("second", style: ["height": 12]),
            box("third", style: ["height": 6]),
            box("fourth", style: ["height": 10]),
        ]), width: 120)
        let first = try frame("first", in: controller)
        let third = try frame("third", in: controller)
        XCTAssertEqual(third.minY - first.minY, 28, accuracy: 1)
    }

    func testNestedGridAutoRowsStayOnTheSharedTreePath() throws {
        let controller = screen(box("root", style: ["width": 120, "height": 100], [
            box("grid", style: [
                "display": "grid", "gridTemplateColumns": "repeat(2, 1fr)",
                "gridAutoRows": 18, "rowGap": 3, "width": 120, "height": 100
            ], [
                box("first", style: ["height": 4]),
                box("second", style: ["height": 6]),
                box("third", style: ["height": 5]),
            ])
        ]), width: 120)
        let first = try frame("first", in: controller)
        let third = try frame("third", in: controller)
        XCTAssertEqual(third.minY - first.minY, 21, accuracy: 1)
    }

    func testExplicitGridRowsStayOnTheSharedTreePath() throws {
        let controller = screen(box("root", style: ["width": 120, "height": 100], [
            box("grid", style: [
                "display": "grid", "gridTemplateColumns": "repeat(2, 1fr)",
                "gridTemplateRows": "repeat(2, 1fr)", "rowGap": 4, "width": 120, "height": 100
            ], [
                box("first", style: ["height": 4]),
                box("second", style: ["height": 6]),
                box("third", style: ["height": 5]),
            ])
        ]), width: 120)
        let first = try frame("first", in: controller)
        let third = try frame("third", in: controller)
        XCTAssertEqual(third.minY - first.minY, 52, accuracy: 1)
    }

    func testANonScrollingFlatListTakesItsRowsHeightInsideAMarginedParent() async throws {
        func row(_ index: Int) -> [String: Any] {
            box("row-\(index)", style: ["flexDirection": "row", "gap": 12, "padding": 12], props: ["listRole": "item", "key": "row-\(index)"], [
                box("icon-\(index)", style: ["width": 32, "height": 32]),
                box("body-\(index)", style: ["flex": 1], [
                    text("title-\(index)", "Interval session with a title long enough to truncate on a phone", props: ["numberOfLines": 1]),
                    text("meta-\(index)", "2h 07m · 23 km"),
                ]),
            ])
        }
        func document(rows: Int) -> [String: Any] {
            box("root", style: ["flex": 1], [[
                "id": "scroll", "type": "ScrollView", "props": ["testID": "scroll"], "style": ["flex": 1],
                "children": [
                    box("wrapper", style: ["marginHorizontal": 16, "padding": 4], [[
                        "id": "list", "type": "FlatList", "props": ["testID": "list", "scrollEnabled": false],
                        "children": [box("header", props: ["listRole": "header", "key": "header"], [text("header-text", "\(rows) sessions")])]
                            + (0..<rows).map(row),
                    ]]),
                    text("after", "After the list"),
                ],
            ]])
        }
        let controller = screen(document(rows: 3))
        await settle(controller)
        let list = try XCTUnwrap(find("list", below: controller.view) as? CraftNativeFlatList)
        XCTAssertFalse(list.isScrollEnabled)
        let listFrame = try frame("list", in: controller)
        XCTAssertEqual(listFrame.minX, 16 + 4, accuracy: 0.5)
        XCTAssertEqual(listFrame.width, 390 - 32 - 8, accuracy: 0.5)
        XCTAssertGreaterThan(listFrame.height, 3 * 44)
        XCTAssertEqual(listFrame.height, list.contentSize.height, accuracy: 1)
        for cell in list.visibleCells {
            XCTAssertEqual(cell.frame.width, listFrame.width, accuracy: 0.5)
        }
        let title = try frame("title-0", in: controller)
        XCTAssertLessThanOrEqual(title.maxX, listFrame.maxX + 0.5)
        XCTAssertGreaterThanOrEqual(try frame("after", in: controller).minY, listFrame.maxY - 0.5)

        // Proposing another width is measurement, not a committed resize.
        // The parent may subtract padding after this intrinsic-size pass.
        let committedFrame = list.frame
        XCTAssertGreaterThan(list.fittingHeight(width: listFrame.width + 80), 0)
        XCTAssertEqual(list.frame, committedFrame)

        // More rows: the header is redrawn and the list grows.
        controller.render(document(rows: 5))
        await settle(controller)
        let header = try XCTUnwrap(find("header-text", below: controller.view) as? UILabel)
        XCTAssertEqual(header.text, "5 sessions")
        XCTAssertEqual(try frame("header", in: controller).width, listFrame.width, accuracy: 0.5)
        XCTAssertGreaterThan(try frame("list", in: controller).height, listFrame.height + 44)

        // Reused cells must self-size at the new constrained width, including
        // while UIKit is invalidating layout before the next layoutSubviews.
        controller.view.frame.size.width = 320
        controller.view.setNeedsLayout()
        await settle(controller)
        let narrower = try frame("list", in: controller)
        XCTAssertEqual(narrower.width, 320 - 32 - 8, accuracy: 0.5)
        for cell in list.visibleCells {
            XCTAssertEqual(cell.frame.width, narrower.width, accuracy: 0.5)
        }
    }

    func testAPlainRootKeepsAnAbsoluteSiblingPinnedBesideItsScrollView() async throws {
        let scroll: [String: Any] = [
            "id": "scroll", "type": "ScrollView", "props": ["testID": "scroll"],
            "style": ["flex": 1],
            "children": (0..<24).map { text("scroll-\($0)", "Overflow row \($0)", style: ["height": 40]) },
        ]
        let controller = screen(box("root", style: ["flex": 1], [
            scroll,
            box("overlay", style: [
                "position": "absolute", "top": 12, "right": 12, "width": 32, "height": 32,
            ]),
        ]))
        await settle(controller)

        let nativeScroll = try XCTUnwrap(find("scroll", below: controller.view) as? UIScrollView)
        let before = try frame("overlay", in: controller)
        XCTAssertGreaterThan(nativeScroll.contentSize.height, nativeScroll.bounds.height)
        nativeScroll.setContentOffset(
            CGPoint(x: 0, y: nativeScroll.contentSize.height - nativeScroll.bounds.height),
            animated: false
        )
        await settle(controller)
        let after = try frame("overlay", in: controller)
        XCTAssertEqual(after.minY, before.minY, accuracy: 1, "absolute sibling followed scroll content")
        XCTAssertEqual(after.maxX, before.maxX, accuracy: 1, "absolute sibling changed horizontal position")
    }

    func testAbsoluteChildrenHonorSizeBoundsAndKeepTheirInsetAnchors() async throws {
        let controller = screen(box("root", style: ["height": 240], [
            ["id": "expand", "type": "Button", "props": ["testID": "expand", "title": "+"],
             "style": ["position": "absolute", "top": 12, "right": 12, "minWidth": 44, "minHeight": 44]],
            box("bounded", style: ["position": "absolute", "right": 12, "bottom": 12, "width": 300, "height": 120, "maxWidth": "50%", "maxHeight": 60]),
            box("wide-ratio", style: ["position": "absolute", "left": 0, "top": 0, "width": 300, "aspectRatio": 2, "maxWidth": 100]),
            box("tall-ratio", style: ["position": "absolute", "left": 110, "top": 0, "height": 120, "aspectRatio": 2, "maxHeight": 60]),
            text("wrapped", "An absolutely positioned label still wraps at its authored maximum width", style: ["position": "absolute", "left": 12, "top": 12, "maxWidth": 80, "fontSize": 17]),
        ]))
        await settle(controller)
        let root = try frame("root", in: controller)
        let expand = try frame("expand", in: controller)
        XCTAssertGreaterThanOrEqual(expand.width, 44)
        XCTAssertEqual(expand.height, 44, accuracy: 0.5, "Floating buttons retain their minimum touch target")
        XCTAssertEqual(expand.maxX, root.maxX - 12, accuracy: 0.5)
        let bounded = try frame("bounded", in: controller)
        XCTAssertEqual(bounded.width, root.width / 2, accuracy: 0.5)
        XCTAssertEqual(bounded.height, 60, accuracy: 0.5)
        XCTAssertEqual(bounded.maxX, root.maxX - 12, accuracy: 0.5)
        XCTAssertEqual(bounded.maxY, root.maxY - 12, accuracy: 0.5)
        let wideRatio = try frame("wide-ratio", in: controller)
        XCTAssertEqual(wideRatio.width, 100, accuracy: 0.5)
        XCTAssertEqual(wideRatio.height, 50, accuracy: 0.5, "An automatic height follows the constrained width")
        let tallRatio = try frame("tall-ratio", in: controller)
        XCTAssertEqual(tallRatio.width, 120, accuracy: 0.5, "An automatic width follows the constrained height")
        XCTAssertEqual(tallRatio.height, 60, accuracy: 0.5)
        let wrapped = try frame("wrapped", in: controller)
        XCTAssertEqual(wrapped.width, 80, accuracy: 0.5)
        XCTAssertGreaterThan(wrapped.height, 44, "Width bounds participate in intrinsic text measurement")
    }

    func testAStyleUpdateIsAppliedInPlaceLayoutIncluded() throws {
        let controller = screen(box("root", style: ["padding": 10], [
            box("grows", style: ["height": 24, "marginHorizontal": 48]),
            text("below", "Below"),
        ]))
        let view = try XCTUnwrap(find("grows", below: controller.view))
        XCTAssertEqual(view.frame.height, 24)
        XCTAssertEqual(view.frame.width, 390 - 20 - 96, accuracy: 0.5)
        let belowBefore = try frame("below", in: controller).minY

        try controller.applyMutation([
            "version": 1, "batchId": "style-1", "baseRevision": 0, "revision": 1,
            "operations": [["op": "updateNode", "id": "grows", "patch": ["style": ["height": 60, "marginHorizontal": 0, "borderRadius": 9999]]]],
        ])
        controller.view.layoutIfNeeded()
        XCTAssertTrue(view === find("grows", below: controller.view))
        XCTAssertEqual(view.frame.height, 60)
        XCTAssertEqual(view.frame.width, 390 - 20, accuracy: 0.5)
        XCTAssertEqual(view.layer.cornerRadius, 30)
        XCTAssertEqual(try frame("below", in: controller).minY, belowBefore + 36, accuracy: 0.5)
    }

    func testInsertedChildrenAreLaidOutInTheirPlaceNotAppended() throws {
        let controller = screen(box("root", style: ["flex": 1], [[
            "id": "scroll", "type": "ScrollView", "props": ["testID": "scroll"], "style": ["flex": 1],
            "children": [text("first", "First"), text("second", "Second"), text("footer", "Updated just now")],
        ]]))
        let operations: [[String: Any]] = (0..<3).flatMap { index -> [[String: Any]] in [
            ["op": "createNode", "id": "new-\(index)", "node": ["type": "Text", "props": ["testID": "new-\(index)"], "children": ["New \(index)"]]],
            ["op": "insertChild", "parentId": "scroll", "childId": "new-\(index)", "index": 2 + index],
        ] }
        try controller.applyMutation(["version": 1, "batchId": "insert-1", "baseRevision": 0, "revision": 1, "operations": operations])
        controller.view.layoutIfNeeded()
        let order = ["first", "second", "new-0", "new-1", "new-2", "footer"]
        let tops = try order.map { try frame($0, in: controller).minY }
        XCTAssertEqual(tops, tops.sorted(), "children laid out as \(zip(order, tops).map { "\($0)=\($1)" })")
        XCTAssertGreaterThan(tops[5], tops[4])
    }

    func testIconIsATintedSymbol() throws {
        let controller = screen(box("root", style: ["flexDirection": "row"], [
            ["id": "sun", "type": "Icon", "props": ["testID": "sun", "symbol": "sun.max"], "style": ["width": 20, "height": 20, "color": "#ff0000", "fontWeight": "600"]],
            ["id": "typo", "type": "Icon", "props": ["testID": "typo", "symbol": "not.a.symbol"], "style": ["fontSize": 17]],
        ]))
        let sun = try XCTUnwrap(find("sun", below: controller.view) as? UIImageView)
        XCTAssertNotNil(sun.image)
        XCTAssertTrue(sun.image?.isSymbolImage == true)
        XCTAssertEqual(sun.tintColor, UIColor(red: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(sun.frame.size, CGSize(width: 20, height: 20))
        let typo = try XCTUnwrap(find("typo", below: controller.view) as? UIImageView)
        XCTAssertNotNil(typo.image, "an unknown symbol falls back to circle")
        XCTAssertGreaterThan(typo.frame.width, 0)
    }

    func testSynchronousStorageSnapshotsAndSecureStorageBeforeTheFirstRender() throws {
        var config = CraftConfig()
        config.enableSecureStorage = true
        let controller = screen(box("root"), config: config)

        // JavaScriptCore has no DOM window, but browser-safe SDK bridges use
        // window.craft. The native prelude supplies that compatibility alias.
        XCTAssertTrue(controller.evaluateScript("window === globalThis")?.toBool() == true)

        // The runtime assigns craft.storage after the host installs it; the
        // synchronous calls survive that.
        controller.evaluateScript("globalThis.craft.storage = { get: function() {} };")
        XCTAssertEqual(controller.evaluateScript("typeof craft.storage.getSync")?.toString(), "function")
        XCTAssertEqual(controller.evaluateScript("typeof craft.storage.get")?.toString(), "function")

        controller.evaluateScript("craft.storage.setSync('layout.test', { visits: 2 })")
        XCTAssertEqual(controller.evaluateScript("craft.storage.getSync('layout.test').visits")?.toInt32(), 2)
        XCTAssertEqual(try CraftNativeActions.storageJSON(forKey: "layout.test"), "{\"visits\":2}")
        let corruptKey = "corrupt-checkpoint-" + UUID().uuidString
        UserDefaults.standard.set(Data("not JSON".utf8), forKey: "craft.native.storage." + corruptKey)
        defer { UserDefaults.standard.removeObject(forKey: "craft.native.storage." + corruptKey) }
        XCTAssertTrue(controller.evaluateScript("(function() { try { craft.storage.getSync('\(corruptKey)'); return false; } catch (error) { return error.message.indexOf('STORAGE_ERROR') !== -1; } })()")?.toBool() == true)
        controller.evaluateScript("craft.storage.setSync('layout.test', null)")
        XCTAssertTrue(controller.evaluateScript("craft.storage.getSync('layout.test') === null")?.toBool() == true)

        controller.evaluateScript("craft.snapshots.set('layout-test', { at: 'now', rows: [1, 2] })")
        XCTAssertTrue(waitForSnapshotFile("layout-test"))
        XCTAssertEqual(controller.evaluateScript("craft.snapshots.get('layout-test').rows.length")?.toInt32(), 2)
        let file = try XCTUnwrap(CraftSnapshots.url(for: "layout-test"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(file.path.hasSuffix("Application Support/craft-snapshots/layout-test.json"))
        XCTAssertTrue(controller.evaluateScript("craft.snapshots.get('../escape') === null")?.toBool() == true)
        CraftSnapshots.write("layout-test", json: nil)

        // The web page's secureStorage.set writes a generic password whose
        // account is the key.
        let account = "layout.test.token"
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        // Written and deleted behind secure storage's back, so the test
        // forgets what it changed, as every writer does (CraftKeychain).
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data("secret-token".utf8)
        let added = SecItemAdd(item as CFDictionary, nil)
        CraftKeychain.forget(account: account)
        // An unsigned simulator test host has no Keychain entitlement.
        if added != errSecMissingEntitlement {
            XCTAssertEqual(added, errSecSuccess)
            XCTAssertEqual(controller.evaluateScript("craft.secureStorage.getSync('\(account)')")?.toString(), "secret-token")
            SecItemDelete(base as CFDictionary)
            CraftKeychain.forget(account: account)
        }
        XCTAssertTrue(controller.evaluateScript("craft.secureStorage.getSync('\(account)') === null")?.toBool() == true)

        XCTAssertEqual(controller.evaluateScript("typeof console.log + typeof console.error")?.toString(), "functionfunction")
        controller.evaluateScript("console.log('layout test', { ok: true }, undefined); console.error(new Error('logged'))")
    }

    func testSharedAccountAndChatButtonsKeepTheirOwnSurfacesAndBadges() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()
        controller.evaluateScript("""
            craft.navigation.setOptions({title: 'Today', largeTitle: true, rightButtons: [
                {id: 'messages', symbol: 'bubble.left', variant: 'accent', badge: 3, accessibilityLabel: 'Messages'},
                {id: 'me', title: 'CB', variant: 'account', badge: 1, badgeStyle: 'dot', accessibilityLabel: 'Me'}
            ]});
        """)
        let items = try XCTUnwrap(controller.navigationItem.rightBarButtonItems)
        let buttons = items.compactMap { $0.customView as? UIButton }
        XCTAssertEqual(buttons.count, 2)
        let chat = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "messages" })
        let account = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "me" })
        XCTAssertEqual(chat.accessibilityValue, "3 unread")
        XCTAssertEqual(account.title(for: .normal), "CB")
        XCTAssertEqual(account.accessibilityLabel, "Me")
        // Each floats on its own round surface (glass on iOS 26, the thin
        // material before it), under its symbol or initials and its badge.
        for button in [chat, account] {
            let surface = try XCTUnwrap(button.subviews.first { $0 is UIVisualEffectView })
            XCTAssertEqual(surface.layer.cornerRadius, 22)
            XCTAssertFalse(surface.isUserInteractionEnabled)
            XCTAssertEqual(button.subviews.filter { $0 is UIVisualEffectView }.count, 1)
            let width = try XCTUnwrap(button.constraints.first { $0.firstAttribute == .width })
            let height = try XCTUnwrap(button.constraints.first { $0.firstAttribute == .height })
            XCTAssertEqual(width.constant, 44)
            XCTAssertEqual(height.constant, 44)
        }
        XCTAssertTrue(items.allSatisfy { $0.customView is UIButton })
    }

    func testJSONNumbersZeroAndOneKeepTheConversationComposerAtTheBottom() async throws {
        // The bridge parses JSON, which boxes 0 and 1 as NSNumber. Swift's
        // `is Bool` also matches those numeric boxes; authored Swift Ints do
        // not reproduce the installed app's lost flex factors.
        let data = Data(#"""
        {"type":"View","props":{"testID":"root"},"style":{"flex":1},"children":[
          {"type":"ScrollView","props":{"testID":"thread"},"style":{"flex":1,"flexBasis":0},"children":[
            {"type":"Text","children":["A short conversation"]}
          ]},
          {"type":"View","props":{"testID":"composer"},"style":{"flexDirection":"row","padding":12,"gap":8},"children":[
            {"type":"TextInput","props":{"testID":"draft","multiline":true,"placeholder":"Message"},"style":{"flex":1,"flexBasis":0,"minHeight":36}},
            {"type":"View","props":{"testID":"send"},"style":{"width":36,"height":36}}
          ]}
        ]}
        """#.utf8)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let controller = screen(document)
        await settle(controller)
        let root = try frame("root", in: controller)
        let composer = try frame("composer", in: controller)
        let thread = try frame("thread", in: controller)
        let draft = try frame("draft", in: controller)
        XCTAssertEqual(composer.maxY, root.maxY, accuracy: 1)
        XCTAssertEqual(thread.maxY, composer.minY, accuracy: 1)
        XCTAssertGreaterThan(thread.height, 600)
        XCTAssertGreaterThan(draft.width, 300)
        XCTAssertEqual(try frame("send", in: controller).width, 36, accuracy: 1)
    }

    func testNestedGroupedConversationKeepsItsViewportAfterAStyleUpdate() async throws {
        let controller = screen(box("root", [
            box("chrome", style: ["height": 0]),
            box("screen", style: ["flex": 1], [
                box("group", style: ["flex": 1, "backgroundColor": "#f2f2f7"], [
                    ["id": "thread", "type": "ScrollView", "props": ["testID": "thread"], "style": ["flex": 1, "flexBasis": 0], "children": [text("intro", "Your coach is ready")]],
                    box("composer", style: ["padding": 12], [text("draft", "Ask your coach")]),
                ]),
            ]),
        ]))
        await settle(controller)
        XCTAssertGreaterThan(try frame("thread", in: controller).height, 600)
        XCTAssertEqual(try frame("composer", in: controller).maxY, controller.view.bounds.height, accuracy: 1)
        try controller.applyMutation([
            "version": 1, "batchId": "appearance", "baseRevision": 0, "revision": 1,
            "operations": [["op": "updateNode", "id": "group", "patch": ["style": ["flex": 1, "backgroundColor": "#000000"]]]],
        ])
        await settle(controller)
        XCTAssertGreaterThan(try frame("thread", in: controller).height, 600)
        XCTAssertEqual(try frame("composer", in: controller).maxY, controller.view.bounds.height, accuracy: 1)
    }

    func testNumericNavigationBadgeOneSurvivesTheJSONBridge() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.evaluateScript("craft.navigation.setOptions({ rightButtons: [{ id: 'one', symbol: 'bell', variant: 'accent', badge: 1 }] });")
        let button = try XCTUnwrap(controller.navigationItem.rightBarButtonItems?.first?.customView as? UIButton)
        XCTAssertEqual(button.accessibilityValue, "1 unread")
    }

    func testBooleanNavigationBadgeIsIgnored() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()
        controller.evaluateScript("craft.navigation.setOptions({ rightButtons: [{ id: 'boolean-badge', symbol: 'bell', variant: 'accent', badge: true }] });")

        let button = try XCTUnwrap(controller.navigationItem.rightBarButtonItems?.first?.customView as? UIButton)
        XCTAssertNil(button.accessibilityValue)
        XCTAssertFalse(button.subviews.compactMap { ($0 as? UILabel)?.text }.contains("1"), "Boolean badge was treated as a numeric unread count")
    }

    func testNavigationOptionsSetTheBarAndTheRootTitleIsNeverUndefined() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()
        XCTAssertNotEqual(controller.navigationItem.title, "undefined")

        controller.evaluateScript("""
            craft.navigation = { push: function() {} };
            craft.navigation.setOptions({
                title: 'Today', largeTitle: true, backTitle: 'Back',
                leftButtons: [{ id: 'calendar', symbol: 'calendar', variant: 'neutral', accessibilityLabel: 'Calendar' }],
                rightButtons: [{ id: 'add', symbol: 'plus' }, { id: 'edit', title: 'Edit' }]
            });
        """)
        XCTAssertEqual(controller.navigationItem.title, "Today")
        XCTAssertEqual(controller.navigationItem.largeTitleDisplayMode, .always)
        XCTAssertTrue(navigation.navigationBar.prefersLargeTitles)
        XCTAssertEqual(controller.navigationItem.backButtonTitle, "Back")
        let buttons = controller.navigationItem.rightBarButtonItems ?? []
        XCTAssertEqual(buttons.count, 2)
        XCTAssertEqual(Set(buttons.compactMap(\.accessibilityIdentifier)), ["nav-add", "nav-edit"])
        let calendar = try XCTUnwrap(controller.navigationItem.leftBarButtonItems?.first)
        XCTAssertEqual(calendar.accessibilityIdentifier, "nav-calendar")
        XCTAssertEqual(calendar.accessibilityLabel, "Calendar")
        XCTAssertEqual(calendar.tintColor, UIColor.label)
        XCTAssertTrue(controller.navigationItem.leftItemsSupplementBackButton)

        controller.evaluateScript("craft.navigation.setOptions({ hidden: true, rightButtons: [] })")
        XCTAssertTrue(navigation.isNavigationBarHidden)
        XCTAssertEqual(controller.navigationItem.rightBarButtonItems?.count ?? 0, 0)
        XCTAssertEqual(controller.navigationItem.title, "Today")
    }

    func testNavigationBarSolidUsesTheScreenColourAndCanReset() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()

        controller.evaluateScript("craft.navigation.setOptions({ title: 'Solid', largeTitle: true, backgroundColor: '#123456', navigationBarSolid: true })")
        XCTAssertEqual(controller.navigationItem.largeTitleDisplayMode, .always)
        XCTAssertTrue(navigation.navigationBar.prefersLargeTitles)
        let solid = try XCTUnwrap(controller.navigationItem.standardAppearance)
        let appearances = [
            solid,
            try XCTUnwrap(controller.navigationItem.scrollEdgeAppearance),
            try XCTUnwrap(controller.navigationItem.compactAppearance),
            try XCTUnwrap(controller.navigationItem.compactScrollEdgeAppearance),
        ]
        for appearance in appearances {
            XCTAssertNil(appearance.backgroundEffect)
            // UIKit may normalize clear to nil; both mean no shadow.
            XCTAssertEqual(appearance.shadowColor?.cgColor.alpha ?? 0, 0)
            XCTAssertNil(appearance.shadowImage)
            try assertColor(appearance.backgroundColor, red: 0x12 / 255, green: 0x34 / 255, blue: 0x56 / 255)
        }

        // The same fill remains attached when a screen opts out of the large
        // title layout; UIKit must not fall back to its translucent scroll-edge
        // material just because the title collapsed.
        controller.evaluateScript("craft.navigation.setOptions({ largeTitle: false })")
        XCTAssertEqual(controller.navigationItem.largeTitleDisplayMode, .never)
        XCTAssertNotNil(controller.navigationItem.scrollEdgeAppearance)

        controller.evaluateScript("craft.navigation.setOptions({ navigationBarSolid: false })")
        XCTAssertNil(controller.navigationItem.standardAppearance)
        XCTAssertNil(controller.navigationItem.scrollEdgeAppearance)
        XCTAssertNil(controller.navigationItem.compactAppearance)
        XCTAssertNil(controller.navigationItem.compactScrollEdgeAppearance)
    }

    func testNavigationBarSolidTracksDynamicConfigColours() throws {
        var config = CraftConfig()
        config.backgroundColor = "#ffffff"
        config.backgroundColorDark = "#101820"
        let controller = CraftNativeScreenController(config: config)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()

        controller.evaluateScript("craft.navigation.setOptions({ navigationBarSolid: true })")
        let appearance = try XCTUnwrap(controller.navigationItem.standardAppearance)
        let light = try XCTUnwrap(appearance.backgroundColor).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = try XCTUnwrap(appearance.backgroundColor).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        try assertColor(light, red: 1, green: 1, blue: 1)
        try assertColor(dark, red: 0x10 / 255, green: 0x18 / 255, blue: 0x20 / 255)
    }

    func testNavigationBarSolidReappliesAfterAnAppearanceChange() throws {
        var config = CraftConfig()
        config.backgroundColor = "#ffffff"
        config.backgroundColorDark = "#101820"
        let controller = CraftNativeScreenController(config: config)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()

        controller.evaluateScript("craft.navigation.setOptions({ navigationBarSolid: true })")
        controller.navigationItem.standardAppearance = nil
        controller.overrideUserInterfaceStyle = .dark
        controller.traitCollectionDidChange(UITraitCollection(userInterfaceStyle: .light))

        let appearance = try XCTUnwrap(controller.navigationItem.standardAppearance)
        let dark = try XCTUnwrap(appearance.backgroundColor).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        try assertColor(dark, red: 0x10 / 255, green: 0x18 / 255, blue: 0x20 / 255)
    }

    func testNavigationBarSolidReappliesWhenScreenReappears() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()

        controller.evaluateScript("craft.navigation.setOptions({ backgroundColor: '#123456', navigationBarSolid: true })")
        controller.navigationItem.standardAppearance = nil
        controller.navigationItem.scrollEdgeAppearance = nil
        controller.navigationItem.compactAppearance = nil
        controller.navigationItem.compactScrollEdgeAppearance = nil

        // UIKit can discard the item appearances while a push/pop or tab
        // swipe is settling. The next appearance must restore every slot.
        controller.viewWillAppear(false)

        let appearances = [
            try XCTUnwrap(controller.navigationItem.standardAppearance),
            try XCTUnwrap(controller.navigationItem.scrollEdgeAppearance),
            try XCTUnwrap(controller.navigationItem.compactAppearance),
            try XCTUnwrap(controller.navigationItem.compactScrollEdgeAppearance),
        ]
        for appearance in appearances {
            XCTAssertNil(appearance.backgroundEffect)
            XCTAssertEqual(appearance.shadowColor?.cgColor.alpha ?? 0, 0)
            try assertColor(appearance.backgroundColor, red: 0x12 / 255, green: 0x34 / 255, blue: 0x56 / 255)
        }
    }

    func testAProgressFillTakesItsShareOnceItsGrowArrives() async throws {
        // HQ's week bar: the shares arrive as a style binding after the first
        // render, 78 to the fill and 22 to the rest of the track.
        let controller = screen(box("root", style: ["flex": 1], [[
            "id": "scroll", "type": "ScrollView", "props": ["testID": "scroll"], "style": ["flex": 1],
            "children": [
                box("card", style: ["marginHorizontal": 16, "padding": 16, "borderRadius": 16], [
                    text("label", "3 / 5 sessions"),
                    box("track", style: ["flexDirection": "row", "overflow": "hidden", "marginTop": 12, "height": 8, "borderRadius": 9999], [
                        box("fill", style: ["height": 8, "backgroundColor": "#2563eb", "borderRadius": 9999]),
                        box("rest", style: ["height": 8]),
                    ]),
                ]),
            ],
        ]]))
        XCTAssertEqual(try frame("fill", in: controller).width, 0, accuracy: 0.5)
        try controller.applyMutation([
            "version": 1, "batchId": "grow-1", "baseRevision": 0, "revision": 1,
            "operations": [
                ["op": "updateNode", "id": "fill", "patch": ["style": ["flexGrow": 78, "flexShrink": 1, "flexBasis": 0]]],
                ["op": "updateNode", "id": "rest", "patch": ["style": ["flexGrow": 22, "flexShrink": 1, "flexBasis": 0]]],
            ],
        ])
        await settle(controller)
        let track = try frame("track", in: controller)
        XCTAssertEqual(track.width, 390 - 32 - 32, accuracy: 0.5)
        XCTAssertEqual(try frame("fill", in: controller).width, track.width * 0.78, accuracy: 1)
        XCTAssertEqual(try frame("rest", in: controller).minX, track.minX + track.width * 0.78, accuracy: 1)
    }

    /// A Calendar-like screen: a large title over a scroll view whose first
    /// child, the week strip, sticks under the bar.
    private func stickyHeaderScreen() -> [String: Any] {
        box("root", style: ["flex": 1], [[
            "id": "scroll", "type": "ScrollView", "props": ["testID": "scroll", "stickyHeaderIndices": [0]], "style": ["flex": 1],
            "children": [
                box("week", style: ["height": 120, "backgroundColor": "#f8fafc"]),
                box("summary", style: ["height": 100, "marginTop": 4, "backgroundColor": "#ffffff"]),
                box("monday", style: ["height": 600]),
            ],
        ]])
    }

    /// As Craft's hybrid shell shows a tab: the bar hidden until the screen
    /// asks for one, in a window, with the screen's first render before or
    /// after it appears.
    private func largeTitleScreen(renderFirst: Bool) async throws -> (CraftNativeScreenController, UINavigationController, UIWindow) {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let navigation = UINavigationController(rootViewController: controller)
        navigation.setNavigationBarHidden(true, animated: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.loadViewIfNeeded()
        controller.evaluateScript("craft.navigation.setOptions({ title: 'Calendar', largeTitle: true })")
        if renderFirst { controller.render(stickyHeaderScreen()) }
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        await settle(controller)
        if !renderFirst { controller.render(stickyHeaderScreen()) }
        await settle(controller)
        return (controller, navigation, window)
    }

    private func assertContentStartsBelowTheBar(_ controller: CraftNativeScreenController, _ navigation: UINavigationController) async throws {
        let bar = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: controller.view)
        let week = try frame("week", in: controller)
        let summary = try frame("summary", in: controller)
        let scroll = try XCTUnwrap(find("scroll", below: controller.view) as? UIScrollView)
        XCTAssertGreaterThanOrEqual(week.minY, bar.maxY - 0.5, "the week strip starts below the large title")
        XCTAssertEqual(summary.minY, week.maxY + 4, accuracy: 0.5, "the summary follows the strip, not under it")
        XCTAssertEqual(scroll.contentOffset.y, -scroll.adjustedContentInset.top, accuracy: 0.5)

        // Scrolled, the strip sticks under the bar, drawn over the content.
        scroll.setContentOffset(CGPoint(x: 0, y: 300 - scroll.adjustedContentInset.top), animated: false)
        await settle(controller)
        let stuck = try frame("week", in: controller)
        let collapsed = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: controller.view)
        XCTAssertEqual(stuck.minY, collapsed.maxY, accuracy: 1)
        let weekView = try XCTUnwrap(find("week", below: controller.view))
        XCTAssertTrue(weekView.superview?.subviews.last === weekView)
        XCTAssertGreaterThan(weekView.layer.zPosition, 0)
    }

    func testALargeTitleScreenRenderedBeforeItAppearsStartsBelowTheBar() async throws {
        let (controller, navigation, window) = try await largeTitleScreen(renderFirst: true)
        defer { window.isHidden = true }
        try await assertContentStartsBelowTheBar(controller, navigation)
    }

    func testALargeTitleScreenRenderedAfterItAppearsStartsBelowTheBar() async throws {
        // The first render switches the screen edge to edge under a bar that
        // is already showing: the scroll view's inset grows from nothing
        // while it rests at the top.
        let (controller, navigation, window) = try await largeTitleScreen(renderFirst: false)
        defer { window.isHidden = true }
        try await assertContentStartsBelowTheBar(controller, navigation)
    }
}
