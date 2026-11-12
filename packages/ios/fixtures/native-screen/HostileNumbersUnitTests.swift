import UIKit
import XCTest
@testable import NativeRender

/// Every number a screen's script can put in a prop or a style, at sizes no
/// screen means: the host must draw something, or nothing, and carry on.
///
/// A prop is whatever the script said, and a script's numbers come from data
/// (#510: `maxLength={Number.MAX_VALUE}` ended the process). Rather than find
/// the next such number by reading, this renders every component with every
/// prop and style key the host reads set to each of a handful of hostile
/// numbers, all together and one at a time. A crash is the failure: the case
/// does not finish. `packages/ios/src/hostile-numbers.test.ts` keeps the two
/// lists here equal to the keys the templates read.
@MainActor
final class HostileNumbersUnitTests: XCTestCase {
    static let props: [String] = [
        "accessibilityActions", "accessibilityHint", "accessibilityLabel", "accessibilityLanguage",
        "accessibilityRole", "accessibilityState", "accessibilityValue", "activeOpacity", "alt",
        "alwaysBounceHorizontal", "alwaysBounceVertical", "animating", "animationType", "attributeName",
        "autoCapitalize", "autoComplete", "autoCorrect", "autoFocus", "autoPlay", "autocomplete", "autoplay",
        "barStyle", "basemap", "behavior", "bounces", "cameraHeading", "cameraPitch", "celebration", "checked",
        "clearButtonMode", "color", "contentContainerStyle", "contextMenu", "contextmenu", "controls", "currentTime",
        "defaultSource", "defaultValue", "disabled", "dismissOnOutsideTap", "display", "duration", "edgePadding",
        "edges", "editable", "ellipsizeMode", "fill", "fitToBounds", "fontSize", "frameTimes", "frames",
        "grabberVisible", "hidden", "hidesWhenStopped", "horizontal", "id", "image", "imageShape", "imageSize",
        "imageshape", "imagesize", "indeterminate", "initialRegion", "inverted", "items", "key",
        "keyboardDismissMode", "keyboardShouldPersistTaps", "keyboardType", "keyboardVerticalOffset", "label",
        "listRole", "loop", "mapType", "markers", "maxLength", "maximumDate", "maximumTrackTintColor",
        "maximumValue", "minimumDate", "minimumTrackTintColor", "minimumValue", "minuteInterval", "mode",
        "mostRecentEventCount", "multiline", "muted", "name", "nonModal", "numColumns", "numberOfLines",
        "onEndReachedThreshold", "opacity", "pageIndex", "pagingEnabled", "passwordRules", "paused",
        "pictureInPicture", "pitchEnabled", "placeholder", "placeholderTextColor", "pointerEvents", "polylines",
        "presentationStyle", "preserveAspectRatio", "refreshControl", "refreshing", "region", "repeatCount",
        "resizeMode", "returnKeyType", "rotateEnabled", "scale", "scrollEnabled", "scrollTarget", "secureTextEntry",
        "selectable", "selectedDetent", "selectedValue", "selectionColor", "sheetDetents", "showsCompass",
        "showsHorizontalScrollIndicator", "showsScale", "showsUserLocation", "showsVerticalScrollIndicator", "size",
        "source", "src", "step", "stickyHeaderIndices", "stroke", "strokeWidth", "symbol", "testID", "textAnchor",
        "textContentType", "threshold", "thumbColor", "thumbTintColor", "tileOverlay", "tintColor", "title",
        "titleColor", "trackColor", "transitionID", "transparent", "underlayColor", "value", "viewBox", "visible",
        "x", "y", "zoomEnabled",
    ]

    static let styles: [String] = [
        "alignContent", "alignItems", "alignSelf", "aspectRatio", "backgroundColor", "borderColor", "borderRadius",
        "borderStyle", "borderWidth", "bottom", "color", "columnGap", "display", "elevation", "fill", "flex",
        "flexBasis", "flexDirection", "flexGrow", "flexShrink", "flexWrap", "fontFamily", "fontSize", "fontStyle",
        "fontWeight", "gap", "gradientDirection", "gradientFrom", "gradientTo", "gradientVia", "gridAutoRows",
        "gridColumns", "gridTemplateColumns", "gridTemplateRows", "height", "justifyContent", "left",
        "letterSpacing", "lineHeight", "margin", "marginBottom", "marginHorizontal", "marginLeft", "marginRight",
        "marginTop", "marginVertical", "maxHeight", "maxWidth", "minHeight", "minWidth", "opacity", "order",
        "overflow", "padding", "paddingBottom", "paddingHorizontal", "paddingLeft", "paddingRight", "paddingTop",
        "paddingVertical", "pointerEvents", "position", "resizeMode", "right", "rowGap", "shadowColor",
        "shadowOffset", "shadowOpacity", "shadowRadius", "stroke", "strokeWidth", "textAlign", "textDecorationColor",
        "textDecorationLine", "textDecorationStyle", "textShadowColor", "textShadowOffset", "textShadowRadius",
        "textTransform", "tintColor", "top", "transform", "width", "zIndex",
    ]

    static let types: [String] = [
        "View", "SafeAreaView", "KeyboardAvoidingView", "Text", "Button", "Link", "Checkbox", "TextInput",
        "SegmentedControl", "Picker", "DatePicker", "Switch", "Slider", "ActivityIndicator", "RefreshControl",
        "Image", "ImageBackground", "Icon", "ScrollView", "SectionList", "FlatList", "Svg",
        "TouchableOpacity", "TouchableHighlight", "Pressable",
    ]

    static let numbers: [Double] = [
        1e30, -1e30, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 4_294_967_296.5, -4_294_967_296.5,
        1e15, -1, 0, 0.5,
    ]

    /// The subject beside a sibling in a row, so a flex factor is a share of
    /// something, with two children of its own.
    private func node(_ type: String, props: [String: Any], style: [String: Any]) -> [String: Any] {
        var props = props
        props["key"] = "subject"
        return [
            "type": "View", "style": ["width": 320, "height": 480, "flexDirection": "row"],
            "children": [
                [
                    "type": type, "props": props, "style": style,
                    "children": [
                        ["type": "Text", "props": ["key": "first"], "children": ["First"]],
                        ["type": "Text", "props": ["key": "second"], "children": ["Second"]],
                    ],
                ] as [String: Any],
                ["type": "Text", "props": ["key": "sibling"], "style": ["flex": 1], "children": ["Sibling"]],
            ],
        ]
    }

    /// The same numbers on a child of the subject instead: what a container
    /// makes of a child it cannot place.
    private func parent(_ type: String, childStyle: [String: Any]) -> [String: Any] {
        [
            "type": "View", "style": ["width": 320, "height": 480],
            "children": [[
                "type": type, "props": ["key": "subject"], "style": ["flexDirection": "row", "flexWrap": "wrap"],
                "children": [
                    ["type": "View", "props": ["key": "child"], "style": childStyle, "children": [["type": "Text", "children": ["Child"]]]],
                    ["type": "Text", "props": ["key": "second"], "style": ["flex": 1], "children": ["Second"]],
                ],
            ] as [String: Any]],
        ]
    }

    /// Lays the document out and paints it: borders, shadows, gradients and
    /// drawings are made in the paint, not in the layout.
    private func draw(_ document: [String: Any], in controller: CraftNativeScreenController, _ window: UIWindow, paint: Bool = true) {
        controller.render(document)
        window.layoutIfNeeded()
        guard paint else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        _ = UIGraphicsImageRenderer(size: CGSize(width: 195, height: 422), format: format).image { context in
            context.cgContext.scaleBy(x: 0.5, y: 0.5)
            window.layer.render(in: context.cgContext)
        }
    }

    private func screen() throws -> (CraftNativeScreenController, UIWindow) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let controller = CraftNativeScreenController(config: CraftConfig())
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return (controller, window)
    }

    func testEveryPropAndStyleSetToAHostileNumberAtOnce() throws {
        let (controller, window) = try screen()
        defer { window.isHidden = true }
        for type in Self.types {
            for number in Self.numbers {
                let props = Dictionary(Self.props.map { ($0, number as Any) }, uniquingKeysWith: { first, _ in first })
                let style = Dictionary(Self.styles.map { ($0, number as Any) }, uniquingKeysWith: { first, _ in first })
                draw(node(type, props: props, style: [:]), in: controller, window)
                draw(node(type, props: [:], style: style), in: controller, window)
                draw(node(type, props: props, style: style), in: controller, window)
            }
        }
        // And an ordinary screen still draws after all that.
        draw(node("Text", props: ["numberOfLines": 2], style: ["fontSize": 17]), in: controller, window)
        XCTAssertNotNil(controller.view.window)
    }

    func testEachPropSetToAHostileNumberOnItsOwn() throws {
        let (controller, window) = try screen()
        defer { window.isHidden = true }
        for type in Self.types {
            for name in Self.props {
                // Laid out only: a prop that paints is painted, with every
                // other, in the case that sets them all at once.
                for number in [1e30, -1e30, Double.greatestFiniteMagnitude] {
                    draw(node(type, props: [name: number], style: [:]), in: controller, window, paint: false)
                }
            }
        }
        XCTAssertNotNil(controller.view.window)
    }

    func testEachStyleSetToAHostileNumberOnItsOwn() throws {
        let (controller, window) = try screen()
        defer { window.isHidden = true }
        for type in Self.types {
            for name in Self.styles {
                for number in [1e30, -1e30, Double.greatestFiniteMagnitude] {
                    draw(node(type, props: [:], style: [name: number]), in: controller, window)
                }
            }
        }
        XCTAssertNotNil(controller.view.window)
    }

    func testEachStyleOfAChildSetToAHostileNumberOnItsOwn() throws {
        let (controller, window) = try screen()
        defer { window.isHidden = true }
        for type in ["View", "ScrollView", "Pressable", "FlatList"] {
            for name in Self.styles {
                for number in [1e30, -1e30, Double.greatestFiniteMagnitude] {
                    draw(parent(type, childStyle: [name: number]), in: controller, window)
                }
            }
        }
        XCTAssertNotNil(controller.view.window)
    }

    /// Lengths written as text, transforms, and a drawing's own numbers:
    /// none of them is a plain number in a style or a prop.
    func testHostileLengthsTransformsAndDrawings() throws {
        let (controller, window) = try screen()
        defer { window.isHidden = true }
        for number in Self.numbers {
            let text = "\(number)"
            for length in ["\(text)%", "\(text)px", text, "1e400", "1e400%", "-1e400px"] {
                for name in ["width", "height", "minWidth", "maxWidth", "minHeight", "maxHeight", "flexBasis", "gridAutoRows"] {
                    draw(node("View", props: [:], style: [name: length]), in: controller, window)
                    draw(parent("View", childStyle: [name: length]), in: controller, window)
                }
            }
            for transform in ["translateX", "translateY", "scale", "scaleX", "scaleY"] {
                draw(node("View", props: [:], style: ["transform": [[transform: number]]]), in: controller, window)
                draw(node("Text", props: [:], style: ["transform": [[transform: number], ["rotate": "\(text)deg"], ["skewX": "\(text)rad"]]]), in: controller, window)
            }
            let shapes: [[String: Any]] = [
                ["type": "Path", "props": ["geometry": [0, number, number, 1, number, 0, 2, number, number, number, number, 0, 0, 3, number, number, 5, 5, 4], "stroke": "#ff0000", "strokeWidth": number, "fill": "#00ff00", "opacity": number]],
                ["type": "Path", "props": ["geometry": [number, 0, 0, 1, 10, 10], "stroke": "#ff0000"]],
                ["type": "SvgText", "props": ["x": number, "y": number, "fontSize": number, "fill": "#000000"], "children": ["Text"]],
                ["type": "G", "props": ["opacity": number, "strokeWidth": number], "children": [["type": "Path", "props": ["geometry": [0, 0, 0, 1, number, number], "stroke": "#0000ff"]]]],
            ]
            let boxes: [[Any]] = [[0, 0, 24, 24], [0, 0, number, number], [number, number, 24, 24], [0, 0, 0, 0], [0, 0, 24, number]]
            for viewBox in boxes {
                draw([
                    "type": "View", "style": ["width": 320, "height": 480],
                    "children": [["type": "Svg", "props": ["key": "drawing", "viewBox": viewBox], "style": ["width": 120, "height": 120], "children": shapes] as [String: Any]],
                ], in: controller, window)
            }
        }
        XCTAssertNotNil(controller.view.window)
    }
}
