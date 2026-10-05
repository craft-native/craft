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

    func testImageAndScrollViewAreNativeAccessibleAndStable() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.loadViewIfNeeded()
        let pixel = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+XhO6WQAAAABJRU5ErkJggg=="
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
}
