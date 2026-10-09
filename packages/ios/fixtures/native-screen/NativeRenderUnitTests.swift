import UIKit
import XCTest
@testable import NativeRender

@MainActor
final class NativeRenderUnitTests: XCTestCase {
    private func capability(
        _ module: String,
        _ method: String,
        _ args: [Any] = [],
        config: CraftConfig = CraftConfig()
    ) async -> Result<Any, CraftNativeActionError> {
        await withCheckedContinuation { continuation in
            CraftNativeActions.perform(
                requestToken: UUID().uuidString,
                version: craftNativeCapabilityProtocolVersion,
                module: module,
                method: method,
                args: args,
                config: config
            ) { continuation.resume(returning: $0) }
        }
    }

    private func batch(
        _ revision: Int,
        _ operations: [[String: Any]],
        version: Int = 1,
        baseRevision: Int? = nil
    ) -> [String: Any] {
        [
            "version": version,
            "batchId": "batch-\(revision)",
            "baseRevision": baseRevision ?? revision - 1,
            "revision": revision,
            "operations": operations,
        ]
    }

    private func node(_ type: String, key: String, text: String? = nil, style: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["type": type, "props": ["key": key], "style": style]
        if let text = text { result["children"] = [text] }
        return result
    }

    private func document(_ children: [[String: Any]]) -> [String: Any] {
        ["type": "View", "children": children]
    }

    private func find<T: UIView>(_ type: T.Type, key: String, below view: UIView) -> T? {
        if let match = view as? T, match.accessibilityIdentifier == key { return match }
        for child in view.subviews {
            if let match = find(type, key: key, below: child) { return match }
        }
        return nil
    }

    func testKeyedViewsKeepIdentityAcrossUpdatesAndMoves() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([
            node("Text", key: "count", text: "Count: 0"),
            node("Button", key: "increment", text: "Increment"),
            node("TextInput", key: "name-input", style: ["width": 140]),
            node("Text", key: "name", text: "Hello"),
        ]))

        let field = try XCTUnwrap(find(UITextField.self, key: "name-input", below: controller.view))
        let count = try XCTUnwrap(find(UILabel.self, key: "count", below: controller.view))
        let button = try XCTUnwrap(find(UIButton.self, key: "increment", below: controller.view))
        field.text = "Ada"
        let caret = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 2))
        field.selectedTextRange = field.textRange(from: caret, to: caret)

        controller.render(document([
            node("Text", key: "count", text: "Count: 1"),
            node("Button", key: "increment", text: "Again"),
            node("TextInput", key: "name-input", style: ["width": 180]),
            node("Text", key: "name", text: "Hello Ada"),
        ]))
        XCTAssertTrue(field === find(UITextField.self, key: "name-input", below: controller.view))
        XCTAssertTrue(count === find(UILabel.self, key: "count", below: controller.view))
        XCTAssertTrue(button === find(UIButton.self, key: "increment", below: controller.view))
        XCTAssertEqual(field.text, "Ada")
        let selection = try XCTUnwrap(field.selectedTextRange)
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: selection.start), 2)
        XCTAssertEqual(count.text, "Count: 1")
        XCTAssertEqual(button.title(for: .normal), "Again")
        XCTAssertEqual(field.constraints.first(where: { $0.firstAttribute == .width && $0.isActive })?.constant, 180)

        controller.render(document([
            node("TextInput", key: "name-input"),
            node("Text", key: "count", text: "Count: 2"),
            node("Button", key: "increment", text: "Again"),
        ]))
        XCTAssertTrue(field === find(UITextField.self, key: "name-input", below: controller.view))
        let root = try XCTUnwrap(find(UIStackView.self, key: "root", below: controller.view))
        XCTAssertTrue(root.arrangedSubviews.first === field)
        XCTAssertFalse(field.constraints.contains(where: { $0.firstAttribute == .width && $0.isActive }))

        controller.render(document([node("Text", key: "name-input", text: "Replaced")]))
        XCTAssertNil(field.superview)
        XCTAssertNotNil(find(UILabel.self, key: "name-input", below: controller.view))
    }

    func testTextInputTraitsFollowHostNeutralProps() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([
            [
                "type": "TextInput",
                "props": [
                    "key": "single",
                    "keyboardType": "email-address",
                    "returnKeyType": "done",
                    "autoCapitalize": "characters",
                    "autoCorrect": false,
                    "secureTextEntry": true,
                    "editable": false,
                ],
            ],
            [
                "type": "TextInput",
                "props": [
                    "key": "multi",
                    "multiline": true,
                    "keyboardType": "decimal-pad",
                    "returnKeyType": "send",
                    "autoCapitalize": "words",
                ],
            ],
        ]))

        let single = try XCTUnwrap(find(UITextField.self, key: "single", below: controller.view))
        XCTAssertEqual(single.keyboardType, .emailAddress)
        XCTAssertEqual(single.returnKeyType, .done)
        XCTAssertEqual(single.autocapitalizationType, .allCharacters)
        XCTAssertEqual(single.autocorrectionType, .no)
        XCTAssertTrue(single.isSecureTextEntry)
        XCTAssertFalse(single.isEnabled)

        let multi = try XCTUnwrap(find(UITextView.self, key: "multi", below: controller.view))
        XCTAssertEqual(multi.keyboardType, .decimalPad)
        XCTAssertEqual(multi.returnKeyType, .send)
        XCTAssertEqual(multi.autocapitalizationType, .words)
        XCTAssertEqual(multi.autocorrectionType, .default)
    }

    func testPersistentStorageAndDatabaseCapabilitiesRoundTripJSONValues() async throws {
        _ = await capability("Storage", "clear")
        let stored = await capability("Storage", "set", ["profile", ["name": "Ada", "visits": 2]])
        guard case .success = stored else { return XCTFail("storage set failed") }
        guard case .success(let value) = await capability("Storage", "get", ["profile"]),
              let profile = value as? [String: Any] else { return XCTFail("storage get failed") }
        XCTAssertEqual(profile["name"] as? String, "Ada")
        XCTAssertEqual(profile["visits"] as? Int, 2)

        var config = CraftConfig()
        config.enableLocalDatabase = true
        let table = "capability_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        guard case .success = await capability("Database", "execute", [
            "CREATE TABLE \(table) (id INTEGER PRIMARY KEY, name TEXT NOT NULL)", [],
        ], config: config) else { return XCTFail("database create failed") }
        guard case .success = await capability("Database", "beginTransaction", [], config: config) else {
            return XCTFail("database transaction failed")
        }
        _ = await capability("Database", "execute", ["INSERT INTO \(table) (name) VALUES (?)", ["Grace"]], config: config)
        _ = await capability("Database", "commit", [], config: config)
        guard case .success(let rows) = await capability("Database", "query", [
            "SELECT name FROM \(table)", [],
        ], config: config), let first = (rows as? [[String: Any]])?.first else {
            return XCTFail("database query failed")
        }
        XCTAssertEqual(first["name"] as? String, "Grace")
    }

    func testUnkeyedChildrenReusePositionAndRemovedChildrenDetach() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([
            ["type": "Text", "children": ["First"]],
            ["type": "Text", "children": ["Second"]],
        ]))
        let first = try XCTUnwrap(find(UILabel.self, key: "root.0", below: controller.view))
        let second = try XCTUnwrap(find(UILabel.self, key: "root.1", below: controller.view))
        controller.render(document([["type": "Text", "children": ["Updated"]]]))
        XCTAssertTrue(first === find(UILabel.self, key: "root.0", below: controller.view))
        XCTAssertEqual(first.text, "Updated")
        XCTAssertNil(second.superview)
    }

    func testImageAndScrollViewAreNativeAccessibleAndStable() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        let pixel = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let image: [String: Any] = [
            "type": "Image",
            "props": ["key": "avatar", "source": ["uri": pixel], "accessibilityLabel": "Profile photo", "accessibilityRole": "image"],
            "style": ["width": 24, "height": 24, "resizeMode": "cover"]
        ]
        let scroll: [String: Any] = [
            "type": "ScrollView", "props": ["key": "feed"], "style": ["height": 80, "gap": 6],
            "children": [image, node("Text", key: "caption", text: "Native content")]
        ]
        controller.render(document([scroll]))

        let scrollView = try XCTUnwrap(find(UIScrollView.self, key: "feed", below: controller.view))
        let imageView = try XCTUnwrap(find(UIImageView.self, key: "avatar", below: controller.view))
        XCTAssertNotNil(imageView.image)
        XCTAssertEqual(imageView.accessibilityLabel, "Profile photo")
        XCTAssertTrue(imageView.accessibilityTraits.contains(.image))
        XCTAssertEqual(imageView.contentMode, .scaleAspectFill)

        controller.render(document([scroll]))
        XCTAssertTrue(scrollView === find(UIScrollView.self, key: "feed", below: controller.view))
        XCTAssertTrue(imageView === find(UIImageView.self, key: "avatar", below: controller.view))
    }

    func testHeaderAccessibilityRoleMapsToUIKitTrait() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([[
            "type": "Text",
            "props": ["key": "header", "accessibilityRole": "header"],
            "children": ["People directory"],
        ]]))

        let header = try XCTUnwrap(find(UILabel.self, key: "header", below: controller.view))
        XCTAssertTrue(header.accessibilityTraits.contains(.header))
    }

    func testSharedLayoutColorAndTextStylesMapToUIKit() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        let first = node("Text", key: "first", text: "first", style: [
            "color": "#123456", "fontSize": 21, "fontWeight": "700", "fontStyle": "italic",
            "textAlign": "right", "letterSpacing": 2, "lineHeight": 28, "textTransform": "uppercase",
            "textDecorationLine": "underline"
        ])
        let second = node("Text", key: "second", text: "second")
        controller.render(document([[
            "type": "View", "props": ["key": "styled"],
            "style": [
                "flexDirection": "row-reverse", "alignItems": "center", "justifyContent": "center",
                "gap": 7, "paddingHorizontal": 11, "paddingVertical": 5,
                "width": 240, "height": 80, "backgroundColor": "#abcdef", "opacity": 0.75,
                "borderWidth": 3, "borderColor": "#654321", "borderRadius": 9, "overflow": "hidden"
            ],
            "children": [first, second]
        ]]))

        let stack = try XCTUnwrap(find(UIStackView.self, key: "styled", below: controller.view))
        let label = try XCTUnwrap(find(UILabel.self, key: "first", below: controller.view))
        XCTAssertEqual(stack.axis, .horizontal)
        XCTAssertEqual(stack.alignment, .center)
        XCTAssertEqual(stack.spacing, 7)
        XCTAssertEqual(stack.layoutMargins.left, 11)
        XCTAssertEqual(stack.layoutMargins.top, 5)
        XCTAssertEqual(stack.arrangedSubviews.compactMap { $0.accessibilityIdentifier }, ["second", "first"])
        XCTAssertEqual(stack.alpha, 0.75)
        XCTAssertEqual(stack.layer.borderWidth, 3)
        XCTAssertEqual(stack.layer.cornerRadius, 9)
        XCTAssertTrue(stack.clipsToBounds)
        XCTAssertEqual(label.text, "FIRST")
        XCTAssertEqual(label.font.pointSize, 21)
        XCTAssertTrue(label.font.fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertEqual(label.textAlignment, .right)
        XCTAssertEqual(label.attributedText?.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat, 2)
        XCTAssertNotNil(label.attributedText?.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }

    func testImageFailuresAreExplicitAndClearStaleContent() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(document([[
            "type": "Image", "props": ["key": "broken", "source": ["uri": "data:image/png;base64,invalid"]]
        ]]))
        let image = try XCTUnwrap(find(UIImageView.self, key: "broken", below: controller.view))
        XCTAssertNil(image.image)
        XCTAssertEqual(image.accessibilityValue, "Image data is invalid")

        controller.render(document([[
            "type": "Image", "props": ["key": "broken", "source": ["uri": "http://example.com/image.png"]]
        ]]))
        XCTAssertEqual(image.accessibilityValue, "Unsupported image source")

        controller.render(document([["type": "Image", "props": ["key": "broken"]]]))
        XCTAssertEqual(image.accessibilityValue, "Image source is missing")

        controller.render(document([["type": "Text", "props": ["key": "status"], "children": ["Updated"]], [
            "type": "Image", "props": ["key": "broken", "source": ["uri": "http://example.com/image.png"]]
        ]]))
        XCTAssertEqual(image.accessibilityValue, "Unsupported image source")

        controller.render(document([[
            "type": "Image",
            "props": [
                "key": "broken",
                "source": ["uri": "http://example.com/image.png"],
                "accessibilityValue": "ready",
            ],
        ]]))
        XCTAssertEqual(image.accessibilityValue, "ready, Unsupported image source")
    }

    func testMutationBatchesPreserveControlsFocusScrollAndHandlers() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.render(["id": "root-node", "type": "View", "children": []])
        try controller.applyMutation(batch(1, [
            ["op": "createNode", "id": "field-node", "node": [
                "type": "TextInput", "props": ["testID": "field"], "events": ["onChange": "changed"]
            ]],
            ["op": "createNode", "id": "scroll-node", "node": [
                "type": "ScrollView", "props": ["testID": "scroll"], "style": ["height": 40]
            ]],
            ["op": "createNode", "id": "label-node", "node": [
                "type": "Text", "props": ["testID": "label", "accessibilityLabel": "Before"],
                "children": ["Before"]
            ]],
            ["op": "insertChild", "parentId": "scroll-node", "childId": "label-node", "index": 0],
            ["op": "insertChild", "parentId": "root-node", "childId": "field-node", "index": 0],
            ["op": "insertChild", "parentId": "root-node", "childId": "scroll-node", "index": 1],
        ]))

        let field = try XCTUnwrap(find(UITextField.self, key: "field", below: controller.view))
        let scroll = try XCTUnwrap(find(UIScrollView.self, key: "scroll", below: controller.view))
        let label = try XCTUnwrap(find(UILabel.self, key: "label", below: controller.view))
        field.text = "draft"
        let caret = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 3))
        field.selectedTextRange = field.textRange(from: caret, to: caret)
        scroll.contentOffset = CGPoint(x: 0, y: 17)

        let update = try controller.applyMutation(batch(2, [
            ["op": "updateNode", "id": "label-node", "patch": [
                "children": ["After"],
                "props": ["testID": "label", "accessibilityLabel": "After"],
                "events": ["onPress": "pressed"],
            ]],
        ]))
        XCTAssertFalse(update.requiresFullRender)
        XCTAssertEqual(update.updatedNodeIds, ["label-node"])

        XCTAssertTrue(field === find(UITextField.self, key: "field", below: controller.view))
        XCTAssertTrue(scroll === find(UIScrollView.self, key: "scroll", below: controller.view))
        XCTAssertTrue(label === find(UILabel.self, key: "label", below: controller.view))
        XCTAssertEqual(field.text, "draft")
        let selection = try XCTUnwrap(field.selectedTextRange)
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: selection.start), 3)
        XCTAssertEqual(scroll.contentOffset.y, 17)
        XCTAssertEqual(label.text, "After")
        XCTAssertEqual(label.accessibilityLabel, "After")

        let move = try controller.applyMutation(batch(3, [
            ["op": "moveChild", "parentId": "root-node", "childId": "scroll-node", "index": 0],
        ]))
        XCTAssertFalse(move.requiresFullRender)
        XCTAssertEqual(move.affectedNodeIds, ["root-node"])
        XCTAssertTrue(field === find(UITextField.self, key: "field", below: controller.view))
        XCTAssertTrue(scroll === find(UIScrollView.self, key: "scroll", below: controller.view))
    }

    func testMutationValidationIsAtomicAndDeterministic() throws {
        let document = CraftNativeMutationDocument()
        XCTAssertThrowsError(try document.apply(batch(1, [
            ["op": "createNode", "id": "root", "root": true, "node": ["type": "View"]],
            ["op": "removeNode", "id": "missing"],
        ]))) { error in
            XCTAssertEqual(error as? CraftNativeMutationFailure, CraftNativeMutationFailure(
                "UNKNOWN_NODE", "node missing does not exist", operationIndex: 1
            ))
        }
        XCTAssertEqual(document.revision, 0)

        _ = try document.apply(batch(1, [
            ["op": "createNode", "id": "root", "root": true, "node": ["type": "View"]],
        ]))
        XCTAssertThrowsError(try document.apply(batch(2, [
            ["op": "updateNode", "id": "root", "patch": ["type": "Text"]],
        ]))) { error in
            XCTAssertEqual(error as? CraftNativeMutationFailure, CraftNativeMutationFailure(
                "INVALID_PATCH", "unsupported patch field type", operationIndex: 0
            ))
        }
        XCTAssertThrowsError(try document.apply(batch(2, [
            ["op": "removeNode", "id": "root"],
        ], version: 2, baseRevision: 1))) { error in
            XCTAssertEqual((error as? CraftNativeMutationFailure)?.code, "UNSUPPORTED_VERSION")
        }
        XCTAssertEqual(document.revision, 1)
    }

    func testMutationRejectsInvalidTreeShapesWithoutAdvancingRevision() throws {
        let document = CraftNativeMutationDocument()
        _ = try document.apply(batch(1, [
            ["op": "createNode", "id": "root", "root": true, "node": ["type": "View"]],
        ]))

        XCTAssertThrowsError(try document.apply(batch(2, [
            ["op": "createNode", "id": "orphan", "node": ["type": "Text"]],
        ]))) { error in
            XCTAssertEqual(error as? CraftNativeMutationFailure, CraftNativeMutationFailure(
                "INVALID_TREE", "all nodes must be reachable from the root"
            ))
        }
        XCTAssertEqual(document.revision, 1)
        XCTAssertNil(document.node("orphan"))

        XCTAssertThrowsError(try document.apply(batch(2, [
            ["op": "createNode", "id": "parent", "node": ["type": "View"]],
            ["op": "insertChild", "parentId": "parent", "childId": "root", "index": 0],
        ]))) { error in
            XCTAssertEqual(error as? CraftNativeMutationFailure, CraftNativeMutationFailure(
                "INVALID_TREE", "root node must not have a parent"
            ))
        }
        XCTAssertEqual(document.revision, 1)
        XCTAssertNil(document.node("parent"))

        XCTAssertThrowsError(try document.apply(batch(2, [
            ["op": "createNode", "id": "child", "node": ["type": "Text"]],
            ["op": "insertChild", "parentId": "root", "childId": "child", "index": 2],
        ]))) { error in
            XCTAssertEqual((error as? CraftNativeMutationFailure)?.code, "INVALID_INDEX")
            XCTAssertEqual((error as? CraftNativeMutationFailure)?.operationIndex, 1)
        }
        XCTAssertEqual(document.revision, 1)
        XCTAssertNil(document.node("child"))

        XCTAssertThrowsError(try document.apply(batch(2, [
            ["op": "removeNode", "id": "root"],
        ], baseRevision: 0))) { error in
            XCTAssertEqual((error as? CraftNativeMutationFailure)?.code, "REVISION_MISMATCH")
            XCTAssertNil((error as? CraftNativeMutationFailure)?.operationIndex)
        }
        XCTAssertEqual(document.revision, 1)
    }

    func testFlatListRecyclesTenThousandKeyedRowsAndKeepsItsViewport() {
        let list = CraftNativeFlatList()
        list.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let rows: [[String: Any]] = (0..<10_000).map { index in
            ["id": "row-\(index)", "type": "Text", "children": ["Row \(index)"]]
        }
        var rendered: [String: UIView] = [:]
        var renderCount = 0
        let render: CraftNativeFlatList.RenderItem = { node, identity, previous in
            renderCount += 1
            if let previous = previous { return previous }
            let label = UILabel()
            label.text = (node["children"] as? [String])?.first
            rendered[identity] = label
            return label
        }

        list.apply(
            nodes: rows,
            horizontal: false,
            columns: 1,
            inverted: false,
            endReachedThreshold: 0.1,
            renderItem: render,
            recycleItem: { _ in },
            endReached: nil
        )
        list.layoutIfNeeded()
        XCTAssertEqual(list.numberOfItems(inSection: 0), 10_000)
        XCTAssertGreaterThan(renderCount, 0)
        XCTAssertLessThan(renderCount, 100)

        list.contentOffset = CGPoint(x: 0, y: 240)
        list.layoutIfNeeded()
        let retainedAnchor = list.visibleItemIdentities.first
        let moved = [rows[1], rows[0]] + Array(rows.dropFirst(2))
        list.apply(
            nodes: moved,
            horizontal: false,
            columns: 1,
            inverted: false,
            endReachedThreshold: 0.1,
            renderItem: render,
            recycleItem: { _ in },
            endReached: nil
        )
        list.layoutIfNeeded()
        XCTAssertEqual(list.numberOfItems(inSection: 0), 10_000)
        XCTAssertNotNil(retainedAnchor)
        XCTAssertTrue(retainedAnchor.map(list.visibleItemIdentities.contains) ?? false)
        XCTAssertLessThan(rendered.count, 100)
    }

    func testFlatListForwardsScrollAndMomentumCallbacks() {
        let list = CraftNativeFlatList()
        list.frame = CGRect(x: 0, y: 0, width: 320, height: 160)
        var scrollCount = 0
        var beginDragCount = 0
        var endDragCount = 0
        var momentumBeginCount = 0
        var momentumEndCount = 0
        list.onScrollEvent = { _ in scrollCount += 1 }
        list.onScrollBeginDrag = { _ in beginDragCount += 1 }
        list.onScrollEndDrag = { _ in endDragCount += 1 }
        list.onMomentumScrollBegin = { _ in momentumBeginCount += 1 }
        list.onMomentumScrollEnd = { _ in momentumEndCount += 1 }
        let rows = (0..<20).map { index in
            ["id": "row-\(index)", "type": "Text", "children": ["Row \(index)"]] as [String: Any]
        }
        let render: CraftNativeFlatList.RenderItem = { _, _, previous in previous ?? UILabel() }
        list.apply(
            nodes: rows,
            horizontal: false,
            columns: 1,
            inverted: false,
            endReachedThreshold: 0.1,
            renderItem: render,
            recycleItem: { _ in },
            endReached: nil
        )
        list.layoutIfNeeded()
        list.scrollViewWillBeginDragging(list)
        list.scrollViewDidScroll(list)
        list.scrollViewDidEndDragging(list, willDecelerate: true)
        list.scrollViewWillBeginDecelerating(list)
        list.scrollViewDidEndDecelerating(list)
        XCTAssertEqual(scrollCount, 1)
        XCTAssertEqual(beginDragCount, 1)
        XCTAssertEqual(endDragCount, 1)
        XCTAssertEqual(momentumBeginCount, 1)
        XCTAssertEqual(momentumEndCount, 1)
    }

    func testFlatListRefreshControlForwardsAndTracksControlledState() {
        let list = CraftNativeFlatList()
        // A refresh control only begins refreshing inside a window.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        list.frame = window.bounds
        window.addSubview(list)
        window.isHidden = false
        defer { window.isHidden = true }
        var refreshCount = 0
        list.setRefreshHandler({ refreshCount += 1 }, refreshing: false)

        let control = try! XCTUnwrap(list.refreshControl)
        control.sendActions(for: .valueChanged)
        XCTAssertEqual(refreshCount, 1)

        list.setRefreshHandler({ refreshCount += 1 }, refreshing: true)
        XCTAssertTrue(control.isRefreshing)
        list.setRefreshHandler({ refreshCount += 1 }, refreshing: false)
        XCTAssertFalse(control.isRefreshing)
        list.setRefreshHandler(nil, refreshing: false)
        XCTAssertNil(list.refreshControl)
    }

    func testFlatListControllerLaysOutAndMovesMulticolumnRowsWithoutReentrantInvalidation() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let rows: [[String: Any]] = (0..<40).map { index in
            [
                "id": "row-\(index)",
                "type": "View",
                "props": ["key": "row-\(index)", "listRole": "item"],
                "children": [[
                    "id": "label-\(index)", "type": "Text",
                    "props": ["testID": "label-\(index)"], "children": ["Row \(index)"],
                ]],
            ]
        }
        func document(_ children: [[String: Any]]) -> [String: Any] {
            [
                "id": "root-node", "type": "View", "children": [[
                    "id": "list-node", "type": "FlatList",
                    "props": ["testID": "grid", "numColumns": 2],
                    "style": ["height": 300], "children": children,
                ]],
            ]
        }

        controller.render(document(rows))
        controller.view.layoutIfNeeded()
        let list = try XCTUnwrap(find(CraftNativeFlatList.self, key: "grid", below: controller.view))
        list.layoutIfNeeded()
        XCTAssertEqual(list.numberOfItems(inSection: 0), 40)
        XCTAssertNotNil(find(UILabel.self, key: "label-0", below: controller.view))

        controller.render(document(Array(rows.reversed())))
        controller.view.layoutIfNeeded()
        list.layoutIfNeeded()
        XCTAssertEqual(list.numberOfItems(inSection: 0), 40)
    }

    func testFlatListCoalescesAnEndReachedRenderDuringSnapshotApplication() {
        let list = CraftNativeFlatList()
        list.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let first = (0..<2).map { index in
            ["id": "row-\(index)", "type": "Text", "children": ["Row \(index)"]] as [String: Any]
        }
        let appended = first + [["id": "row-2", "type": "Text", "children": ["Row 2"]]]
        let render: CraftNativeFlatList.RenderItem = { _, _, previous in previous ?? UILabel() }
        var endReachedCount = 0
        let endReached = expectation(description: "end reached after initial snapshot")

        list.apply(
            nodes: first,
            horizontal: false,
            columns: 1,
            inverted: false,
            endReachedThreshold: 0.1,
            renderItem: render,
            recycleItem: { _ in },
            endReached: {
                endReachedCount += 1
                list.apply(
                    nodes: appended,
                    horizontal: false,
                    columns: 1,
                    inverted: false,
                    endReachedThreshold: 0.1,
                    renderItem: render,
                    recycleItem: { _ in },
                    endReached: nil
                )
                endReached.fulfill()
            }
        )
        list.layoutIfNeeded()
        wait(for: [endReached], timeout: 2)
        list.layoutIfNeeded()

        XCTAssertEqual(endReachedCount, 1)
        XCTAssertEqual(list.numberOfItems(inSection: 0), 3)

        let changedMiddle = expectation(description: "end reached after a middle row changes")
        list.apply(
            nodes: [
                first[0],
                ["id": "row-1", "type": "Text", "children": ["Updated row 1"]],
                appended[2],
            ],
            horizontal: false,
            columns: 1,
            inverted: false,
            endReachedThreshold: 0.1,
            renderItem: render,
            recycleItem: { _ in },
            endReached: { changedMiddle.fulfill() }
        )
        list.layoutIfNeeded()
        wait(for: [changedMiddle], timeout: 2)

        let chromeOnlyEndReached = expectation(description: "chrome-only list does not reach data end")
        chromeOnlyEndReached.isInverted = true
        let chromeOnly: [[String: Any]] = [
            ["id": "header", "type": "Text", "props": ["listRole": "header"]],
            ["id": "empty", "type": "Text", "props": ["listRole": "empty"]],
            ["id": "footer", "type": "Text", "props": ["listRole": "footer"]],
        ]
        list.apply(
            nodes: chromeOnly,
            horizontal: false,
            columns: 1,
            inverted: false,
            endReachedThreshold: 0.1,
            renderItem: render,
            recycleItem: { _ in },
            endReached: { chromeOnlyEndReached.fulfill() }
        )
        list.layoutIfNeeded()
        wait(for: [chromeOnlyEndReached], timeout: 0.2)
    }

    func testFlatListRetainsAHorizontalViewportAcrossInvertedMoves() throws {
        let list = CraftNativeFlatList()
        list.frame = CGRect(x: 0, y: 0, width: 320, height: 160)
        let header: [String: Any] = [
            "id": "header", "type": "Text", "props": ["listRole": "header"],
        ]
        let footer: [String: Any] = [
            "id": "footer", "type": "Text", "props": ["listRole": "footer"],
        ]
        let rows: [[String: Any]] = (0..<8).map { index in
            ["id": "row-\(index)", "type": "Text", "children": ["Row \(index)"]]
        }
        let render: CraftNativeFlatList.RenderItem = { _, _, previous in previous ?? UILabel() }
        func apply(_ data: [[String: Any]]) {
            list.apply(
                nodes: [header] + data + [footer],
                horizontal: true,
                columns: 1,
                inverted: true,
                endReachedThreshold: 0.1,
                renderItem: render,
                recycleItem: { _ in },
                endReached: nil
            )
            let settled = expectation(description: "horizontal snapshot settled")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { settled.fulfill() }
            wait(for: [settled], timeout: 1)
            list.layoutIfNeeded()
        }

        apply(rows)
        let layout = try XCTUnwrap(list.collectionViewLayout as? UICollectionViewFlowLayout)
        XCTAssertEqual(layout.scrollDirection, .horizontal)
        XCTAssertEqual(list.numberOfItems(inSection: 0), 10)
        XCTAssertEqual(list.visibleItemIdentities.first, "footer")

        list.scrollToItem(at: IndexPath(item: 4, section: 0), at: .left, animated: false)
        list.layoutIfNeeded()
        let retainedAnchor = try XCTUnwrap(list.visibleItemIdentities.first)
        let moved = [rows[1], rows[0]] + Array(rows.dropFirst(2))
        apply(moved)

        XCTAssertTrue(list.visibleItemIdentities.contains(retainedAnchor))
    }
}
