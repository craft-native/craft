import UIKit
import XCTest
@testable import NativeRender

@MainActor
final class NativeRenderUnitTests: XCTestCase {
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
}
