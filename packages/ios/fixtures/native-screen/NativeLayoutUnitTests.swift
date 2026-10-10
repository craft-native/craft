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

    private func settle(_ controller: CraftNativeScreenController) {
        for _ in 0..<4 {
            let settled = expectation(description: "layout settled")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { settled.fulfill() }
            wait(for: [settled], timeout: 1)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }
    }

    private func waitForJavaScript(
        _ controller: CraftNativeScreenController,
        _ expression: String,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if controller.evaluateScript(expression)?.toBool() == true { return true }
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

    func testButtonHonoursAlignSelfStretch() throws {
        let controller = screen(box("root", style: ["padding": 16, "alignItems": "center"], [
            ["id": "start", "type": "Button", "props": ["testID": "start"], "style": ["height": 44, "alignSelf": "stretch"], "children": ["Start"]],
            ["id": "small", "type": "Button", "props": ["testID": "small"], "style": ["height": 44], "children": ["Small"]],
        ]))
        XCTAssertEqual(try frame("start", in: controller).width, 390 - 32, accuracy: 0.5)
        XCTAssertLessThan(try frame("small", in: controller).width, 200)
    }

    func testANonScrollingFlatListTakesItsRowsHeightInsideAMarginedParent() throws {
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
        settle(controller)
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

        // More rows: the header is redrawn and the list grows.
        controller.render(document(rows: 5))
        settle(controller)
        let header = try XCTUnwrap(find("header-text", below: controller.view) as? UILabel)
        XCTAssertEqual(header.text, "5 sessions")
        XCTAssertEqual(try frame("header", in: controller).width, listFrame.width, accuracy: 0.5)
        XCTAssertGreaterThan(try frame("list", in: controller).height, listFrame.height + 44)
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

        // The runtime assigns craft.storage after the host installs it; the
        // synchronous calls survive that.
        controller.evaluateScript("globalThis.craft.storage = { get: function() {} };")
        XCTAssertEqual(controller.evaluateScript("typeof craft.storage.getSync")?.toString(), "function")
        XCTAssertEqual(controller.evaluateScript("typeof craft.storage.get")?.toString(), "function")

        controller.evaluateScript("craft.storage.setSync('layout.test', { visits: 2 })")
        XCTAssertEqual(controller.evaluateScript("craft.storage.getSync('layout.test').visits")?.toInt32(), 2)
        XCTAssertEqual(CraftNativeActions.storageJSON(forKey: "layout.test"), "{\"visits\":2}")
        controller.evaluateScript("craft.storage.setSync('layout.test', null)")
        XCTAssertTrue(controller.evaluateScript("craft.storage.getSync('layout.test') === null")?.toBool() == true)

        let written = expectation(description: "snapshot written")
        controller.evaluateScript("craft.snapshots.set('layout-test', { at: 'now', rows: [1, 2] }).then(function() { globalThis.snapshotWritten = true })")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { written.fulfill() }
        wait(for: [written], timeout: 2)
        XCTAssertTrue(waitForJavaScript(controller, "globalThis.snapshotWritten === true"))
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
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data("secret-token".utf8)
        let added = SecItemAdd(item as CFDictionary, nil)
        // An unsigned simulator test host has no Keychain entitlement.
        if added != errSecMissingEntitlement {
            XCTAssertEqual(added, errSecSuccess)
            XCTAssertEqual(controller.evaluateScript("craft.secureStorage.getSync('\(account)')")?.toString(), "secret-token")
            SecItemDelete(base as CFDictionary)
        }
        XCTAssertTrue(controller.evaluateScript("craft.secureStorage.getSync('\(account)') === null")?.toBool() == true)

        XCTAssertEqual(controller.evaluateScript("typeof console.log + typeof console.error")?.toString(), "functionfunction")
        controller.evaluateScript("console.log('layout test', { ok: true }, undefined); console.error(new Error('logged'))")
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

        controller.evaluateScript("craft.navigation.setOptions({ hidden: true, rightButtons: [] })")
        XCTAssertTrue(navigation.isNavigationBarHidden)
        XCTAssertEqual(controller.navigationItem.rightBarButtonItems?.count ?? 0, 0)
        XCTAssertEqual(controller.navigationItem.title, "Today")
    }
}
