import Foundation
import zlib
import CoreFoundation
import ImageIO
import AVFoundation
import AVKit
import CryptoKit
import Darwin
import JavaScriptCore
import MapKit
import OSLog
import Security
import SwiftUI
import UIKit

private let craftNativeCapabilityTimeoutMilliseconds = 30_000

/// A retained JavaScript context must lose storage and snapshot access when
/// its screen closes. Only the actual synchronous unmount callback may finish
/// its cleanup; queued script work runs after that allowance ends.
private final class CraftNativeStorageLifetime {
    private let lock = NSLock()
    private var closed = false
    private var unmounting = false

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    func unmount(_ work: () -> Void) {
        lock.lock()
        unmounting = true
        lock.unlock()
        defer {
            lock.lock()
            unmounting = false
            lock.unlock()
        }
        work()
    }

    func access<T>(closedValue: T, _ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !closed || unmounting else {
            if let context = JSContext.current() {
                context.exception = JSValue(newErrorFromMessage: "SCREEN_CLOSED: The native screen is closed", in: context)
            }
            return closedValue
        }
        return work()
    }
}

/// Foundation's `NSNumber(0/1) is Bool` is true even for JSON numbers.
/// Check the Core Foundation identity so real booleans stay invalid numeric
/// props while zero lengths, flex factors and opacity 1 remain numbers.
func craftNativeNumber(_ value: Any?) -> NSNumber? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return number
}

/// A finite number from a prop, for the views outside the screen controller,
/// which has its own: the keyboard-avoiding view and SVG text read theirs
/// with it, and without it the template did not compile.
private func number(_ value: Any?) -> CGFloat? {
    // JavaScript booleans bridge to NSNumber on Apple platforms; they are
    // invalid numeric styles and must stay unset like Android's Number cast.
    guard let number = craftNativeNumber(value) else { return nil }
    let value = CGFloat(truncating: number)
    return value.isFinite ? value : nil
}

private func craftNativeFontWeight(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    guard let number = craftNativeNumber(value), number.doubleValue.isFinite else { return nil }
    let integer = number.doubleValue.rounded()
    return integer == number.doubleValue ? String(Int(integer)) : nil
}

private func craftNativePickerValue(_ value: Any?) -> String? {
    if let value = value as? String, !value.isEmpty { return value }
    if let value = craftNativeNumber(value), value.doubleValue.isFinite { return String(value.doubleValue) }
    return nil
}

private func craftNativeGridColumnCount(_ value: Any?) -> Int {
    if let number = craftNativeNumber(value) { return max(1, number.intValue) }
    guard let text = value as? String else { return 1 }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("repeat(") {
        let digits = trimmed.dropFirst("repeat(".count).prefix { $0.isNumber }
        if let count = Int(digits) { return max(1, count) }
    }
    let tracks = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
    return max(1, tracks.count)
}

private func craftNativeGridRowCount(_ value: Any?) -> Int? {
    if let number = craftNativeNumber(value) { return max(1, number.intValue) }
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("repeat(") {
        let digits = trimmed.dropFirst("repeat(".count).prefix { $0.isNumber }
        if let count = Int(digits) { return max(1, count) }
    }
    let tracks = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
    return tracks.isEmpty ? nil : max(1, tracks.count)
}

/// Optional bridge to the shared Zig flex rule. Native hosts retain their
/// local implementation when no Craft runtime is linked (the normal SDK
/// fallback), while runtime-backed apps get one cross-platform calculation.
private enum CraftNativeFlexBridge {
    private struct Item {
        var basis: Float
        var grow: Float
        var shrink: Float
        var min: Float
        var max: Float
        var marginStart: Float
        var marginEnd: Float
    }

    private typealias Function = @convention(c) (
        Float, Float, UInt32, UnsafeRawPointer, Int, UnsafeMutableRawPointer, UnsafeMutableRawPointer
    ) -> Int32

    private static let function: Function? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "craft_native_flex_row_justified") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    static func widths(available: CGFloat, gap: CGFloat, justify: UInt32, items: [(basis: CGFloat, grow: CGFloat, shrink: CGFloat, min: CGFloat?, max: CGFloat?, leading: CGFloat, trailing: CGFloat)]) -> [(width: CGFloat, position: CGFloat)]? {
        guard let function, !items.isEmpty else { return nil }
        var input = items.map { item in
            Item(
                basis: Float(item.basis), grow: Float(item.grow), shrink: Float(item.shrink),
                min: item.min.map(Float.init) ?? .nan, max: item.max.map(Float.init) ?? .nan,
                marginStart: Float(item.leading), marginEnd: Float(item.trailing)
            )
        }
        var output = [Float](repeating: 0, count: input.count)
        var positions = [Float](repeating: 0, count: input.count)
        let status = input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                positions.withUnsafeMutableBufferPointer { positionBuffer in
                    function(Float(available), Float(gap), justify, UnsafeRawPointer(inputBuffer.baseAddress!), input.count, UnsafeMutableRawPointer(outputBuffer.baseAddress!), UnsafeMutableRawPointer(positionBuffer.baseAddress!))
                }
            }
        }
        guard status == 0, output.allSatisfy({ $0.isFinite }), positions.allSatisfy({ $0.isFinite }) else { return nil }
        return zip(output, positions).map { (width: CGFloat($0), position: CGFloat($1)) }
    }
}

private func craftNativeJustifyCode(_ value: String) -> UInt32 {
    switch value {
    case "center": return 1
    case "flex-end": return 2
    case "space-between": return 3
    case "space-around": return 4
    case "space-evenly": return 5
    default: return 0
    }
}

/// Optional bridge to the host-neutral tree layout ABI. The host still owns
/// intrinsic measurement and keeps its local implementation for unsupported
/// trees or runtimes built before this symbol was exported.
private enum CraftNativeTreeLayoutBridge {
    private struct StyleInput {
        var direction: UInt32 = 0
        var width: Float = .nan
        var height: Float = .nan
        var intrinsicWidth: Float = .nan
        var intrinsicHeight: Float = .nan
        var baseline: Float = .nan
        var aspectRatio: Float = .nan
        var flexBasis: Float = .nan
        var flexGrow: Float = 0
        var flexShrink: Float = 0
        var minWidth: Float = .nan
        var maxWidth: Float = .nan
        var minHeight: Float = .nan
        var maxHeight: Float = .nan
        var gap: Float = 0
        var justifyContent: UInt32 = 0
        var alignItems: UInt32 = 3
        var alignSelf: UInt32 = 0
        var flexWrap: UInt32 = 0
        var alignContent: UInt32 = 5
        var marginTop: Float = 0
        var marginRight: Float = 0
        var marginBottom: Float = 0
        var marginLeft: Float = 0
        var paddingTop: Float = 0
        var paddingRight: Float = 0
        var paddingBottom: Float = 0
        var paddingLeft: Float = 0
        var grid: UInt32 = 0
        var gridColumns: UInt32 = 1
        var rowGap: Float = 0
        var columnGap: Float = 0
    }

    private struct NodeInput {
        var style: StyleInput
        var firstChild: UInt32
        var childCount: UInt32
    }

    private struct StyleInputV2 {
        var direction: UInt32 = 0
        var width: Float = .nan
        var height: Float = .nan
        var intrinsicWidth: Float = .nan
        var intrinsicHeight: Float = .nan
        var baseline: Float = .nan
        var aspectRatio: Float = .nan
        var flexBasis: Float = .nan
        var flexGrow: Float = 0
        var flexShrink: Float = 0
        var minWidth: Float = .nan
        var maxWidth: Float = .nan
        var minHeight: Float = .nan
        var maxHeight: Float = .nan
        var gap: Float = 0
        var justifyContent: UInt32 = 0
        var alignItems: UInt32 = 3
        var alignSelf: UInt32 = 0
        var flexWrap: UInt32 = 0
        var alignContent: UInt32 = 5
        var marginTop: Float = 0
        var marginRight: Float = 0
        var marginBottom: Float = 0
        var marginLeft: Float = 0
        var paddingTop: Float = 0
        var paddingRight: Float = 0
        var paddingBottom: Float = 0
        var paddingLeft: Float = 0
        var grid: UInt32 = 0
        var gridColumns: UInt32 = 1
        var rowGap: Float = 0
        var columnGap: Float = 0
        var reverse: UInt32 = 0
    }

    private struct NodeInputV2 {
        var style: StyleInputV2
        var firstChild: UInt32
        var childCount: UInt32
    }

    private struct StyleInputV4 {
        var direction: UInt32 = 0
        var width: Float = .nan
        var height: Float = .nan
        var intrinsicWidth: Float = .nan
        var intrinsicHeight: Float = .nan
        var baseline: Float = .nan
        var aspectRatio: Float = .nan
        var flexBasis: Float = .nan
        var flexGrow: Float = 0
        var flexShrink: Float = 0
        var minWidth: Float = .nan
        var maxWidth: Float = .nan
        var minHeight: Float = .nan
        var maxHeight: Float = .nan
        var gap: Float = 0
        var justifyContent: UInt32 = 0
        var alignItems: UInt32 = 3
        var alignSelf: UInt32 = 0
        var flexWrap: UInt32 = 0
        var alignContent: UInt32 = 5
        var marginTop: Float = 0
        var marginRight: Float = 0
        var marginBottom: Float = 0
        var marginLeft: Float = 0
        var paddingTop: Float = 0
        var paddingRight: Float = 0
        var paddingBottom: Float = 0
        var paddingLeft: Float = 0
        var grid: UInt32 = 0
        var gridColumns: UInt32 = 1
        var rowGap: Float = 0
        var columnGap: Float = 0
        var reverse: UInt32 = 0
        var gridAutoRows: Float = .nan
    }

    private struct StyleInputV5 {
        var direction: UInt32 = 0
        var width: Float = .nan
        var height: Float = .nan
        var intrinsicWidth: Float = .nan
        var intrinsicHeight: Float = .nan
        var baseline: Float = .nan
        var aspectRatio: Float = .nan
        var flexBasis: Float = .nan
        var flexGrow: Float = 0
        var flexShrink: Float = 0
        var minWidth: Float = .nan
        var maxWidth: Float = .nan
        var minHeight: Float = .nan
        var maxHeight: Float = .nan
        var gap: Float = 0
        var justifyContent: UInt32 = 0
        var alignItems: UInt32 = 3
        var alignSelf: UInt32 = 0
        var flexWrap: UInt32 = 0
        var alignContent: UInt32 = 5
        var marginTop: Float = 0
        var marginRight: Float = 0
        var marginBottom: Float = 0
        var marginLeft: Float = 0
        var paddingTop: Float = 0
        var paddingRight: Float = 0
        var paddingBottom: Float = 0
        var paddingLeft: Float = 0
        var grid: UInt32 = 0
        var gridColumns: UInt32 = 1
        var rowGap: Float = 0
        var columnGap: Float = 0
        var reverse: UInt32 = 0
        var gridAutoRows: Float = .nan
        var gridRows: UInt32 = 0
    }

    private struct NodeInputV4 {
        var style: StyleInputV4
        var firstChild: UInt32
        var childCount: UInt32
    }

    private struct NodeInputV5 {
        var style: StyleInputV5
        var firstChild: UInt32
        var childCount: UInt32
    }

    fileprivate struct Frame {
        var x: Float
        var y: Float
        var width: Float
        var height: Float
    }

    fileprivate struct TreeNode {
        let view: UIView?
        let style: CraftNativeLayoutStyle
        let intrinsic: CGSize
        let baseline: CGFloat
        let direction: NSLayoutConstraint.Axis
        let gap: CGFloat
        let rowGap: CGFloat
        let columnGap: CGFloat
        let wrap: Bool
        let justifyContent: String
        let alignItems: String
        let alignContent: String
        let padding: UIEdgeInsets
        let grid: Bool
        let gridColumns: Int
        let gridRows: Int?
        let gridAutoRows: CraftNativeLength?
        let reverse: Bool
        let wrapReverse: Bool
        let children: [TreeNode]
    }

    fileprivate struct TreeResult {
        let nodes: [TreeNode]
        let parents: [Int]
        let frames: [Frame]
    }

    private typealias Function = @convention(c) (
        Float, Float, UnsafeRawPointer, Int, UnsafeMutableRawPointer, Int
    ) -> Int32

    private typealias FunctionV2 = @convention(c) (
        Float, Float, UnsafeRawPointer, Int, UnsafeMutableRawPointer, Int
    ) -> Int32

    private static let function: Function? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "craft_native_layout_tree") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    private static let functionV2: FunctionV2? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "craft_native_layout_tree_v2") else { return nil }
        return unsafeBitCast(symbol, to: FunctionV2.self)
    }()

    private static let functionV3: FunctionV2? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "craft_native_layout_tree_v3") else { return nil }
        return unsafeBitCast(symbol, to: FunctionV2.self)
    }()

    private static let functionV4: FunctionV2? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "craft_native_layout_tree_v4") else { return nil }
        return unsafeBitCast(symbol, to: FunctionV2.self)
    }()

    private static let functionV5: FunctionV2? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "craft_native_layout_tree_v5") else { return nil }
        return unsafeBitCast(symbol, to: FunctionV2.self)
    }()

    private static func finite(_ value: CGFloat?) -> Float {
        guard let value, value.isFinite else { return .nan }
        return Float(value)
    }

    private static func length(_ value: CraftNativeLength?, base: CGFloat?) -> Float {
        guard let value else { return .nan }
        return finite(value.resolve(base))
    }

    private static func alignment(_ value: String?) -> UInt32 {
        switch value {
        case "center": return 1
        case "flex-end": return 2
        case "stretch": return 3
        case "baseline": return 4
        default: return 0
        }
    }

    private static func alignSelf(_ value: String?) -> UInt32 {
        switch value {
        case "flex-start": return 1
        case "center": return 2
        case "flex-end": return 3
        case "stretch": return 4
        case "baseline": return 5
        default: return 0
        }
    }

    private static func justify(_ value: String) -> UInt32 {
        craftNativeJustifyCode(value)
    }

    static func frames(
        width: CGFloat,
        height: CGFloat,
        direction: NSLayoutConstraint.Axis,
        gap: CGFloat,
        rowGap: CGFloat?,
        columnGap: CGFloat?,
        wrap: Bool,
        justifyContent: String,
        alignItems: String,
        padding: UIEdgeInsets,
        children: [(UIView, CraftNativeLayoutStyle, CGSize, CGFloat)]
    ) -> [(UIView, CGRect)]? {
        guard let function, width.isFinite, height.isFinite, width >= 0, height >= 0, !children.isEmpty else { return nil }
        let mainGap = direction == .horizontal ? (columnGap ?? gap) : (rowGap ?? gap)
        let crossGap = direction == .horizontal ? (rowGap ?? gap) : (columnGap ?? gap)
        var root = StyleInput(
            direction: direction == .horizontal ? 0 : 1,
            width: Float(width), height: Float(height), gap: Float(max(0, mainGap)),
            justifyContent: justify(justifyContent), alignItems: alignment(alignItems), flexWrap: wrap ? 1 : 0,
            paddingTop: Float(max(0, padding.top)), paddingRight: Float(max(0, padding.right)),
            paddingBottom: Float(max(0, padding.bottom)), paddingLeft: Float(max(0, padding.left))
        )
        root.rowGap = Float(max(0, rowGap ?? 0))
        root.columnGap = Float(max(0, columnGap ?? 0))
        let contentWidth = max(0, width - padding.left - padding.right)
        let contentHeight = max(0, height - padding.top - padding.bottom)
        let mainSize = direction == .horizontal ? contentWidth : contentHeight
        var nodes = [NodeInput(style: root, firstChild: 1, childCount: UInt32(children.count))]
        for (view, style, intrinsic, baseline) in children {
            let shrink: CGFloat
            if let authored = style.flexShrink {
                shrink = authored
            } else if view is UIScrollView {
                shrink = 1
            } else if view is UILabel, direction == .horizontal {
                shrink = 1
            } else {
                shrink = 0
            }
            var input = StyleInput(
                width: length(style.width, base: contentWidth), height: length(style.height, base: contentHeight),
                intrinsicWidth: Float(max(0, intrinsic.width)), intrinsicHeight: Float(max(0, intrinsic.height)),
                baseline: Float(max(0, baseline)), aspectRatio: finite(style.aspectRatio),
                flexBasis: length(style.flexBasis, base: mainSize), flexGrow: Float(max(0, style.flexGrow)), flexShrink: Float(max(0, shrink)),
                minWidth: length(style.minWidth, base: contentWidth), maxWidth: length(style.maxWidth, base: contentWidth),
                minHeight: length(style.minHeight, base: contentHeight), maxHeight: length(style.maxHeight, base: contentHeight),
                alignSelf: alignSelf(style.alignSelf),
                marginTop: Float(max(0, style.marginTop)), marginRight: Float(max(0, style.marginRight)),
                marginBottom: Float(max(0, style.marginBottom)), marginLeft: Float(max(0, style.marginLeft))
            )
            input.direction = 0
            nodes.append(NodeInput(style: input, firstChild: 0, childCount: 0))
        }
        var output = [Frame](repeating: Frame(x: 0, y: 0, width: 0, height: 0), count: nodes.count)
        let frameCount = output.count
        let status = nodes.withUnsafeBufferPointer { nodeBuffer in
            output.withUnsafeMutableBufferPointer { frameBuffer in
                function(
                    Float(width), Float(height), UnsafeRawPointer(nodeBuffer.baseAddress!), nodes.count,
                    UnsafeMutableRawPointer(frameBuffer.baseAddress!), frameCount
                )
            }
        }
        guard status == 0 else { return nil }
        let childFrames = output.dropFirst()
        guard childFrames.allSatisfy({ frame in
            frame.x.isFinite && frame.y.isFinite && frame.width.isFinite && frame.height.isFinite &&
                frame.width >= 0 && frame.height >= 0
        }) else { return nil }
        return zip(children, childFrames).map { child, frame in
            (child.0, CGRect(x: CGFloat(frame.x), y: CGFloat(frame.y), width: CGFloat(frame.width), height: CGFloat(frame.height)))
        }
    }

    fileprivate static func treeFrames(root: TreeNode, width: CGFloat, height: CGFloat) -> TreeResult? {
        guard let function, width.isFinite, height.isFinite, width >= 0, height >= 0, !root.children.isEmpty else { return nil }
        if containsGridRows(root) {
            return treeFramesV5(root: root, width: width, height: height, function: functionV5)
        }
        if containsGridAutoRows(root) {
            return treeFramesV4(root: root, width: width, height: height, function: functionV4)
        }
        if containsWrapReverse(root) {
            return treeFramesV2(root: root, width: width, height: height, function: functionV3)
        }
        if containsReverse(root) {
            return treeFramesV2(root: root, width: width, height: height, function: functionV2)
        }
        var nodes: [TreeNode] = []
        var parents: [Int] = []
        func append(_ node: TreeNode, parent: Int) {
            let index = nodes.count
            nodes.append(node)
            parents.append(parent)
            node.children.forEach { append($0, parent: index) }
        }
        append(root, parent: -1)

        func put(_ input: inout StyleInput, _ node: TreeNode, parentWidth: CGFloat, parentHeight: CGFloat, rootNode: Bool, parentDirection: NSLayoutConstraint.Axis) {
            let contentWidth = max(0, (rootNode ? width : node.intrinsic.width) - node.padding.left - node.padding.right)
            let contentHeight = max(0, (rootNode ? height : node.intrinsic.height) - node.padding.top - node.padding.bottom)
            let mainSize = node.direction == .horizontal ? contentWidth : contentHeight
            input.direction = node.direction == .horizontal ? 0 : 1
            input.width = rootNode ? Float(width) : length(node.style.width, base: parentWidth)
            input.height = rootNode ? Float(height) : length(node.style.height, base: parentHeight)
            input.intrinsicWidth = rootNode ? .nan : Float(max(0, node.intrinsic.width))
            input.intrinsicHeight = rootNode ? .nan : Float(max(0, node.intrinsic.height))
            input.baseline = rootNode ? .nan : Float(max(0, node.baseline))
            input.aspectRatio = finite(node.style.aspectRatio)
            input.flexBasis = length(node.style.flexBasis, base: mainSize)
            input.flexGrow = rootNode ? 0 : Float(max(0, node.style.flexGrow))
            let defaultShrink: CGFloat = node.view is UIScrollView || (node.view is UILabel && parentDirection == .horizontal) ? 1 : 0
            input.flexShrink = rootNode ? 0 : Float(max(0, node.style.flexShrink ?? defaultShrink))
            input.minWidth = length(node.style.minWidth, base: contentWidth)
            input.maxWidth = length(node.style.maxWidth, base: contentWidth)
            input.minHeight = length(node.style.minHeight, base: contentHeight)
            input.maxHeight = length(node.style.maxHeight, base: contentHeight)
            input.gap = Float(max(0, node.gap))
            input.justifyContent = justify(node.justifyContent)
            input.alignItems = alignment(node.alignItems)
            input.alignSelf = rootNode ? 0 : alignSelf(node.style.alignSelf)
            input.flexWrap = node.wrap ? 1 : 0
            input.alignContent = craftNativeAlignContentCode(node.alignContent)
            input.marginTop = Float(max(0, node.style.marginTop))
            input.marginRight = Float(max(0, node.style.marginRight))
            input.marginBottom = Float(max(0, node.style.marginBottom))
            input.marginLeft = Float(max(0, node.style.marginLeft))
            input.paddingTop = Float(max(0, node.padding.top))
            input.paddingRight = Float(max(0, node.padding.right))
            input.paddingBottom = Float(max(0, node.padding.bottom))
            input.paddingLeft = Float(max(0, node.padding.left))
            input.grid = node.grid ? 1 : 0
            input.gridColumns = UInt32(max(1, node.gridColumns))
            input.rowGap = Float(max(0, node.rowGap))
            input.columnGap = Float(max(0, node.columnGap))
        }

        var styles = [StyleInput](repeating: StyleInput(), count: nodes.count)
        var metadata = [Float](repeating: 0, count: nodes.count * 2)
        var cursor = 0
        func write(_ node: TreeNode, parentWidth: CGFloat, parentHeight: CGFloat, rootNode: Bool, parentDirection: NSLayoutConstraint.Axis) {
            let index = cursor
            cursor += 1
            put(&styles[index], node, parentWidth: parentWidth, parentHeight: parentHeight, rootNode: rootNode, parentDirection: parentDirection)
            let contentWidth = max(0, (rootNode ? width : node.intrinsic.width) - node.padding.left - node.padding.right)
            let contentHeight = max(0, (rootNode ? height : node.intrinsic.height) - node.padding.top - node.padding.bottom)
            let firstChild = cursor
            node.children.forEach { write($0, parentWidth: contentWidth, parentHeight: contentHeight, rootNode: false, parentDirection: node.direction) }
            metadata[index * 2] = Float(firstChild)
            metadata[index * 2 + 1] = Float(cursor - firstChild)
        }
        write(root, parentWidth: width, parentHeight: height, rootNode: true, parentDirection: root.direction)
        let inputs = zip(styles, stride(from: 0, to: metadata.count, by: 2)).map { style, offset in
            NodeInput(style: style, firstChild: UInt32(metadata[offset]), childCount: UInt32(metadata[offset + 1]))
        }

        var output = [Frame](repeating: Frame(x: 0, y: 0, width: 0, height: 0), count: nodes.count)
        let frameCount = output.count
        let status = inputs.withUnsafeBufferPointer { inputBuffer in
            metadata.withUnsafeBufferPointer { metadataBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    function(
                        Float(width), Float(height), UnsafeRawPointer(inputBuffer.baseAddress!), inputs.count,
                        UnsafeMutableRawPointer(outputBuffer.baseAddress!), frameCount
                    )
                }
            }
        }
        guard status == 0, output.allSatisfy({ frame in
            frame.x.isFinite && frame.y.isFinite && frame.width.isFinite && frame.height.isFinite &&
                frame.width >= 0 && frame.height >= 0
        }) else { return nil }
        return TreeResult(nodes: nodes, parents: parents, frames: output)
    }

    private static func containsReverse(_ node: TreeNode) -> Bool {
        node.reverse || node.children.contains(where: containsReverse)
    }

    private static func containsWrapReverse(_ node: TreeNode) -> Bool {
        node.wrapReverse || node.children.contains(where: containsWrapReverse)
    }

    private static func containsGridAutoRows(_ node: TreeNode) -> Bool {
        node.gridAutoRows != nil || node.children.contains(where: containsGridAutoRows)
    }

    private static func containsGridRows(_ node: TreeNode) -> Bool {
        node.gridRows != nil || node.children.contains(where: containsGridRows)
    }

    private static func treeFramesV2(root: TreeNode, width: CGFloat, height: CGFloat, function: FunctionV2?) -> TreeResult? {
        guard let function, width.isFinite, height.isFinite, width >= 0, height >= 0, !root.children.isEmpty else { return nil }
        var nodes: [TreeNode] = []
        var parents: [Int] = []
        func append(_ node: TreeNode, parent: Int) {
            let index = nodes.count
            nodes.append(node)
            parents.append(parent)
            node.children.forEach { append($0, parent: index) }
        }
        append(root, parent: -1)

        func put(_ input: inout StyleInputV2, _ node: TreeNode, parentWidth: CGFloat, parentHeight: CGFloat, rootNode: Bool, parentDirection: NSLayoutConstraint.Axis) {
            let contentWidth = max(0, (rootNode ? width : node.intrinsic.width) - node.padding.left - node.padding.right)
            let contentHeight = max(0, (rootNode ? height : node.intrinsic.height) - node.padding.top - node.padding.bottom)
            let mainSize = node.direction == .horizontal ? contentWidth : contentHeight
            input.direction = node.direction == .horizontal ? 0 : 1
            input.width = rootNode ? Float(width) : length(node.style.width, base: parentWidth)
            input.height = rootNode ? Float(height) : length(node.style.height, base: parentHeight)
            input.intrinsicWidth = rootNode ? .nan : Float(max(0, node.intrinsic.width))
            input.intrinsicHeight = rootNode ? .nan : Float(max(0, node.intrinsic.height))
            input.baseline = rootNode ? .nan : Float(max(0, node.baseline))
            input.aspectRatio = finite(node.style.aspectRatio)
            input.flexBasis = length(node.style.flexBasis, base: mainSize)
            input.flexGrow = rootNode ? 0 : Float(max(0, node.style.flexGrow))
            let defaultShrink: CGFloat = node.view is UIScrollView || (node.view is UILabel && parentDirection == .horizontal) ? 1 : 0
            input.flexShrink = rootNode ? 0 : Float(max(0, node.style.flexShrink ?? defaultShrink))
            input.minWidth = length(node.style.minWidth, base: contentWidth)
            input.maxWidth = length(node.style.maxWidth, base: contentWidth)
            input.minHeight = length(node.style.minHeight, base: contentHeight)
            input.maxHeight = length(node.style.maxHeight, base: contentHeight)
            input.gap = Float(max(0, node.gap))
            input.justifyContent = justify(node.justifyContent)
            input.alignItems = alignment(node.alignItems)
            input.alignSelf = rootNode ? 0 : alignSelf(node.style.alignSelf)
            input.flexWrap = node.wrap ? 1 : 0
            input.alignContent = craftNativeAlignContentCode(node.alignContent)
            input.marginTop = Float(max(0, node.style.marginTop))
            input.marginRight = Float(max(0, node.style.marginRight))
            input.marginBottom = Float(max(0, node.style.marginBottom))
            input.marginLeft = Float(max(0, node.style.marginLeft))
            input.paddingTop = Float(max(0, node.padding.top))
            input.paddingRight = Float(max(0, node.padding.right))
            input.paddingBottom = Float(max(0, node.padding.bottom))
            input.paddingLeft = Float(max(0, node.padding.left))
            input.grid = node.grid ? 1 : 0
            input.gridColumns = UInt32(max(1, node.gridColumns))
            input.rowGap = Float(max(0, node.rowGap))
            input.columnGap = Float(max(0, node.columnGap))
            input.reverse = (node.reverse ? 1 : 0) | (node.wrapReverse ? 2 : 0)
        }

        var styles = [StyleInputV2](repeating: StyleInputV2(), count: nodes.count)
        var metadata = [Float](repeating: 0, count: nodes.count * 2)
        var cursor = 0
        func write(_ node: TreeNode, parentWidth: CGFloat, parentHeight: CGFloat, rootNode: Bool, parentDirection: NSLayoutConstraint.Axis) {
            let index = cursor
            cursor += 1
            put(&styles[index], node, parentWidth: parentWidth, parentHeight: parentHeight, rootNode: rootNode, parentDirection: parentDirection)
            let contentWidth = max(0, (rootNode ? width : node.intrinsic.width) - node.padding.left - node.padding.right)
            let contentHeight = max(0, (rootNode ? height : node.intrinsic.height) - node.padding.top - node.padding.bottom)
            let firstChild = cursor
            node.children.forEach { write($0, parentWidth: contentWidth, parentHeight: contentHeight, rootNode: false, parentDirection: node.direction) }
            metadata[index * 2] = Float(firstChild)
            metadata[index * 2 + 1] = Float(cursor - firstChild)
        }
        write(root, parentWidth: width, parentHeight: height, rootNode: true, parentDirection: root.direction)
        let inputs = zip(styles, stride(from: 0, to: metadata.count, by: 2)).map { style, offset in
            NodeInputV2(style: style, firstChild: UInt32(metadata[offset]), childCount: UInt32(metadata[offset + 1]))
        }

        var output = [Frame](repeating: Frame(x: 0, y: 0, width: 0, height: 0), count: nodes.count)
        let frameCount = output.count
        let status = inputs.withUnsafeBufferPointer { inputBuffer in
            metadata.withUnsafeBufferPointer { metadataBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    function(
                        Float(width), Float(height), UnsafeRawPointer(inputBuffer.baseAddress!), inputs.count,
                        UnsafeMutableRawPointer(outputBuffer.baseAddress!), frameCount
                    )
                }
            }
        }
        guard status == 0, output.allSatisfy({ frame in
            frame.x.isFinite && frame.y.isFinite && frame.width.isFinite && frame.height.isFinite &&
                frame.width >= 0 && frame.height >= 0
        }) else { return nil }
        return TreeResult(nodes: nodes, parents: parents, frames: output)
    }

    /// v4 is the reverse-aware tree payload with one resolved grid-auto-rows
    /// value appended. Keeping this as a separate struct preserves the v1–v3
    /// strides for runtimes that predate the shared auto-row contract.
    private static func treeFramesV4(root: TreeNode, width: CGFloat, height: CGFloat, function: FunctionV2?) -> TreeResult? {
        guard let function, width.isFinite, height.isFinite, width >= 0, height >= 0, !root.children.isEmpty else { return nil }
        var nodes: [TreeNode] = []
        var parents: [Int] = []
        func append(_ node: TreeNode, parent: Int) {
            let index = nodes.count
            nodes.append(node)
            parents.append(parent)
            node.children.forEach { append($0, parent: index) }
        }
        append(root, parent: -1)

        func put(_ input: inout StyleInputV4, _ node: TreeNode, parentWidth: CGFloat, parentHeight: CGFloat, rootNode: Bool, parentDirection: NSLayoutConstraint.Axis) {
            let contentWidth = max(0, (rootNode ? width : node.intrinsic.width) - node.padding.left - node.padding.right)
            let contentHeight = max(0, (rootNode ? height : node.intrinsic.height) - node.padding.top - node.padding.bottom)
            let mainSize = node.direction == .horizontal ? contentWidth : contentHeight
            input.direction = node.direction == .horizontal ? 0 : 1
            input.width = rootNode ? Float(width) : length(node.style.width, base: parentWidth)
            input.height = rootNode ? Float(height) : length(node.style.height, base: parentHeight)
            input.intrinsicWidth = rootNode ? .nan : Float(max(0, node.intrinsic.width))
            input.intrinsicHeight = rootNode ? .nan : Float(max(0, node.intrinsic.height))
            input.baseline = rootNode ? .nan : Float(max(0, node.baseline))
            input.aspectRatio = finite(node.style.aspectRatio)
            input.flexBasis = length(node.style.flexBasis, base: mainSize)
            input.flexGrow = rootNode ? 0 : Float(max(0, node.style.flexGrow))
            let defaultShrink: CGFloat = node.view is UIScrollView || (node.view is UILabel && parentDirection == .horizontal) ? 1 : 0
            input.flexShrink = rootNode ? 0 : Float(max(0, node.style.flexShrink ?? defaultShrink))
            input.minWidth = length(node.style.minWidth, base: contentWidth)
            input.maxWidth = length(node.style.maxWidth, base: contentWidth)
            input.minHeight = length(node.style.minHeight, base: contentHeight)
            input.maxHeight = length(node.style.maxHeight, base: contentHeight)
            input.gap = Float(max(0, node.gap))
            input.justifyContent = justify(node.justifyContent)
            input.alignItems = alignment(node.alignItems)
            input.alignSelf = rootNode ? 0 : alignSelf(node.style.alignSelf)
            input.flexWrap = node.wrap ? 1 : 0
            input.alignContent = craftNativeAlignContentCode(node.alignContent)
            input.marginTop = Float(max(0, node.style.marginTop))
            input.marginRight = Float(max(0, node.style.marginRight))
            input.marginBottom = Float(max(0, node.style.marginBottom))
            input.marginLeft = Float(max(0, node.style.marginLeft))
            input.paddingTop = Float(max(0, node.padding.top))
            input.paddingRight = Float(max(0, node.padding.right))
            input.paddingBottom = Float(max(0, node.padding.bottom))
            input.paddingLeft = Float(max(0, node.padding.left))
            input.grid = node.grid ? 1 : 0
            input.gridColumns = UInt32(max(1, node.gridColumns))
            input.rowGap = Float(max(0, node.rowGap))
            input.columnGap = Float(max(0, node.columnGap))
            input.reverse = (node.reverse ? 1 : 0) | (node.wrapReverse ? 2 : 0)
            input.gridAutoRows = node.gridAutoRows.map { length($0, base: contentHeight) } ?? .nan
        }

        var styles = [StyleInputV4](repeating: StyleInputV4(), count: nodes.count)
        var metadata = [Float](repeating: 0, count: nodes.count * 2)
        var cursor = 0
        func write(_ node: TreeNode, parentWidth: CGFloat, parentHeight: CGFloat, rootNode: Bool, parentDirection: NSLayoutConstraint.Axis) {
            let index = cursor
            cursor += 1
            put(&styles[index], node, parentWidth: parentWidth, parentHeight: parentHeight, rootNode: rootNode, parentDirection: parentDirection)
            let contentWidth = max(0, (rootNode ? width : node.intrinsic.width) - node.padding.left - node.padding.right)
            let contentHeight = max(0, (rootNode ? height : node.intrinsic.height) - node.padding.top - node.padding.bottom)
            let firstChild = cursor
            node.children.forEach { write($0, parentWidth: contentWidth, parentHeight: contentHeight, rootNode: false, parentDirection: node.direction) }
            metadata[index * 2] = Float(firstChild)
            metadata[index * 2 + 1] = Float(cursor - firstChild)
        }
        write(root, parentWidth: width, parentHeight: height, rootNode: true, parentDirection: root.direction)
        let inputs = zip(styles, stride(from: 0, to: metadata.count, by: 2)).map { style, offset in
            NodeInputV4(style: style, firstChild: UInt32(metadata[offset]), childCount: UInt32(metadata[offset + 1]))
        }

        var output = [Frame](repeating: Frame(x: 0, y: 0, width: 0, height: 0), count: nodes.count)
        let frameCount = output.count
        let status = inputs.withUnsafeBufferPointer { inputBuffer in
            metadata.withUnsafeBufferPointer { metadataBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    function(
                        Float(width), Float(height), UnsafeRawPointer(inputBuffer.baseAddress!), inputs.count,
                        UnsafeMutableRawPointer(outputBuffer.baseAddress!), frameCount
                    )
                }
            }
        }
        guard status == 0, output.allSatisfy({ frame in
            frame.x.isFinite && frame.y.isFinite && frame.width.isFinite && frame.height.isFinite &&
                frame.width >= 0 && frame.height >= 0
        }) else { return nil }
        return TreeResult(nodes: nodes, parents: parents, frames: output)
    }

    /// v5 appends the explicit grid-template-rows count to v4's payload.
    /// Older runtimes continue through v4 when no explicit rows are present.
    private static func treeFramesV5(root: TreeNode, width: CGFloat, height: CGFloat, function: FunctionV2?) -> TreeResult? {
        guard let function, width.isFinite, height.isFinite, width >= 0, height >= 0, !root.children.isEmpty else { return nil }
        var nodes: [TreeNode] = []
        var parents: [Int] = []
        func append(_ node: TreeNode, parent: Int) {
            let index = nodes.count
            nodes.append(node)
            parents.append(parent)
            node.children.forEach { append($0, parent: index) }
        }
        append(root, parent: -1)

        func put(_ input: inout StyleInputV5, _ node: TreeNode, parentWidth: CGFloat, parentHeight: CGFloat, rootNode: Bool, parentDirection: NSLayoutConstraint.Axis) {
            let contentWidth = max(0, (rootNode ? width : node.intrinsic.width) - node.padding.left - node.padding.right)
            let contentHeight = max(0, (rootNode ? height : node.intrinsic.height) - node.padding.top - node.padding.bottom)
            let mainSize = node.direction == .horizontal ? contentWidth : contentHeight
            input.direction = node.direction == .horizontal ? 0 : 1
            input.width = rootNode ? Float(width) : length(node.style.width, base: parentWidth)
            input.height = rootNode ? Float(height) : length(node.style.height, base: parentHeight)
            input.intrinsicWidth = rootNode ? .nan : Float(max(0, node.intrinsic.width))
            input.intrinsicHeight = rootNode ? .nan : Float(max(0, node.intrinsic.height))
            input.baseline = rootNode ? .nan : Float(max(0, node.baseline))
            input.aspectRatio = finite(node.style.aspectRatio)
            input.flexBasis = length(node.style.flexBasis, base: mainSize)
            input.flexGrow = rootNode ? 0 : Float(max(0, node.style.flexGrow))
            let defaultShrink: CGFloat = node.view is UIScrollView || (node.view is UILabel && parentDirection == .horizontal) ? 1 : 0
            input.flexShrink = rootNode ? 0 : Float(max(0, node.style.flexShrink ?? defaultShrink))
            input.minWidth = length(node.style.minWidth, base: contentWidth)
            input.maxWidth = length(node.style.maxWidth, base: contentWidth)
            input.minHeight = length(node.style.minHeight, base: contentHeight)
            input.maxHeight = length(node.style.maxHeight, base: contentHeight)
            input.gap = Float(max(0, node.gap))
            input.justifyContent = justify(node.justifyContent)
            input.alignItems = alignment(node.alignItems)
            input.alignSelf = rootNode ? 0 : alignSelf(node.style.alignSelf)
            input.flexWrap = node.wrap ? 1 : 0
            input.alignContent = craftNativeAlignContentCode(node.alignContent)
            input.marginTop = Float(max(0, node.style.marginTop))
            input.marginRight = Float(max(0, node.style.marginRight))
            input.marginBottom = Float(max(0, node.style.marginBottom))
            input.marginLeft = Float(max(0, node.style.marginLeft))
            input.paddingTop = Float(max(0, node.padding.top))
            input.paddingRight = Float(max(0, node.padding.right))
            input.paddingBottom = Float(max(0, node.padding.bottom))
            input.paddingLeft = Float(max(0, node.padding.left))
            input.grid = node.grid ? 1 : 0
            input.gridColumns = UInt32(max(1, node.gridColumns))
            input.rowGap = Float(max(0, node.rowGap))
            input.columnGap = Float(max(0, node.columnGap))
            input.reverse = (node.reverse ? 1 : 0) | (node.wrapReverse ? 2 : 0)
            input.gridAutoRows = node.gridAutoRows.map { length($0, base: contentHeight) } ?? .nan
            input.gridRows = UInt32(max(0, node.gridRows ?? 0))
        }

        var styles = [StyleInputV5](repeating: StyleInputV5(), count: nodes.count)
        var metadata = [Float](repeating: 0, count: nodes.count * 2)
        var cursor = 0
        func write(_ node: TreeNode, parentWidth: CGFloat, parentHeight: CGFloat, rootNode: Bool, parentDirection: NSLayoutConstraint.Axis) {
            let index = cursor
            cursor += 1
            put(&styles[index], node, parentWidth: parentWidth, parentHeight: parentHeight, rootNode: rootNode, parentDirection: parentDirection)
            let contentWidth = max(0, (rootNode ? width : node.intrinsic.width) - node.padding.left - node.padding.right)
            let contentHeight = max(0, (rootNode ? height : node.intrinsic.height) - node.padding.top - node.padding.bottom)
            let firstChild = cursor
            node.children.forEach { write($0, parentWidth: contentWidth, parentHeight: contentHeight, rootNode: false, parentDirection: node.direction) }
            metadata[index * 2] = Float(firstChild)
            metadata[index * 2 + 1] = Float(cursor - firstChild)
        }
        write(root, parentWidth: width, parentHeight: height, rootNode: true, parentDirection: root.direction)
        let inputs = zip(styles, stride(from: 0, to: metadata.count, by: 2)).map { style, offset in
            NodeInputV5(style: style, firstChild: UInt32(metadata[offset]), childCount: UInt32(metadata[offset + 1]))
        }

        var output = [Frame](repeating: Frame(x: 0, y: 0, width: 0, height: 0), count: nodes.count)
        let frameCount = output.count
        let status = inputs.withUnsafeBufferPointer { inputBuffer in
            metadata.withUnsafeBufferPointer { metadataBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    function(
                        Float(width), Float(height), UnsafeRawPointer(inputBuffer.baseAddress!), inputs.count,
                        UnsafeMutableRawPointer(outputBuffer.baseAddress!), frameCount
                    )
                }
            }
        }
        guard status == 0, output.allSatisfy({ frame in
            frame.x.isFinite && frame.y.isFinite && frame.width.isFinite && frame.height.isFinite &&
                frame.width >= 0 && frame.height >= 0
        }) else { return nil }
        return TreeResult(nodes: nodes, parents: parents, frames: output)
    }
}

private enum CraftNativeFlexLineBridge {
    private struct Item {
        var basis: Float
        var marginStart: Float
        var marginEnd: Float
    }

    private typealias Function = @convention(c) (
        Float, Float, UInt32, UnsafeRawPointer, Int, UnsafeMutableRawPointer
    ) -> Int32

    private static let function: Function? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "craft_native_flex_line_breaks") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    static func lines(available: CGFloat, gap: CGFloat, wrap: Bool, items: [(basis: CGFloat, leading: CGFloat, trailing: CGFloat)]) -> [Int]? {
        guard let function, !items.isEmpty else { return nil }
        var input = items.map { Item(basis: Float($0.basis), marginStart: Float($0.leading), marginEnd: Float($0.trailing)) }
        var output = [Int32](repeating: 0, count: input.count)
        let status = input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                function(Float(available), Float(gap), wrap ? 1 : 0, UnsafeRawPointer(inputBuffer.baseAddress!), input.count, UnsafeMutableRawPointer(outputBuffer.baseAddress!))
            }
        }
        guard status > 0 else { return nil }
        return output.map(Int.init)
    }
}

private enum CraftNativeFlexLineDistributionBridge {
    private typealias Function = @convention(c) (
        Float, Float, UInt32, UnsafeRawPointer, Int, UnsafeMutableRawPointer, UnsafeMutableRawPointer
    ) -> Int32

    private static let function: Function? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "craft_native_flex_line_distribution") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    static func distribute(available: CGFloat, gap: CGFloat, alignment: UInt32, lineCrosses: [CGFloat]) -> (offsets: [CGFloat], sizes: [CGFloat])? {
        guard let function, !lineCrosses.isEmpty else { return nil }
        var input = lineCrosses.map(Float.init)
        var offsets = [Float](repeating: 0, count: input.count)
        var sizes = [Float](repeating: 0, count: input.count)
        let status = input.withUnsafeBufferPointer { inputBuffer in
            offsets.withUnsafeMutableBufferPointer { offsetBuffer in
                sizes.withUnsafeMutableBufferPointer { sizeBuffer in
                    function(Float(available), Float(gap), alignment, UnsafeRawPointer(inputBuffer.baseAddress!), input.count, UnsafeMutableRawPointer(offsetBuffer.baseAddress!), UnsafeMutableRawPointer(sizeBuffer.baseAddress!))
                }
            }
        }
        guard status == 0, offsets.allSatisfy({ $0.isFinite }), sizes.allSatisfy({ $0.isFinite }) else { return nil }
        return (offsets.map { CGFloat($0) }, sizes.map { CGFloat($0) })
    }
}

/// Optional bridge to the shared cross-axis alignment rule. The local rule is
/// retained for runtimes built before this symbol was exported.
private enum CraftNativeCrossAxisBridge {
    private typealias Function = @convention(c) (Float, Float, Float, Float, UInt32) -> Float

    private static let function: Function? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "craft_native_cross_axis_position") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    static func position(available: CGFloat, size: CGFloat, leading: CGFloat, trailing: CGFloat, alignment: UInt32) -> CGFloat? {
        guard let function else { return nil }
        let result = function(Float(available), Float(size), Float(leading), Float(trailing), alignment)
        return result.isFinite ? CGFloat(result) : nil
    }
}

private enum CraftNativeGridBridge {
    private struct Item {
        var intrinsicWidth: Float
        var intrinsicHeight: Float
        var explicitWidth: Float
        var explicitHeight: Float
        var minWidth: Float
        var maxWidth: Float
        var minHeight: Float
        var maxHeight: Float
        var marginLeft: Float
        var marginRight: Float
        var marginTop: Float
        var marginBottom: Float
        var stretch: UInt32
        var alignment: UInt32
    }

    private struct Frame {
        var x: Float
        var y: Float
        var width: Float
        var height: Float
    }

    private typealias Function = @convention(c) (
        Float, Float, UInt32, Float, Float, UnsafeRawPointer, Int, UnsafeMutableRawPointer
    ) -> Int32
    private typealias AutoRowsFunction = @convention(c) (
        Float, Float, UInt32, Float, Float, Float, UnsafeRawPointer, Int, UnsafeMutableRawPointer
    ) -> Int32
    private typealias AlignedFunction = @convention(c) (
        Float, Float, UInt32, Float, Float, UInt32, UnsafeRawPointer, Int, UnsafeMutableRawPointer
    ) -> Int32
    private typealias AutoRowsAlignedFunction = @convention(c) (
        Float, Float, UInt32, Float, Float, UInt32, Float, UnsafeRawPointer, Int, UnsafeMutableRawPointer
    ) -> Int32

    private static let function: Function? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "craft_native_grid") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()
    private static let autoRowsFunction: AutoRowsFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "craft_native_grid_auto_rows") else { return nil }
        return unsafeBitCast(symbol, to: AutoRowsFunction.self)
    }()
    private static let alignedFunction: AlignedFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "craft_native_grid_aligned") else { return nil }
        return unsafeBitCast(symbol, to: AlignedFunction.self)
    }()
    private static let autoRowsAlignedFunction: AutoRowsAlignedFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "craft_native_grid_auto_rows_aligned") else { return nil }
        return unsafeBitCast(symbol, to: AutoRowsAlignedFunction.self)
    }()

    static func frames(
        availableWidth: CGFloat,
        availableHeight: CGFloat,
        columns: Int,
        columnGap: CGFloat,
        rowGap: CGFloat,
        items: [(intrinsicWidth: CGFloat, intrinsicHeight: CGFloat, explicitWidth: CGFloat?, explicitHeight: CGFloat?, minWidth: CGFloat?, maxWidth: CGFloat?, minHeight: CGFloat?, maxHeight: CGFloat?, marginLeft: CGFloat, marginRight: CGFloat, marginTop: CGFloat, marginBottom: CGFloat, stretch: Bool, alignment: UInt32)],
        autoRowHeight: CGFloat? = nil,
        alignContent: UInt32 = 0
    ) -> [(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)]? {
        guard !items.isEmpty else { return nil }
        if autoRowHeight != nil, autoRowsFunction == nil { return nil }
        if autoRowHeight == nil, function == nil { return nil }
        var input = items.map { item in
            Item(
                intrinsicWidth: Float(item.intrinsicWidth), intrinsicHeight: Float(item.intrinsicHeight),
                explicitWidth: item.explicitWidth.map(Float.init) ?? .nan, explicitHeight: item.explicitHeight.map(Float.init) ?? .nan,
                minWidth: item.minWidth.map(Float.init) ?? .nan, maxWidth: item.maxWidth.map(Float.init) ?? .nan,
                minHeight: item.minHeight.map(Float.init) ?? .nan, maxHeight: item.maxHeight.map(Float.init) ?? .nan,
                marginLeft: Float(item.marginLeft), marginRight: Float(item.marginRight),
                marginTop: Float(item.marginTop), marginBottom: Float(item.marginBottom),
                stretch: item.stretch ? 1 : 0, alignment: item.alignment
            )
        }
        var output = [Frame](repeating: Frame(x: 0, y: 0, width: 0, height: 0), count: input.count)
        let status = input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                if let autoRowHeight, let autoRowsFunction {
                    if alignContent != 0, let autoRowsAlignedFunction {
                        return autoRowsAlignedFunction(Float(availableWidth), Float(availableHeight), UInt32(max(1, columns)), Float(columnGap), Float(rowGap), alignContent, Float(autoRowHeight), UnsafeRawPointer(inputBuffer.baseAddress!), input.count, UnsafeMutableRawPointer(outputBuffer.baseAddress!))
                    }
                    return autoRowsFunction(Float(availableWidth), Float(availableHeight), UInt32(max(1, columns)), Float(columnGap), Float(rowGap), Float(autoRowHeight), UnsafeRawPointer(inputBuffer.baseAddress!), input.count, UnsafeMutableRawPointer(outputBuffer.baseAddress!))
                }
                if alignContent != 0, let alignedFunction {
                    return alignedFunction(Float(availableWidth), Float(availableHeight), UInt32(max(1, columns)), Float(columnGap), Float(rowGap), alignContent, UnsafeRawPointer(inputBuffer.baseAddress!), input.count, UnsafeMutableRawPointer(outputBuffer.baseAddress!))
                }
                guard let function else { return Int32(-1) }
                return function(Float(availableWidth), Float(availableHeight), UInt32(max(1, columns)), Float(columnGap), Float(rowGap), UnsafeRawPointer(inputBuffer.baseAddress!), input.count, UnsafeMutableRawPointer(outputBuffer.baseAddress!))
            }
        }
        guard status == 0, output.allSatisfy({ frame in
            frame.x.isFinite && frame.y.isFinite && frame.width.isFinite && frame.height.isFinite
        }) else { return nil }
        return output.map { (CGFloat($0.x), CGFloat($0.y), CGFloat($0.width), CGFloat($0.height)) }
    }
}

private func craftNativeAlignContentCode(_ value: String) -> UInt32 {
    switch value {
    case "center": return 1
    case "flex-end": return 2
    case "space-between": return 3
    case "space-around": return 4
    case "stretch": return 5
    case "space-evenly": return 6
    default: return 0
    }
}

/// Keep the indicator's intrinsic size separate from authored style transforms.
private final class CraftNativeActivityIndicatorView: UIActivityIndicatorView {
    var indicatorScale: CGFloat = 1
}

/// A native screen's `<Video>`: AVPlayerViewController in place.
///
/// With sound, a video takes the audio session as a playing sound does
/// (`CraftNativeSounds`): playback, mixed with the person's music, heard
/// through the silent switch, and with speech ducking the music under a cue
/// as it does for any other sound. With `pictureInPicture` it carries on in
/// the system's floating player when the app goes to the background or
/// another app opens (the app needs the `audio` background mode, which
/// `enableBackgroundAudio` writes), and comes back into its place when the
/// app does.
private final class CraftNativeVideoView: UIView, AVPlayerViewControllerDelegate {
    private let playerController = AVPlayerViewController()
    private var player: AVPlayer?
    private var sourceURI = ""
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var playingObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var loops = false
    private var requestedTime: Double?
    private var pendingSeek: Double?
    private var wasPlaying: Bool?
    private var playIntent: Bool?
    private var userPaused = false
    private var ended = false
    /// This video holds a claim on the audio session (`CraftNativeSounds`).
    private var claimedSession = false
    /// The screen's handlers by event name (`onEnd`, `onPlay`, `onPause`,
    /// `onProgress`, `onLoadStart`, `onLoad`, `onLoadEnd`, `onError`), and how
    /// an event reaches them.
    var handlers: [String: String] = [:]
    var emit: ((_ handler: String, _ nativeEvent: [String: Any]) -> Void)?

    init(host: UIViewController) {
        super.init(frame: .zero)
        clipsToBounds = true
        host.addChild(playerController)
        addSubview(playerController.view)
        playerController.didMove(toParent: host)
        // Expose the host view as the native Video node. The player controller
        // owns an accessibility subtree of its own, which otherwise masks the
        // host's testID and makes the component look like a WebView-backed view
        // to UI tests and assistive technology.
        playerController.view.isAccessibilityElement = false
        playerController.view.accessibilityElementsHidden = true
        playerController.delegate = self
        playerController.allowsPictureInPicturePlayback = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
        addSubview(playerController.view)
        playerController.view.isAccessibilityElement = false
        playerController.view.accessibilityElementsHidden = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerController.view.frame = bounds
    }

    private func fire(_ event: String, _ nativeEvent: [String: Any] = [:]) {
        guard let handler = handlers[event], !handler.isEmpty else { return }
        emit?(handler, nativeEvent)
    }

    private func seconds(_ time: CMTime?) -> Double {
        guard let time, time.isNumeric else { return 0 }
        let value = CMTimeGetSeconds(time)
        return value.isFinite ? value : 0
    }

    private func detachPlayer() {
        if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
        endObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        playingObservation?.invalidate()
        playingObservation = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        wasPlaying = nil
        player?.pause()
        player = nil
        releaseSession()
    }

    /// Playback, mixed with the music, before the player first makes a sound:
    /// an AVPlayer started under the app's default session stops the music.
    private func claimSession() {
        guard !claimedSession else { return }
        claimedSession = true
        CraftNativeSounds.claimSession(respectSilentSwitch: false)
    }

    private func releaseSession() {
        guard claimedSession else { return }
        claimedSession = false
        CraftNativeSounds.releaseSession()
    }

    private func applyPendingSeek() {
        guard let target = pendingSeek, let player, let item = player.currentItem, item.status == .readyToPlay else { return }
        let current = seconds(player.currentTime())
        pendingSeek = nil
        guard abs(current - target) > 0.25 else { return }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func configure(source: Any?, autoplay: Bool, paused: Bool, loop: Bool, muted: Bool, currentTime: Any?, controls: Bool, resizeMode: String?, pictureInPicture: Bool = false) {
        let uri = (source as? String) ?? (source as? [String: Any])?["uri"] as? String ?? ""
        let nextTime = number(currentTime).map(Double.init).map { max(0, $0) }
        if nextTime != requestedTime {
            requestedTime = nextTime
            pendingSeek = nextTime
        }
        let nextShouldPlay = autoplay && !paused
        if playIntent != nextShouldPlay {
            userPaused = false
            ended = false
        }
        playIntent = nextShouldPlay
        if uri != sourceURI {
            detachPlayer()
            sourceURI = uri
            userPaused = false
            ended = false
            loops = false
            pendingSeek = requestedTime
            // The copy `craft.media.keep` put on the phone plays in place of
            // the address, so a kept video plays with no signal.
            let kept = CraftNativeMedia.local(uri)
            guard let url = kept ?? URL(string: uri), !uri.isEmpty, kept != nil || url.scheme != nil else {
                playerController.player = nil
                // A path with no scheme ("/videos/a.mp4") has nowhere to load
                // from on a native screen. Say so rather than stay black.
                if !uri.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.sourceURI == uri else { return }
                        self.fire("onError", ["message": "The video address is not a full URL: \(uri)"])
                    }
                }
                return
            }
            let next = AVPlayer(url: url)
            fire("onLoadStart")
            player = next
            playerController.player = next
            observe(next)
        }
        guard let player else { return }
        applyPendingSeek()
        player.isMuted = muted
        // A muted video makes no sound, so it leaves the session as it is.
        if muted { releaseSession() } else { claimSession() }
        playerController.showsPlaybackControls = controls
        // The system's controls are for VoiceOver too; a bare video stays one element.
        playerController.view.accessibilityElementsHidden = !controls
        isUserInteractionEnabled = true
        playerController.videoGravity = resizeMode == "cover" ? .resizeAspectFill
            : resizeMode == "stretch" ? .resize
            : .resizeAspect
        // Picture in Picture needs the playback session, so a muted video has none.
        let floating = pictureInPicture && !muted
        playerController.allowsPictureInPicturePlayback = floating
        if #available(iOS 14.2, *) {
            playerController.canStartPictureInPictureAutomaticallyFromInline = floating
        }
        loops = loop
        if nextShouldPlay {
            if !userPaused && !ended { player.play() }
        } else {
            player.pause()
        }
    }

    // MARK: AVPlayerViewControllerDelegate

    /// The video stays in its place on the screen while it floats.
    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool {
        false
    }

    /// Back from the floating player (the app came back, or its button was
    /// tapped): the video is still in its place, so there is nothing to put back.
    func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(player != nil)
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        fire("onPictureInPictureStart")
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        fire("onPictureInPictureStop")
    }

    /// Load, play and pause, time, the end and failure, as the web's video
    /// element reports them, so `@ended` and `@timeupdate` work as on the page.
    private func observe(_ player: AVPlayer) {
        if let item = player.currentItem {
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self, self.player?.currentItem === item else { return }
                    switch item.status {
                    case .readyToPlay:
                        self.applyPendingSeek()
                        self.fire("onLoad", ["duration": self.seconds(item.duration)])
                        self.fire("onLoadEnd")
                    case .failed: self.fire("onError", ["message": item.error?.localizedDescription ?? "The video could not be played"])
                    default: break
                    }
                }
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak player] _ in
                guard let self else { return }
                self.ended = !self.loops
                self.fire("onEnd")
                if self.loops {
                    self.ended = false
                    player?.seek(to: .zero) { _ in player?.play() }
                }
            }
        }
        playingObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self, self.player === player, player.timeControlStatus != .waitingToPlayAtSpecifiedRate else { return }
                let playing = player.timeControlStatus == .playing
                guard playing != self.wasPlaying else { return }
                // Paused before it ever played is where it starts, not news.
                if self.wasPlaying == nil && !playing { self.wasPlaying = false; return }
                self.wasPlaying = playing
                if playing {
                    self.userPaused = false
                    self.ended = false
                } else if self.playIntent == true {
                    self.userPaused = true
                }
                self.fire(playing ? "onPlay" : "onPause")
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self, weak player] time in
            guard let self, let player, player.timeControlStatus == .playing else { return }
            self.fire("onProgress", ["currentTime": self.seconds(time), "duration": self.seconds(player.currentItem?.duration)])
        }
    }

    func stop() {
        detachPlayer()
        playerController.player = nil
        playerController.delegate = nil
        sourceURI = ""
        requestedTime = nil
        pendingSeek = nil
        playIntent = nil
        userPaused = false
        ended = false
        handlers.removeAll()
        emit = nil
        if playerController.parent != nil {
            playerController.willMove(toParent: nil)
            playerController.view.removeFromSuperview()
            playerController.removeFromParent()
        }
    }

    deinit { stop() }
}

/// A map pin that answers being activated as it answers a tap.
final class CraftMarkerAnnotationView: MKAnnotationView {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return super.accessibilityActivate() }
        onActivate()
        return true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onActivate = nil
    }
}

/// A tile overlay whose tiles are kept on disk.
///
/// MKTileOverlay asked the network for every tile on every pan back over the
/// same ground, and drew nothing where a tile had not come yet. These go
/// through one session with a cache of its own (Caches/craft-map-tiles), so
/// ground seen before draws at once and offline, and a phone on a trail
/// does not fetch the same hillside twice.
final class CraftCachedTileOverlay: MKTileOverlay {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("craft-map-tiles", isDirectory: true)
        configuration.urlCache = URLCache(memoryCapacity: 48 << 20, diskCapacity: 512 << 20, directory: directory)
        // Topography and imagery change on the scale of months: a tile held
        // is used without asking again.
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: configuration)
    }()

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let request = URLRequest(url: url(forTilePath: path), cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        Self.session.dataTask(with: request) { data, response, error in
            if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                result(nil, error ?? URLError(.badServerResponse))
                return
            }
            result(data, error)
        }.resume()
    }
}

/// The basemaps a `Map` names with `basemap`, drawn the best way each
/// platform can: Apple's vector map (with real terrain from iOS 16) for
/// standard, imagery and hybrid, and topography with contours over a muted
/// Apple map for outdoors.
enum CraftBasemap: String {
    case standard, outdoors, satellite, hybrid

    static let outdoorTiles = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/{z}/{y}/{x}"
    static let outdoorCredit = "Topography: Esri, USGS, NOAA, OpenStreetMap contributors"
}

private final class CraftMarkerPhotoRedirects: NSObject, URLSessionTaskDelegate {
    static let session = URLSession(configuration: .ephemeral, delegate: CraftMarkerPhotoRedirects(), delegateQueue: nil)

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        completionHandler(url?.scheme?.lowercased() == "https" && url?.user == nil && url?.password == nil ? request : nil)
    }
}

private final class CraftNativeMapView: MKMapView, MKMapViewDelegate {
    private var annotationsByID: [String: MKPointAnnotation] = [:]
    private var overlaysByID: [String: MKPolyline] = [:]
    private var overlayCoordinatesByID: [String: [CLLocationCoordinate2D]] = [:]
    private var overlayColors: [ObjectIdentifier: UIColor] = [:]
    private var overlayWidths: [ObjectIdentifier: CGFloat] = [:]
    private var polygonsByID: [String: MKPolygon] = [:]
    private var polygonCoordinatesByID: [String: [CLLocationCoordinate2D]] = [:]
    private var polygonFills: [ObjectIdentifier: UIColor] = [:]
    private var polygonStrokes: [ObjectIdentifier: UIColor] = [:]
    private var polygonWidths: [ObjectIdentifier: CGFloat] = [:]
    private var initialCameraKey: String?
    private var pendingFitKey: String?
    private var pendingRegion: MKCoordinateRegion?
    private(set) var markerHandlers: [String: String] = [:]
    var onMarkerTap: ((String) -> Void)?
    var onMapPress: ((CLLocationCoordinate2D) -> Void)?
    var onRegionChangeComplete: ((MKCoordinateRegion, Double, Double) -> Void)?
    private var userChangingCamera = false
    private var authoredPitch: Double?
    private var authoredHeading: Double?
    private var edgePadding = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    private var markerBearings: [String: Double] = [:]
    private var markerPinColors: [String: UIColor] = [:]
    private struct MarkerPhoto: Equatable {
        let url: URL
        let size: CGFloat
        let circle: Bool

        init?(_ props: [String: Any]) {
            guard let raw = props["image"] as? String, let url = URL(string: raw),
                  url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else { return nil }
            self.url = url
            // Current STX releases preserve unknown HTML/binding spellings.
            let value = CraftNativeMapView.numeric(props["imageSize"] ?? props["imagesize"] ?? props["image-size"]) ?? 30
            size = CGFloat(value.isFinite ? min(96, max(16, value)) : 30)
            circle = (props["imageShape"] ?? props["imageshape"] ?? props["image-shape"]) as? String != "square"
        }
    }
    private var markerPhotos: [String: MarkerPhoto] = [:]
    private var markerPhotoImages: [String: UIImage] = [:]
    private var markerPhotoTasks: [String: URLSessionDataTask] = [:]
    private var markerPhotoRequests: [String: UUID] = [:]
    private var tileOverlay: MKTileOverlay?
    private var tileTemplate: String?
    private var tileReplacesMap = true
    private var appliedBasemap: CraftBasemap?
    private var tileAttributionBottom: NSLayoutConstraint?
    private lazy var tileAttribution: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 9)
        label.textColor = .darkGray
        label.backgroundColor = UIColor.white.withAlphaComponent(0.85)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 2
        addSubview(label)
        let bottom = label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        tileAttributionBottom = bottom
        NSLayoutConstraint.activate([label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), bottom, label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 48)])
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        refreshThemeDefaults()
        showsCompass = false
        showsScale = false
        isRotateEnabled = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(pressedMap(_:)))
        tap.cancelsTouchesInView = false
        // Alongside MapKit's own recognizers, not instead of them: on its own
        // this tap won the touch, MapKit never selected the pin under it, and
        // a pin's onPress (Explore's trail card) never fired on a phone.
        tap.delegate = CraftMapTapDelegate.shared
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
        refreshThemeDefaults()
    }

    func refreshThemeDefaults() {
        tileAttribution.textColor = .secondaryLabel
        tileAttribution.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.85)
        // Marker images are rasterized from the resolved trait color. Refresh
        // mounted annotations as well as the utility chrome so a retained map
        // does not keep light-trait artwork after a dark-mode switch.
        Self.markerImages.removeAllObjects()
        for (id, annotation) in annotationsByID {
            if let view = view(for: annotation) { configureMarkerView(view, id: id) }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        refreshThemeDefaults()
    }

    func configure(props: [String: Any], children: [Any], markerHandler: @escaping (String) -> Void) {
        delegate = self
        onMarkerTap = markerHandler
        isScrollEnabled = props["scrollEnabled"] as? Bool ?? true
        isZoomEnabled = props["zoomEnabled"] as? Bool ?? true
        isRotateEnabled = props["rotateEnabled"] as? Bool ?? false
        isPitchEnabled = props["pitchEnabled"] as? Bool ?? true
        if let basemap = (props["basemap"] as? String).flatMap({ CraftBasemap(rawValue: $0.lowercased()) }) {
            applyBasemap(basemap)
        } else {
            appliedBasemap = nil
            mapType = Self.mapType(props["mapType"] as? String)
            configureTiles(props["tileOverlay"] as? [String: Any])
        }
        showsCompass = props["showsCompass"] as? Bool ?? false
        showsScale = props["showsScale"] as? Bool ?? false
        authoredPitch = Self.numeric(props["cameraPitch"])
        authoredHeading = Self.numeric(props["cameraHeading"])
        let padding = props["edgePadding"] as? [String: Any]
        func inset(_ name: String) -> CGFloat {
            guard let value = Self.numeric(padding?[name]), value.isFinite else { return 24 }
            return CGFloat(min(10_000, max(0, value)))
        }
        edgePadding = UIEdgeInsets(top: inset("top"), left: inset("left"), bottom: inset("bottom"), right: inset("right"))
        var nextBearings: [String: Double] = [:]
        var nextPinColors: [String: UIColor] = [:]
        var nextPhotos: [String: MarkerPhoto] = [:]
        // Showing the user dot must not trigger a permission prompt from a
        // renderer pass. The app's existing location capability owns that
        // prompt; a map only opts in after authorization is already granted.
        showsUserLocation = props["showsUserLocation"] as? Bool == true && Self.locationPermissionGranted()

        var nextMarkers: [String: (coordinate: CLLocationCoordinate2D, title: String?)] = [:]
        var nextHandlers: [String: String] = [:]
        var nextPolylines: [String: (coordinates: [CLLocationCoordinate2D], color: UIColor, width: CGFloat)] = [:]
        var nextPolylineIDs: [String] = []
        var nextPolygons: [String: (coordinates: [CLLocationCoordinate2D], fill: UIColor, stroke: UIColor, width: CGFloat)] = [:]
        if let polylines = props["polylines"] as? [[String: Any]] {
            for overlay in polylines {
                let points = Self.coordinates(overlay["geometry"])
                guard let id = (overlay["id"] as? CustomStringConvertible)?.description,
                      points.count > 1 else { continue }
                let authoredWidth = Self.numeric(overlay["strokeWidth"]) ?? 3
                let width = CGFloat(authoredWidth)
                guard authoredWidth.isFinite, width.isFinite, width > 0 else { continue }
                nextPolylineIDs.append(id)
                nextPolylines[id] = (points, Self.color(overlay["strokeColor"] as? String), width)
            }
        }
        if let markers = props["markers"] as? [[String: Any]] {
            for overlay in markers {
                let points = Self.coordinates(overlay["geometry"])
                guard let id = (overlay["id"] as? CustomStringConvertible)?.description,
                      let point = points.first else { continue }
                nextMarkers[id] = (point, overlay["title"] as? String)
                nextPhotos[id] = MarkerPhoto(overlay)
                if let color = overlay["pinColor"] as? String { nextPinColors[id] = Self.color(color) }
                if let bearing = Self.numeric(overlay["bearing"]), bearing.isFinite {
                    nextBearings[id] = bearing.truncatingRemainder(dividingBy: 360)
                }
            }
        }
        for (index, child) in children.enumerated() {
            guard let node = child as? [String: Any], let rawType = node["type"] as? String else { continue }
            let type = rawType.lowercased()
            let childProps = node["props"] as? [String: Any] ?? [:]
            let childEvents = node["events"] as? [String: String] ?? [:]
            let id = (childProps["id"] as? CustomStringConvertible)?.description
                ?? (node["id"] as? String)
                ?? "overlay-\(index)"
            let points = Self.coordinates(childProps["geometry"])
            if type == "mapmarker" || type == "marker" {
                guard let point = points.first else { continue }
                nextMarkers[id] = (point, childProps["title"] as? String)
                nextPhotos[id] = MarkerPhoto(childProps)
                if let color = childProps["pinColor"] as? String { nextPinColors[id] = Self.color(color) }
                if let bearing = Self.numeric(childProps["bearing"]), bearing.isFinite {
                    nextBearings[id] = bearing.truncatingRemainder(dividingBy: 360)
                }
                if let handler = nonEmptyHandler(childEvents["onPress"])
                    ?? nonEmptyHandler(childEvents["onMarkerPress"]) {
                    nextHandlers[id] = handler
                }
            } else if type == "mappolyline" || type == "polyline" {
                guard points.count > 1 else { continue }
                let authoredWidth = Self.numeric(childProps["strokeWidth"]) ?? 3
                let width = CGFloat(authoredWidth)
                guard authoredWidth.isFinite, width.isFinite, width > 0 else { continue }
                if nextPolylines[id] == nil { nextPolylineIDs.append(id) }
                nextPolylines[id] = (points, Self.color(childProps["strokeColor"] as? String), width)
            } else if type == "mappolygon" || type == "polygon" {
                guard points.count > 2 else { continue }
                let authoredWidth = Self.numeric(childProps["strokeWidth"]) ?? 2
                let width = CGFloat(authoredWidth)
                guard authoredWidth.isFinite, width.isFinite, width > 0 else { continue }
                let fill = Self.color(childProps["fillColor"] as? String).withAlphaComponent(0.28)
                let stroke = Self.color(childProps["strokeColor"] as? String)
                nextPolygons[id] = (points, fill, stroke, width)
            }
        }

        markerBearings = nextBearings
        markerPinColors = nextPinColors
        for id in markerPhotos.keys where markerPhotos[id] != nextPhotos[id] {
            markerPhotoTasks.removeValue(forKey: id)?.cancel()
            markerPhotoRequests.removeValue(forKey: id)
            markerPhotoImages.removeValue(forKey: id)
        }
        markerPhotos = nextPhotos
        let staleMarkers = annotationsByID.keys.filter { nextMarkers[$0] == nil }
        removeAnnotations(staleMarkers.compactMap { annotationsByID.removeValue(forKey: $0) })
        for (id, value) in nextMarkers {
            if let annotation = annotationsByID[id] {
                annotation.coordinate = value.coordinate
                annotation.title = value.title
                if let view = view(for: annotation) { configureMarkerView(view, id: id) }
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = value.coordinate
                annotation.title = value.title
                annotationsByID[id] = annotation
                addAnnotation(annotation)
            }
        }
        markerHandlers = nextHandlers
        for (id, photo) in markerPhotos where markerPhotoRequests[id] == nil {
            loadMarkerPhoto(photo, id: id)
        }

        let staleOverlays = overlaysByID.keys.filter { nextPolylines[$0] == nil }
        for id in staleOverlays {
            if let overlay = overlaysByID.removeValue(forKey: id) {
                removeOverlay(overlay)
                overlayColors.removeValue(forKey: ObjectIdentifier(overlay))
                overlayWidths.removeValue(forKey: ObjectIdentifier(overlay))
            }
            overlayCoordinatesByID.removeValue(forKey: id)
        }
        for id in nextPolylineIDs {
            guard let value = nextPolylines[id] else { continue }
            if let overlay = overlaysByID[id],
               let coordinates = overlayCoordinatesByID[id],
               Self.coordinatesEqual(coordinates, value.coordinates),
               overlayColors[ObjectIdentifier(overlay)]?.isEqual(value.color) == true,
               overlayWidths[ObjectIdentifier(overlay)] == value.width {
                continue
            }
            if let previous = overlaysByID.removeValue(forKey: id) {
                removeOverlay(previous)
                overlayColors.removeValue(forKey: ObjectIdentifier(previous))
                overlayWidths.removeValue(forKey: ObjectIdentifier(previous))
            }
            let overlay = MKPolyline(coordinates: value.coordinates, count: value.coordinates.count)
            overlaysByID[id] = overlay
            overlayCoordinatesByID[id] = value.coordinates
            overlayColors[ObjectIdentifier(overlay)] = value.color
            overlayWidths[ObjectIdentifier(overlay)] = value.width
            // Above labels, as a basemap's topography is: at a lower level
            // the outdoors layer covered every route drawn on it.
            addOverlay(overlay, level: .aboveLabels)
        }
        let stalePolygons = polygonsByID.keys.filter { nextPolygons[$0] == nil }
        for id in stalePolygons {
            if let polygon = polygonsByID.removeValue(forKey: id) {
                removeOverlay(polygon)
                polygonFills.removeValue(forKey: ObjectIdentifier(polygon))
                polygonStrokes.removeValue(forKey: ObjectIdentifier(polygon))
                polygonWidths.removeValue(forKey: ObjectIdentifier(polygon))
            }
            polygonCoordinatesByID.removeValue(forKey: id)
        }
        for (id, value) in nextPolygons {
            if let polygon = polygonsByID[id],
               let coordinates = polygonCoordinatesByID[id],
               Self.coordinatesEqual(coordinates, value.coordinates),
               polygonFills[ObjectIdentifier(polygon)]?.isEqual(value.fill) == true,
               polygonStrokes[ObjectIdentifier(polygon)]?.isEqual(value.stroke) == true,
               polygonWidths[ObjectIdentifier(polygon)] == value.width {
                continue
            }
            if let previous = polygonsByID.removeValue(forKey: id) {
                removeOverlay(previous)
                polygonFills.removeValue(forKey: ObjectIdentifier(previous))
                polygonStrokes.removeValue(forKey: ObjectIdentifier(previous))
                polygonWidths.removeValue(forKey: ObjectIdentifier(previous))
            }
            let polygon = MKPolygon(coordinates: value.coordinates, count: value.coordinates.count)
            polygonsByID[id] = polygon
            polygonCoordinatesByID[id] = value.coordinates
            polygonFills[ObjectIdentifier(polygon)] = value.fill
            polygonStrokes[ObjectIdentifier(polygon)] = value.stroke
            polygonWidths[ObjectIdentifier(polygon)] = value.width
            addOverlay(polygon, level: .aboveLabels)
        }
        // Keep authored casing/foreground order when an earlier line changes
        // or retained children move. Exchanging native overlays preserves the
        // unchanged objects, tile levels and current camera.
        let ownedOverlayIDs = Set(overlaysByID.values.map { ObjectIdentifier($0) })
        var orderedOverlays = overlays.compactMap { $0 as? MKPolyline }
            .filter { ownedOverlayIDs.contains(ObjectIdentifier($0)) }
        for (index, id) in nextPolylineIDs.enumerated() {
            guard let overlay = overlaysByID[id], index < orderedOverlays.count,
                  orderedOverlays[index] !== overlay,
                  let previousIndex = orderedOverlays.firstIndex(where: { $0 === overlay }) else { continue }
            exchangeOverlay(orderedOverlays[index], with: orderedOverlays[previousIndex])
            orderedOverlays.swapAt(index, previousIndex)
        }

        if let region = Self.region(props["region"]) {
            // `region` is controlled: an authored change is allowed to move
            // the camera, even when the map itself was already mounted.
            pendingFitKey = nil
            pendingRegion = bounds.width > 0 && bounds.height > 0 ? nil : region
            if abs(self.region.center.latitude - region.center.latitude) > 0.00000001
                || abs(self.region.center.longitude - region.center.longitude) > 0.00000001
                || abs(self.region.span.latitudeDelta - region.span.latitudeDelta) > 0.00000001
                || abs(self.region.span.longitudeDelta - region.span.longitudeDelta) > 0.00000001 {
                setRegion(region, animated: false)
            }
            initialCameraKey = nil
        } else if let initial = Self.region(props["initialRegion"]) {
            pendingFitKey = nil
            let key = "region:\(Self.regionKey(initial))"
            if initialCameraKey != key {
                pendingRegion = bounds.width > 0 && bounds.height > 0 ? nil : initial
                setRegion(initial, animated: false)
                initialCameraKey = key
            }
        } else if props["fitToBounds"] as? Bool == true {
            let key = "fit:\(Self.overlayKey(markers: nextMarkers.mapValues { $0.coordinate }, polylines: nextPolylines.mapValues { $0.coordinates }, polygons: nextPolygons.mapValues { $0.coordinates })):\(edgePadding)"
            if initialCameraKey != key {
                // A native screen can reconcile before UIKit assigns the map
                // its final safe-area-constrained bounds. Keep the fit
                // pending until there is a real viewport, matching Android's
                // onSizeChanged retry instead of silently accepting a no-op.
                pendingFitKey = key
                if fitToOverlays() {
                    initialCameraKey = key
                    pendingFitKey = nil
                }
            }
        } else {
            initialCameraKey = nil
            pendingFitKey = nil
        }
        applyCameraOrientation()
    }

    /// Release callbacks and native overlays before a map leaves a screen or
    /// is recycled for another row. `configure` restores the delegate when
    /// the view is adopted again.
    func destroy() {
        delegate = nil
        onMarkerTap = nil
        onMapPress = nil
        onRegionChangeComplete = nil
        markerHandlers.removeAll()
        markerBearings.removeAll()
        markerPinColors.removeAll()
        markerPhotoTasks.values.forEach { $0.cancel() }
        markerPhotoTasks.removeAll()
        markerPhotoRequests.removeAll()
        markerPhotoImages.removeAll()
        markerPhotos.removeAll()
        removeAnnotations(Array(annotationsByID.values))
        annotationsByID.removeAll()
        removeOverlays(Array(overlaysByID.values))
        overlaysByID.removeAll()
        overlayCoordinatesByID.removeAll()
        overlayColors.removeAll()
        overlayWidths.removeAll()
        removeOverlays(Array(polygonsByID.values))
        polygonsByID.removeAll()
        polygonCoordinatesByID.removeAll()
        polygonFills.removeAll()
        polygonStrokes.removeAll()
        polygonWidths.removeAll()
        if let tileOverlay {
            removeOverlay(tileOverlay)
            self.tileOverlay = nil
        }
        tileTemplate = nil
        tileAttribution.text = nil
        tileAttribution.isHidden = true
    }

    /// A named basemap. Applied once per change: setting a map configuration
    /// again redraws the whole map.
    private func applyBasemap(_ basemap: CraftBasemap) {
        if appliedBasemap != basemap {
            appliedBasemap = basemap
            if #available(iOS 16.0, *) {
                switch basemap {
                case .satellite: preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
                case .hybrid: preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
                // Flat under the topography, so the overlay's contours sit
                // on the ground they describe.
                case .outdoors: preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
                case .standard: preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
                }
            }
            else {
                mapType = basemap == .satellite ? .satellite : basemap == .hybrid ? .hybrid : basemap == .outdoors ? .mutedStandard : .standard
            }
        }
        configureTiles(basemap == .outdoors ? ["urlTemplate": CraftBasemap.outdoorTiles, "attribution": CraftBasemap.outdoorCredit] : nil, replacesMap: false)
    }

    /// `replacesMap`: an authored `tileOverlay` replaces Apple's map, as it
    /// always has. A basemap's topography draws over it instead, above its
    /// labels, so ground whose tiles have not come yet shows the map rather
    /// than an empty grid.
    private func configureTiles(_ options: [String: Any]?, replacesMap: Bool = true) {
        let template = options?["urlTemplate"] as? String
        let credit = options?["attribution"] as? String ?? ""
        let valid = template.map { value in value.hasPrefix("https://") && ["{z}", "{x}", "{y}"].allSatisfy { value.contains($0) } } ?? false
        let next = valid && !credit.isEmpty ? template : nil
        if tileTemplate != next || tileReplacesMap != replacesMap {
            if let overlay = tileOverlay { removeOverlay(overlay) }
            tileOverlay = nil
            tileTemplate = next
            tileReplacesMap = replacesMap
            if let next {
                let overlay = CraftCachedTileOverlay(urlTemplate: next)
                overlay.canReplaceMapContent = replacesMap
                overlay.maximumZ = 19
                tileOverlay = overlay
                insertOverlay(overlay, at: 0, level: replacesMap ? .aboveRoads : .aboveLabels)
            }
        }
        tileAttribution.text = next == nil ? nil : credit
        tileAttribution.isHidden = next == nil
    }

    private func applyCameraOrientation() {
        // Region-to-altitude conversion needs a measured viewport. Applying
        // pitch to the zero-altitude camera before layout clamps it to zero.
        guard bounds.width > 0, bounds.height > 0 else { return }
        let next = camera.copy() as! MKMapCamera
        var changed = false
        if let pitch = authoredPitch, pitch.isFinite {
            let value = CGFloat(min(60, max(0, pitch)))
            if abs(next.pitch - value) > 0.01 { next.pitch = value; changed = true }
        }
        if let heading = authoredHeading, heading.isFinite {
            let value = heading.truncatingRemainder(dividingBy: 360)
            if abs(next.heading - value) > 0.01 { next.heading = value; changed = true }
        }
        if changed { setCamera(next, animated: false) }
    }

    @objc private func pressedMap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, onMapPress != nil else { return }
        let point = gesture.location(in: self)
        var touched = hitTest(point, with: nil)
        while let view = touched, view !== self {
            if view is MKAnnotationView { return }
            touched = view.superview
        }
        onMapPress?(convert(point, toCoordinateFrom: self))
    }

    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        func interacting(_ view: UIView) -> Bool {
            if view.gestureRecognizers?.contains(where: { [.began, .changed, .ended].contains($0.state) }) == true { return true }
            return view.subviews.contains(where: interacting)
        }
        userChangingCamera = userChangingCamera || interacting(self)
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        for (id, annotation) in annotationsByID {
            if let view = view(for: annotation) { configureMarkerView(view, id: id) }
        }
        if userChangingCamera {
            userChangingCamera = false
            onRegionChangeComplete?(region, camera.heading, Double(camera.pitch))
        }
    }

    private func configureMarkerView(_ view: MKAnnotationView, id: String) {
        if let photo = markerPhotoImages[id] {
            view.image = photo
            view.transform = .identity
            view.displayPriority = .required
            view.collisionMode = markerPhotos[id]?.circle == true ? .circle : .rectangle
            if #available(iOS 14.0, *) { view.zPriority = .max }
            view.isAccessibilityElement = true
            view.accessibilityTraits = .button
        } else if let bearing = markerBearings[id] {
            let color = (markerPinColors[id] ?? .systemGreen).resolvedColor(with: traitCollection)
            view.tintColor = color
            view.image = Self.markerImage(color: color, direction: true)
            view.transform = CGAffineTransform(rotationAngle: CGFloat((bearing - camera.heading) * .pi / 180))
            // Direction marks thin themselves: MapKit hides the ones that
            // would overlap at this zoom and brings them back closer in, so
            // a trail reads as a line with chevrons along it, not a column of
            // badges over the route.
            view.displayPriority = .defaultLow
            view.collisionMode = .circle
            // Decoration along the route: not a stop for VoiceOver.
            view.isAccessibilityElement = false
        } else {
            let color = (markerPinColors[id] ?? .systemRed).resolvedColor(with: traitCollection)
            view.tintColor = color
            view.image = Self.markerImage(color: color, direction: false)
            view.transform = .identity
            view.displayPriority = .required
            view.collisionMode = .rectangle
            // Above the user's own location: at a trailhead - where the map
            // is most often opened - the dot sat on the trail's pin and took
            // every tap meant for it.
            if #available(iOS 14.0, *) { view.zPriority = .max }
            view.isAccessibilityElement = true
            view.accessibilityTraits = .button
        }
    }

    private func loadMarkerPhoto(_ photo: MarkerPhoto, id: String) {
        let request = UUID()
        markerPhotoRequests[id] = request
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let finish: (Data?) -> Void = { [weak self] data in
            let pixels = CGSize(width: photo.size * scale, height: photo.size * scale)
            let decoded = data.flatMap { $0.count <= 8 * 1024 * 1024 ? CraftNativeScreenController.decodeImage($0, fitting: (pixels, scale), fill: true) : nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.markerPhotoRequests[id] == request else { return }
                self.markerPhotoTasks.removeValue(forKey: id)
                guard let decoded, decoded.size.width > 0, decoded.size.height > 0 else { return }
                let size = CGSize(width: photo.size, height: photo.size)
                let format = UIGraphicsImageRendererFormat()
                format.scale = scale
                self.markerPhotoImages[id] = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    let bounds = CGRect(origin: .zero, size: size)
                    if photo.circle { UIBezierPath(ovalIn: bounds).addClip() }
                    let factor = max(photo.size / decoded.size.width, photo.size / decoded.size.height)
                    let drawn = CGSize(width: decoded.size.width * factor, height: decoded.size.height * factor)
                    decoded.draw(in: CGRect(x: (photo.size - drawn.width) / 2, y: (photo.size - drawn.height) / 2,
                                            width: drawn.width, height: drawn.height))
                }.withRenderingMode(.alwaysOriginal)
                if let annotation = self.annotationsByID[id], let view = self.view(for: annotation) {
                    self.configureMarkerView(view, id: id)
                }
            }
        }
        if let local = CraftNativeMedia.local(photo.url.absoluteString) {
            DispatchQueue.global(qos: .userInitiated).async { finish(try? Data(contentsOf: local)) }
        } else {
            let task = CraftMarkerPhotoRedirects.session.dataTask(with: photo.url) { data, response, _ in
                let response = response as? HTTPURLResponse
                finish(response?.statusCode == 200 && response?.url?.scheme?.lowercased() == "https" ? data : nil)
            }
            markerPhotoTasks[id] = task
            task.resume()
        }
    }

    private static let markerImages: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        return cache
    }()

    private static func markerImage(color: UIColor, direction: Bool) -> UIImage {
        let key = "\(direction ? "chevron" : "pin"):\(color.description)" as NSString
        if let cached = markerImages.object(forKey: key) { return cached }
        if direction { return directionImage(color: color, key: key) }
        let size = CGSize(width: 28, height: 28)
        // Explicit native drawing preserves the light backing independently
        // of MapKit's tint and SF Symbols' multicolor rendering preferences.
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let border = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1),
                                      cornerRadius: (size.width - 2) / 2)
            UIColor.white.setFill()
            border.fill()
            color.setStroke()
            border.lineWidth = 1.5
            border.stroke()
            let symbol = UIImage(systemName: direction ? "arrow.up" : "mappin",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))?
                .withTintColor(color, renderingMode: .alwaysOriginal)
            symbol?.draw(in: CGRect(x: 7, y: 5, width: 14, height: 18))
        }.withRenderingMode(.alwaysOriginal)
        markerImages.setObject(image, forKey: key)
        return image
    }

    /// A route's direction: a 16-point chevron in the route's colour with a
    /// white edge, so it sits on the line it describes and stays legible
    /// over topography and imagery alike.
    private static func directionImage(color: UIColor, key: NSString) -> UIImage {
        let size = CGSize(width: 16, height: 16)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let chevron = UIBezierPath()
            chevron.move(to: CGPoint(x: 8, y: 2.5))
            chevron.addLine(to: CGPoint(x: 13.5, y: 12))
            chevron.addLine(to: CGPoint(x: 8, y: 9.25))
            chevron.addLine(to: CGPoint(x: 2.5, y: 12))
            chevron.close()
            chevron.lineJoinStyle = .round
            context.cgContext.setShadow(offset: .zero, blur: 1.5, color: UIColor.black.withAlphaComponent(0.25).cgColor)
            UIColor.white.setStroke()
            chevron.lineWidth = 3
            chevron.stroke()
            context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            color.setFill()
            chevron.fill()
        }.withRenderingMode(.alwaysOriginal)
        markerImages.setObject(image, forKey: key)
        return image
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if tileTemplate != nil {
            tileAttributionBottom?.constant = -min(edgePadding.bottom, max(0, bounds.height - 40)) - 8
            bringSubviewToFront(tileAttribution)
        }
        if let region = pendingRegion, bounds.width > 0, bounds.height > 0 {
            pendingRegion = nil
            setRegion(region, animated: false)
            applyCameraOrientation()
        }
        guard let key = pendingFitKey else { return }
        pendingFitKey = nil
        guard fitToOverlays() else {
            pendingFitKey = key
            return
        }
        initialCameraKey = key
        applyCameraOrientation()
    }

    @discardableResult
    private func fitToOverlays() -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }
        var rect = MKMapRect.null
        for overlay in overlaysByID.values { rect = rect.union(overlay.boundingMapRect) }
        for polygon in polygonsByID.values { rect = rect.union(polygon.boundingMapRect) }
        for annotation in annotationsByID.values {
            let point = MKMapPoint(annotation.coordinate)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        guard !rect.isNull else { return false }
        var inset = edgePadding
        let horizontal = inset.left + inset.right
        let vertical = inset.top + inset.bottom
        let availableWidth = max(0, bounds.width - 40)
        let availableHeight = max(0, bounds.height - 40)
        if horizontal > availableWidth && horizontal > 0 {
            inset.left *= availableWidth / horizontal
            inset.right *= availableWidth / horizontal
        }
        if vertical > availableHeight && vertical > 0 {
            inset.top *= availableHeight / vertical
            inset.bottom *= availableHeight / vertical
        }
        setVisibleMapRect(rect, edgePadding: inset, animated: false)
        return true
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard let id = annotationsByID.first(where: { $0.value === annotation })?.key else { return nil }
        let view = (dequeueReusableAnnotationView(withIdentifier: "craft-native-marker") as? CraftMarkerAnnotationView)
            ?? CraftMarkerAnnotationView(annotation: annotation, reuseIdentifier: "craft-native-marker")
        view.annotation = annotation
        // Activated (VoiceOver, Switch Control, a UI test) as a tap would:
        // the plain annotation view did nothing when activated.
        view.onActivate = { [weak self] in self?.onMarkerTap?(id) }
        configureMarkerView(view, id: id)
        view.accessibilityIdentifier = id
        return view
    }

    func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
        guard let id = annotationsByID.first(where: { $0.value === annotation })?.key else { return }
        onMarkerTap?(id)
        deselectAnnotation(annotation, animated: false)
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
        if let polygon = overlay as? MKPolygon {
            let renderer = MKPolygonRenderer(polygon: polygon)
            renderer.fillColor = polygonFills[ObjectIdentifier(polygon)] ?? UIColor.systemBlue.withAlphaComponent(0.28)
            renderer.strokeColor = polygonStrokes[ObjectIdentifier(polygon)] ?? .systemBlue
            renderer.lineWidth = polygonWidths[ObjectIdentifier(polygon)] ?? 2
            return renderer
        }
        let renderer = MKPolylineRenderer(overlay: overlay)
        renderer.strokeColor = overlayColors[ObjectIdentifier(overlay)] ?? .systemBlue
        renderer.lineWidth = overlayWidths[ObjectIdentifier(overlay)] ?? 3
        return renderer
    }

    private static func coordinates(_ value: Any?) -> [CLLocationCoordinate2D] {
        let numbers = (value as? [Any])?.compactMap(Self.numeric)
            ?? (value as? [NSNumber])?.compactMap(Self.numeric)
            ?? []
        return stride(from: 0, to: numbers.count - 1, by: 2).compactMap {
            let latitude = numbers[$0]
            let longitude = numbers[$0 + 1]
            guard latitude.isFinite, longitude.isFinite,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    private static func coordinatesEqual(_ lhs: [CLLocationCoordinate2D], _ rhs: [CLLocationCoordinate2D]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.latitude == right.latitude && left.longitude == right.longitude
        }
    }

    private static func regionKey(_ region: MKCoordinateRegion) -> String {
        "\(region.center.latitude),\(region.center.longitude),\(region.span.latitudeDelta),\(region.span.longitudeDelta)"
    }

    private static func overlayKey(
        markers: [String: CLLocationCoordinate2D],
        polylines: [String: [CLLocationCoordinate2D]],
        polygons: [String: [CLLocationCoordinate2D]]
    ) -> String {
        let markerKey = markers.keys.sorted().compactMap { id in
            guard let point = markers[id] else { return nil }
            return "\(id):\(point.latitude),\(point.longitude)"
        }.joined(separator: "|")
        let polylineKey = polylines.keys.sorted().compactMap { id in
            guard let points = polylines[id] else { return nil }
            return "\(id):" + points.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ";")
        }.joined(separator: "|")
        let polygonKey = polygons.keys.sorted().compactMap { id in
            guard let points = polygons[id] else { return nil }
            return "\(id):" + points.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ";")
        }.joined(separator: "|")
        return "m[\(markerKey)]p[\(polylineKey)]g[\(polygonKey)]"
    }

    private static func region(_ value: Any?) -> MKCoordinateRegion? {
        guard let value = value as? [String: Any],
              let center = value["center"] as? [String: Any],
              let span = value["span"] as? [String: Any],
              let latitude = numeric(center["latitude"]),
              let longitude = numeric(center["longitude"]),
              let latitudeDelta = numeric(span["latitudeDelta"]) ?? numeric(span["latitude_delta"]),
              let longitudeDelta = numeric(span["longitudeDelta"]) ?? numeric(span["longitude_delta"]),
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              latitudeDelta > 0, latitudeDelta <= 180, longitudeDelta > 0, longitudeDelta <= 360,
              latitude - latitudeDelta / 2 >= -90, latitude + latitudeDelta / 2 <= 90 else { return nil }
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta))
    }

    private static func numeric(_ value: Any?) -> Double? {
        guard let number = craftNativeNumber(value) else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private func nonEmptyHandler(_ handler: String?) -> String? {
        guard let handler, !handler.isEmpty else { return nil }
        return handler
    }

    private static func color(_ value: String?) -> UIColor {
        switch value?.lowercased() {
        case "label": return .label
        case "secondarylabel", "secondary-label": return .secondaryLabel
        case "red": return .systemRed
        case "green": return .systemGreen
        case "orange": return .systemOrange
        case "purple": return .systemPurple
        case "yellow": return .systemYellow
        default:
            guard let value else { return .systemBlue }
            return UIColor(css: value) ?? UIColor(hex: value) ?? .systemBlue
        }
    }

    private static func mapType(_ value: String?) -> MKMapType {
        switch value?.lowercased() {
        case "satellite": return .satellite
        case "hybrid": return .hybrid
        case "muted_standard": return .mutedStandard
        default: return .standard
        }
    }

    private static func locationPermissionGranted() -> Bool {
        #if CRAFT_PERMISSION_LOCATION
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = CLLocationManager().authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }
        return status == .authorizedAlways || status == .authorizedWhenInUse
        #else
        return false
        #endif
    }
}

/// A WebView-free host for the first stx native vertical slice. The bundled
/// JavaScript sends whole, compiled view trees to UIKit and receives control
/// events and Craft API replies through JavaScriptCore.
struct CraftNativeScreen: UIViewControllerRepresentable {
    let config: CraftConfig

    func makeUIViewController(context: Context) -> UINavigationController {
        let screen = CraftNativeScreenController(config: config)
        // The shell hears the first frame (the app script starts after it)
        // and `craft.navigation.open`, which has no paths to open here but
        // web addresses, in the in-app browser.
        screen.hybridEvents = CraftHybrid.shared
        return UINavigationController(rootViewController: screen)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

/// A length as a style gives it: points, or a percentage of the parent's
/// content box. A percentage against a size that is not known yet (a column
/// whose height comes from its content) resolves to nothing, as on the web.
private enum CraftNativeLength: Equatable {
    case points(CGFloat)
    case percent(CGFloat)

    init?(_ value: Any?) {
        // JavaScript booleans can bridge to NSNumber on Apple platforms;
        // they are invalid CSS lengths and must stay unset like Android.
        if let number = craftNativeNumber(value) {
            let points = CGFloat(truncating: number)
            guard points.isFinite else { return nil }
            self = .points(points)
            return
        }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasSuffix("%"), let fraction = Double(text.dropLast()), fraction.isFinite {
            self = .percent(CGFloat(fraction) / 100)
        } else if text.hasSuffix("px"), let points = Double(text.dropLast(2)), points.isFinite {
            self = .points(CGFloat(points))
        } else if let points = Double(text), points.isFinite {
            self = .points(CGFloat(points))
        } else {
            return nil
        }
    }

    func resolve(_ base: CGFloat?) -> CGFloat? {
        switch self {
        case .points(let value): return max(0, value)
        case .percent(let fraction): return base.map { max(0, $0 * fraction) }
        }
    }
}

/// How a parent lays a child out, read once from the child's style.
private struct CraftNativeLayoutStyle {
    let width: CraftNativeLength?
    let height: CraftNativeLength?
    let aspectRatio: CGFloat?
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
    /// CSS/Yoga order; equal values retain source order.
    let order: Int
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
    let gridRows: Int?
    let gridAutoRows: CraftNativeLength?

    static let empty = CraftNativeLayoutStyle([:])

    init(_ raw: [String: Any]) {
        func number(_ value: Any?) -> CGFloat? {
            guard let number = craftNativeNumber(value) else { return nil }
            let value = CGFloat(truncating: number)
            return value.isFinite ? value : nil
        }
        width = CraftNativeLength(raw["width"])
        height = CraftNativeLength(raw["height"])
        let ratio = number(raw["aspectRatio"])
        aspectRatio = ratio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
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
        order = number(raw["order"]).map { Int($0.rounded(.towardZero)) } ?? 0
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
        gridRows = craftNativeGridRowCount(raw["gridTemplateRows"])
        gridAutoRows = CraftNativeLength(raw["gridAutoRows"])
    }
}

private final class CraftNativeLayoutStyleBox {
    let style: CraftNativeLayoutStyle
    init(_ style: CraftNativeLayoutStyle) { self.style = style }
}

private var craftNativeLayoutStyleKey: UInt8 = 0
private var craftNativeCornerRadiusKey: UInt8 = 0
private var craftNativeCornerRadiiKey: UInt8 = 0
private var craftNativeBorderLayerKey: UInt8 = 0
private var craftNativeSideBorderLayersKey: UInt8 = 0

private let craftAllCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner, .layerMinXMaxYCorner]

/// One radius for every rounded corner of `radii` (top-left, top-right,
/// bottom-right, bottom-left), and which corners those are; nil when the
/// rounded corners differ.
func craftSharedCornerRadius(_ radii: [CGFloat]) -> (radius: CGFloat, corners: CACornerMask)? {
    let order: [CACornerMask] = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner, .layerMinXMaxYCorner]
    var radius: CGFloat?
    var corners: CACornerMask = []
    for (index, corner) in order.enumerated() {
        let value = max(0, radii.count > index ? radii[index] : 0)
        guard value > 0 else { continue }
        if let radius, abs(radius - value) > 0.01 { return nil }
        radius = value
        corners.insert(corner)
    }
    return radius.map { ($0, corners) } ?? (0, craftAllCorners)
}

private func craftRoundedPath(_ rect: CGRect, _ rawRadii: [CGFloat]) -> CGPath {
    let limit = min(rect.width, rect.height) / 2
    let radii = (0..<4).map { min(max(0, rawRadii.count > $0 ? rawRadii[$0] : 0), limit) }
    let path = CGMutablePath()
    let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
    path.move(to: CGPoint(x: minX + radii[0], y: minY))
    path.addLine(to: CGPoint(x: maxX - radii[1], y: minY))
    path.addArc(center: CGPoint(x: maxX - radii[1], y: minY + radii[1]), radius: radii[1], startAngle: -.pi / 2, endAngle: 0, clockwise: false)
    path.addLine(to: CGPoint(x: maxX, y: maxY - radii[2]))
    path.addArc(center: CGPoint(x: maxX - radii[2], y: maxY - radii[2]), radius: radii[2], startAngle: 0, endAngle: .pi / 2, clockwise: false)
    path.addLine(to: CGPoint(x: minX + radii[3], y: maxY))
    path.addArc(center: CGPoint(x: minX + radii[3], y: maxY - radii[3]), radius: radii[3], startAngle: .pi / 2, endAngle: .pi, clockwise: false)
    path.addLine(to: CGPoint(x: minX, y: minY + radii[0]))
    path.addArc(center: CGPoint(x: minX + radii[0], y: minY + radii[0]), radius: radii[0], startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
    path.closeSubpath()
    return path
}

extension UIView {
    /// The layout style this view's parent reads. It lives on the view, so an
    /// in-place style update reaches the parent's next layout pass without the
    /// parent being reconciled too.
    fileprivate var craftLayoutStyle: CraftNativeLayoutStyle {
        get { (objc_getAssociatedObject(self, &craftNativeLayoutStyleKey) as? CraftNativeLayoutStyleBox)?.style ?? .empty }
        set { objc_setAssociatedObject(self, &craftNativeLayoutStyleKey, CraftNativeLayoutStyleBox(newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// The margins this view's style asks for, for a container that places
    /// it without a flex parent (a FlatList cell).
    var craftLayoutMargins: UIEdgeInsets {
        let style = craftLayoutStyle
        return UIEdgeInsets(top: max(0, style.marginTop), left: max(0, style.marginLeft), bottom: max(0, style.marginBottom), right: max(0, style.marginRight))
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

    var craftRequestedCornerRadii: [CGFloat]? {
        get { (objc_getAssociatedObject(self, &craftNativeCornerRadiiKey) as? [NSNumber])?.map { CGFloat(truncating: $0) } }
        set {
            objc_setAssociatedObject(self, &craftNativeCornerRadiiKey, newValue?.map { NSNumber(value: Double($0)) }, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            craftApplyCornerRadius()
        }
    }

    func craftApplyCornerRadius() {
        let requested = craftRequestedCornerRadius ?? 0
        let limit = min(bounds.width, bounds.height) / 2
        let radius = limit > 0 ? min(requested, limit) : min(requested, 9_998)
        if let radii = craftRequestedCornerRadii, let shared = craftSharedCornerRadius(radii) {
            // The rounded corners share one radius (`rounded-t-md`): the
            // layer rounds just those corners itself. A mask layer is an
            // offscreen render pass for every frame the view is on screen,
            // which Apple names first among render-phase hitches. Clipped
            // like the mask was.
            let clamped = limit > 0 ? min(shared.radius, limit) : min(shared.radius, 9_998)
            layer.mask = nil
            if layer.cornerRadius != clamped { layer.cornerRadius = clamped }
            if layer.maskedCorners != shared.corners { layer.maskedCorners = shared.corners }
            if !layer.masksToBounds { layer.masksToBounds = true }
        } else if let radii = craftRequestedCornerRadii {
            // Corners of different radii: only a path can draw them.
            let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
            if mask.frame != bounds { mask.frame = bounds }
            mask.path = craftRoundedPath(bounds, radii)
            layer.mask = mask
            layer.cornerRadius = 0
        } else {
            if layer.mask != nil { layer.mask = nil }
            if layer.maskedCorners != craftAllCorners { layer.maskedCorners = craftAllCorners }
            if layer.cornerRadius != radius { layer.cornerRadius = radius }
        }
        // A box shadow, as CSS draws it: the shape of the rounded box. Given
        // no path, Core Animation renders the layer offscreen every frame to
        // find the shadow's shape from its pixels.
        if layer.shadowOpacity > 0, bounds.width > 0, bounds.height > 0 {
            let cornerRadius = layer.mask == nil ? layer.cornerRadius : 0
            let shape: CGPath = layer.mask == nil
                ? (layer.maskedCorners == craftAllCorners || cornerRadius == 0
                    ? CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                    : craftRoundedPath(bounds, [CACornerMask.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner, .layerMinXMaxYCorner].map { layer.maskedCorners.contains($0) ? cornerRadius : 0 }))
                : craftRoundedPath(bounds, craftRequestedCornerRadii ?? [])
            if layer.shadowPath != shape { layer.shadowPath = shape }
        } else if layer.shadowPath != nil {
            layer.shadowPath = nil
        }
        let border = objc_getAssociatedObject(self, &craftNativeBorderLayerKey) as? CAShapeLayer
        let sides = (objc_getAssociatedObject(self, &craftNativeSideBorderLayersKey) as? [CALayer]).flatMap { $0.count == 4 ? $0 : nil }
        guard border != nil || sides != nil else { return }
        // Border layers are the view's own sublayers, so a new frame or path
        // would animate implicitly; and a path set again, even an equal one,
        // draws the shape again. Layout runs for every child on every pass.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let border {
            if border.frame != bounds { border.frame = bounds }
            let inset = border.lineWidth / 2
            let path = UIBezierPath(
                roundedRect: bounds.insetBy(dx: inset, dy: inset),
                cornerRadius: max(0, radius - inset)
            ).cgPath
            if border.path != path { border.path = path }
        }
        if let sides {
            let top = sides[0].frame.height
            let right = sides[1].frame.width
            let bottom = sides[2].frame.height
            let left = sides[3].frame.width
            let frames = [
                CGRect(x: 0, y: 0, width: bounds.width, height: top),
                CGRect(x: max(0, bounds.width - right), y: 0, width: right, height: bounds.height),
                CGRect(x: 0, y: max(0, bounds.height - bottom), width: bounds.width, height: bottom),
                CGRect(x: 0, y: 0, width: left, height: bounds.height),
            ]
            for (index, side) in sides.enumerated() {
                if side.frame != frames[index] { side.frame = frames[index] }
                if let shape = side as? CAShapeLayer {
                    let path = craftSideBorderPath(shape.bounds, index: index)
                    if shape.path != path { shape.path = path }
                }
            }
        }
    }

    private func craftSideBorderPath(_ bounds: CGRect, index: Int) -> CGPath {
        let path = UIBezierPath()
        switch index {
        case 0: path.move(to: CGPoint(x: bounds.minX, y: bounds.midY)); path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
        case 1: path.move(to: CGPoint(x: bounds.midX, y: bounds.minY)); path.addLine(to: CGPoint(x: bounds.midX, y: bounds.maxY))
        case 2: path.move(to: CGPoint(x: bounds.minX, y: bounds.midY)); path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
        default: path.move(to: CGPoint(x: bounds.midX, y: bounds.minY)); path.addLine(to: CGPoint(x: bounds.midX, y: bounds.maxY))
        }
        return path.cgPath
    }

    fileprivate func craftApplyBorderStyle(_ style: String?, width: CGFloat, color: UIColor) {
        guard width > 0, style == "dashed" || style == "dotted" else {
            (objc_getAssociatedObject(self, &craftNativeBorderLayerKey) as? CAShapeLayer)?.removeFromSuperlayer()
            objc_setAssociatedObject(self, &craftNativeBorderLayerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            layer.borderWidth = width
            layer.borderColor = color.cgColor
            return
        }
        layer.borderWidth = 0
        let border = (objc_getAssociatedObject(self, &craftNativeBorderLayerKey) as? CAShapeLayer) ?? CAShapeLayer()
        border.strokeColor = color.cgColor
        border.fillColor = nil
        border.lineWidth = width
        border.lineDashPattern = style == "dotted"
            ? [NSNumber(value: Double(width)), NSNumber(value: Double(width * 1.5))]
            : [NSNumber(value: Double(width * 3)), NSNumber(value: Double(width * 2))]
        border.contentsScale = window?.screen.scale ?? traitCollection.displayScale
        if border.superlayer !== layer { layer.addSublayer(border) }
        objc_setAssociatedObject(self, &craftNativeBorderLayerKey, border, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        craftApplyCornerRadius()
    }

    fileprivate func craftApplySideBorders(_ hasSideBorders: Bool, style: String?, widths: [CGFloat], colors: [UIColor]) {
        guard hasSideBorders else {
            (objc_getAssociatedObject(self, &craftNativeSideBorderLayersKey) as? [CALayer])?.forEach { $0.removeFromSuperlayer() }
            objc_setAssociatedObject(self, &craftNativeSideBorderLayersKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            craftApplyBorderStyle(style, width: widths.first ?? 0, color: colors.first ?? .clear)
            return
        }
        (objc_getAssociatedObject(self, &craftNativeBorderLayerKey) as? CAShapeLayer)?.removeFromSuperlayer()
        objc_setAssociatedObject(self, &craftNativeBorderLayerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        layer.borderWidth = 0
        (objc_getAssociatedObject(self, &craftNativeSideBorderLayersKey) as? [CALayer])?.forEach { $0.removeFromSuperlayer() }
        let top = max(0, widths.count > 0 ? widths[0] : 0)
        let right = max(0, widths.count > 1 ? widths[1] : 0)
        let bottom = max(0, widths.count > 2 ? widths[2] : 0)
        let left = max(0, widths.count > 3 ? widths[3] : 0)
        let frames = [
            CGRect(x: 0, y: 0, width: bounds.width, height: top),
            CGRect(x: max(0, bounds.width - right), y: 0, width: right, height: bounds.height),
            CGRect(x: 0, y: max(0, bounds.height - bottom), width: bounds.width, height: bottom),
            CGRect(x: 0, y: 0, width: left, height: bounds.height),
        ]
        let layers = frames.enumerated().map { index, frame in
            let side: CALayer
            if style == "dashed" || style == "dotted" {
                let shape = CAShapeLayer()
                shape.strokeColor = (colors.count > index ? colors[index] : .clear).cgColor
                shape.fillColor = nil
                shape.lineWidth = index % 2 == 0 ? frame.height : frame.width
                shape.lineCap = style == "dotted" ? .round : .butt
                shape.lineDashPattern = style == "dotted"
                    ? [NSNumber(value: Double(shape.lineWidth)), NSNumber(value: Double(shape.lineWidth * 1.5))]
                    : [NSNumber(value: Double(shape.lineWidth * 3)), NSNumber(value: Double(shape.lineWidth * 2))]
                shape.contentsScale = window?.screen.scale ?? traitCollection.displayScale
                shape.frame = frame
                shape.path = craftSideBorderPath(shape.bounds, index: index)
                side = shape
            } else {
                side = CALayer()
                side.backgroundColor = (colors.count > index ? colors[index] : .clear).cgColor
            }
            side.frame = frame
            layer.addSublayer(side)
            return side
        }
        objc_setAssociatedObject(self, &craftNativeSideBorderLayersKey, layers, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
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
            // Ask for max-content before asking for the wrapped height. A
            // constrained sizeThatFits call can return min-content (the
            // longest word), which collapses shrink-to-fit bubbles and pills.
            let maxContent = label.sizeThatFits(CGSize(width: unbounded, height: unbounded))
            let resolvedWidth = width ?? min(ceil(maxContent.width), limit)
            // Narrower than max-content (it met the limit): the wrapped height.
            let resolvedHeight = height ?? ceil(resolvedWidth < ceil(maxContent.width)
                ? label.sizeThatFits(CGSize(width: resolvedWidth, height: unbounded)).height
                : maxContent.height)
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
extension UIView {
    /// The native screen this view is drawn on, through the responder chain.
    var craftScreenController: CraftNativeScreenController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let screen = current as? CraftNativeScreenController { return screen }
            if let sheet = current as? CraftNativeSheetController { return sheet.screen }
            responder = current.next
        }
        return nil
    }
}

/// A finite, opt-in native celebration. Reconciliation with the same replay
/// value never restarts it; Reduce Motion always leaves the complete card still.
struct CraftNativeCelebrationSpec: Equatable {
    let replay: Double
    let enabled: Bool

    init?(_ raw: Any?) {
        guard let value = raw as? [String: Any],
              let replay = value["replay"] as? NSNumber,
              CFGetTypeID(replay) != CFBooleanGetTypeID(),
              replay.doubleValue.isFinite, replay.doubleValue >= 0 else { return nil }
        self.replay = replay.doubleValue
        enabled = value["enabled"] as? Bool != false
    }
}

final class CraftNativeCelebration {
    private weak var view: UIView?
    private var request: CraftNativeCelebrationSpec?
    private var pending = false
    private var overlay: CALayer?
    private var sheen: CALayer?
    private var cleanup: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private(set) var starts = 0
    var isRunning: Bool { overlay != nil }

    init(view: UIView) {
        self.view = view
        for name in [UIApplication.didEnterBackgroundNotification, UIAccessibility.reduceMotionStatusDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.stop() })
        }
    }

    deinit {
        cleanup?.cancel()
        overlay?.removeFromSuperlayer()
        sheen?.removeFromSuperlayer()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func configure(_ raw: Any?) {
        let next = CraftNativeCelebrationSpec(raw)
        guard next != request else { return }
        stop()
        request = next
        pending = next?.enabled == true
        view?.setNeedsLayout()
    }

    func stop() {
        pending = false
        cleanup?.cancel()
        cleanup = nil
        view?.layer.removeAnimation(forKey: "craft.celebration.entrance")
        overlay?.removeFromSuperlayer()
        overlay = nil
        sheen?.removeFromSuperlayer()
        sheen = nil
    }

    func layout(reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled) {
        guard pending, let view, let window = view.window,
              view.bounds.width > 0, view.bounds.height > 0, !view.isHidden else { return }
        var ancestor: UIView? = view.superview
        while let parent = ancestor {
            if parent.isHidden { return }
            ancestor = parent.superview
        }
        pending = false
        guard !reduceMotion else { return }
        starts += 1
        let frame = view.convert(view.bounds, to: window)
        let overlay = CALayer()
        overlay.name = "craft.celebration.confetti"
        overlay.frame = window.bounds
        window.layer.addSublayer(overlay)
        self.overlay = overlay

        // Core Animation owns every frame. No script timers, per-frame bridge
        // messages, bitmap assets or touch-intercepting overlay views.
        let colors: [UIColor] = [.init(red: 0.23, green: 0.51, blue: 0.96, alpha: 1), .init(red: 0.6, green: 0.96, blue: 0.89, alpha: 1), .init(red: 0.9, green: 0.77, blue: 0.55, alpha: 1), .white]
        let now = CACurrentMediaTime()
        for index in 0..<52 {
            let side: CGFloat = index % 2 == 0 ? -1 : 1
            let spread = CGFloat((index * 37) % 101) / 100
            let start = CGPoint(x: frame.midX + side * frame.width * 0.42, y: frame.minY + 28)
            let end = CGPoint(x: frame.midX + side * (35 + spread * window.bounds.width * 0.7), y: window.bounds.height + 30)
            let piece = CALayer()
            piece.bounds = CGRect(x: 0, y: 0, width: index % 3 == 0 ? 4 : 7, height: 11)
            piece.cornerRadius = 1
            piece.backgroundColor = colors[index % colors.count].cgColor
            piece.position = end
            piece.opacity = 0
            overlay.addSublayer(piece)
            let path = CAKeyframeAnimation(keyPath: "position")
            path.values = [NSValue(cgPoint: start), NSValue(cgPoint: CGPoint(x: start.x + side * (45 + spread * 65), y: max(0, start.y - 70 - spread * 100))), NSValue(cgPoint: end)]
            path.keyTimes = [0, 0.28, 1]
            path.calculationMode = .cubic
            let tumble = CABasicAnimation(keyPath: "transform.rotation")
            tumble.fromValue = side * Double(index)
            tumble.toValue = side * (Double(index) + 7 + Double(spread) * 10)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.04, 0.7, 1]
            let group = CAAnimationGroup()
            group.animations = [path, tumble, fade]
            group.duration = 2.2 + Double(spread) * 0.45
            group.beginTime = now + Double(index % 7) * 0.018
            group.fillMode = .backwards
            group.atDisplayRate()
            piece.add(group, forKey: "craft.celebration.particle")
        }

        let entrance = CASpringAnimation(keyPath: "transform")
        var from = CATransform3DMakeTranslation(0, 34, 0)
        from = CATransform3DRotate(from, -0.045, 0, 0, 1)
        from = CATransform3DScale(from, 0.86, 0.86, 1)
        entrance.fromValue = NSValue(caTransform3D: CATransform3DConcat(view.layer.transform, from))
        entrance.toValue = NSValue(caTransform3D: view.layer.transform)
        entrance.damping = 19
        entrance.stiffness = 160
        entrance.mass = 1
        entrance.duration = 0.95
        entrance.atDisplayRate()
        view.layer.add(entrance, forKey: "craft.celebration.entrance")

        let sheen = CAGradientLayer()
        sheen.name = "craft.celebration.sheen"
        sheen.frame = view.bounds
        sheen.colors = [UIColor.clear.cgColor, UIColor.white.withAlphaComponent(0.2).cgColor, UIColor.clear.cgColor]
        sheen.locations = [0.25, 0.5, 0.75]
        sheen.startPoint = CGPoint(x: 0, y: 0.3)
        sheen.endPoint = CGPoint(x: 1, y: 0.7)
        sheen.opacity = 0
        let mask = CAShapeLayer()
        mask.path = UIBezierPath(roundedRect: view.bounds, cornerRadius: view.layer.cornerRadius).cgPath
        sheen.mask = mask
        view.layer.addSublayer(sheen)
        self.sheen = sheen
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = -view.bounds.width
        sweep.toValue = view.bounds.width
        let light = CAKeyframeAnimation(keyPath: "opacity")
        light.values = [0, 1, 1, 0]
        light.keyTimes = [0, 0.15, 0.8, 1]
        let shine = CAAnimationGroup()
        shine.animations = [sweep, light]
        shine.duration = 1.15
        shine.beginTime = now + 0.55
        shine.atDisplayRate()
        sheen.add(shine, forKey: "craft.celebration.sweep")
        let cleanup = DispatchWorkItem { [weak self] in self?.stop() }
        self.cleanup = cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: cleanup)
    }
}

private class CraftNativeFlowView: UIStackView {
    var pageViewport: CGSize? { didSet { if pageViewport != oldValue { invalidateMeasurements() } } }
    var celebration: CraftNativeCelebration?
    func configureCelebration(_ raw: Any?) {
        if raw != nil && celebration == nil { celebration = CraftNativeCelebration(view: self) }
        celebration?.configure(raw)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { celebration?.stop() }
        else { setNeedsLayout() }
    }
    var pressActiveOpacity: CGFloat?
    var pressBaseOpacity: CGFloat = 1
    var pressUnderlayColor: UIColor?
    var pressBaseBackgroundColor: UIColor?
    var wrap = false { didSet { if wrap != oldValue { invalidateMeasurements() } } }
    var alignItems = "stretch" { didSet { alignment = alignmentValue; if alignItems != oldValue { invalidateMeasurements() } } }
    var alignContent = "flex-start" { didSet { if alignContent != oldValue { invalidateMeasurements() } } }
    var justifyContent = "flex-start" { didSet { distribution = distributionValue; if justifyContent != oldValue { invalidateMeasurements() } } }
    var gap: CGFloat = 0 { didSet { spacing = gap; if gap != oldValue { invalidateMeasurements() } } }
    var rowGap: CGFloat? { didSet { if rowGap != oldValue { invalidateMeasurements() } } }
    var columnGap: CGFloat? { didSet { if columnGap != oldValue { invalidateMeasurements() } } }
    var grid = false { didSet { if grid != oldValue { invalidateMeasurements() } } }
    var gridColumns = 1 { didSet { if gridColumns != oldValue { invalidateMeasurements() } } }
    var gridRows: Int? { didSet { if gridRows != oldValue { invalidateMeasurements() } } }
    var gridAutoRows: CraftNativeLength? { didSet { if gridAutoRows != oldValue { invalidateMeasurements() } } }
    var reverse = false { didSet { if reverse != oldValue { invalidateMeasurements() } } }
    var wrapReverse = false { didSet { if wrapReverse != oldValue { invalidateMeasurements() } } }
    var padding = UIEdgeInsets.zero {
        didSet {
            layoutMargins = effectivePadding
            isLayoutMarginsRelativeArrangement = true
            if padding != oldValue { invalidateMeasurements() }
        }
    }
    /// Insets contributed by a native SafeAreaView root. Authored padding
    /// remains separate so a reconciliation can remove either source without
    /// leaving stale safe-area space behind.
    var safeAreaPadding = UIEdgeInsets.zero {
        didSet {
            layoutMargins = effectivePadding
            if safeAreaPadding != oldValue { invalidateMeasurements() }
        }
    }
    var effectivePadding: UIEdgeInsets {
        UIEdgeInsets(
            top: padding.top + safeAreaPadding.top,
            left: padding.left + safeAreaPadding.left,
            bottom: padding.bottom + safeAreaPadding.bottom,
            right: padding.right + safeAreaPadding.right
        )
    }
    override var axis: NSLayoutConstraint.Axis {
        didSet { if axis != oldValue { invalidateMeasurements() } }
    }

    private var flowChildren: [UIView] = []
    private var measurements: [MeasureKey: CGSize] = [:]
    /// The screen's rendered root gets a definite viewport from the host. A
    /// root with `flex: 1` must keep that height even when its first child is
    /// a ScrollView whose content is taller than the screen; otherwise an
    /// absolute sibling is positioned against the scroll content and moves
    /// with it.
    private weak var viewportChild: UIView?
    private var viewportChildFillsHeight = false

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

    /// A view made one accessibility element (a row with `accessibilityRole`)
    /// hides its children from VoiceOver, so with no label of its own it reads
    /// what they say, in order, as React Native's accessible View does. A
    /// label given in props always wins.
    override var accessibilityLabel: String? {
        get {
            if let own = super.accessibilityLabel, !own.isEmpty { return own }
            guard isAccessibilityElement else { return nil }
            // An avatar labelled with the name beside it is said once.
            var spoken: [String] = []
            for part in CraftNativeFlowView.spokenText(in: self) where !spoken.contains(part) { spoken.append(part) }
            return spoken.isEmpty ? nil : spoken.joined(separator: ", ")
        }
        set { super.accessibilityLabel = newValue }
    }

    private static func spokenText(in view: UIView) -> [String] {
        var parts: [String] = []
        for child in view.subviews where !child.isHidden && child.alpha > 0.01 {
            if child.isAccessibilityElement {
                // A Text's label is its text (applyAccessibility leaves accessibilityLabel nil).
                let said = child.accessibilityLabel ?? (child as? UILabel)?.text
                if let label = said?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { parts.append(label) }
            } else {
                parts.append(contentsOf: spokenText(in: child))
            }
        }
        return parts
    }

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

    // MARK: Touches

    /// A child drawn outside this view's bounds still takes its touches, as an
    /// overflowing element is clickable on the web, unless the view clips
    /// (`overflow: hidden`). UIKit only asks a view's children when the point
    /// is inside the view, so a floating button absolutely positioned out of a
    /// zero-height parent (a component's wrapper) drew but could not be tapped.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let hit = super.hitTest(point, with: event) { return hit }
        guard !clipsToBounds, !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
        for child in subviews.reversed() where !child.isHidden && child.alpha > 0.01 && child.isUserInteractionEnabled {
            if let hit = child.hitTest(child.convert(point, from: self), with: event) { return hit }
        }
        return nil
    }

    // MARK: Children

    override var arrangedSubviews: [UIView] { flowChildren }

    override func addArrangedSubview(_ view: UIView) {
        insertArrangedSubview(view, at: flowChildren.count)
    }

    override func insertArrangedSubview(_ view: UIView, at stackIndex: Int) {
        flowChildren.removeAll { $0 === view }
        let index = min(max(0, stackIndex), flowChildren.count)
        flowChildren.insert(view, at: index)
        if view.superview !== self {
            view.removeFromSuperview()
            addSubview(view)
        }
        // Stacking follows the tree, as on the web: a later sibling draws and
        // takes touches above an earlier one. Appending a child inserted
        // before its siblings put it on top of all of them, so a ScrollView
        // re-created under a floating button (absolute, after it) took the
        // button's taps for whatever lay beneath while the button still drew.
        if let next = flowChildren[(index + 1)...].first(where: { $0.superview === self }) {
            insertSubview(view, belowSubview: next)
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

    func setViewportChild(_ view: UIView?, fillsHeight: Bool) {
        viewportChild = view
        viewportChildFillsHeight = fillsHeight
        invalidateMeasurements()
    }

    func removeLayoutStyle(for view: UIView) {
        view.craftLayoutStyle = .empty
        // Detaching a retained child must invalidate the parent's cached
        // intrinsic measurements too. The normal arranged-subview path does
        // this after removal, but callers that clear a style before deciding
        // whether to detach must not leave the old dimensions memoized.
        invalidateMeasurements()
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
        if let page = pageViewport { return CGSize(width: page.width * CGFloat(arrangedSubviews.filter { !$0.isHidden }.count), height: page.height) }
        let key = MeasureKey(width: width, height: height, maxWidth: maxWidth, maxHeight: maxHeight)
        if let cached = measurements[key] { return cached }
        let size = layout(width: width, height: height, maxWidth: maxWidth, maxHeight: maxHeight, place: false).size
        measurements[key] = size
        return size
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        craftApplyCornerRadius()
        celebration?.layout()
        if let page = pageViewport {
            for (index, child) in arrangedSubviews.filter({ !$0.isHidden }).enumerated() {
                child.frame = CGRect(x: CGFloat(index) * page.width, y: 0, width: page.width, height: page.height)
            }
            return
        }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let result = layout(width: bounds.width, height: bounds.height, maxWidth: bounds.width, maxHeight: bounds.height, place: true)
        var moved = false
        defer {
            // The screen reports onLayout from its own layout pass, which a
            // change deep in a scroll view's content never runs: a view that
            // went from 240 to 180 wide kept saying 240.
            if moved {
                craftScreenController?.scheduleLayoutEvents()
                craftScreenController?.scheduleKeyboardInsets()
            }
        }
        for (child, frame) in result.frames {
            var viewportFrame = frame
            if child === viewportChild, viewportChildFillsHeight {
                viewportFrame.origin.y = 0
                viewportFrame.size.height = bounds.height
            }
            var snapped = CraftNativeFlexLayout.snapped(viewportFrame, scale: scale)
            // Snapping each edge can take a pixel off a label (15.83…33.83
            // becomes 16…33.67), and a label a pixel narrower than its text
            // truncates it ("13" drew as "…"). Text keeps its whole size.
            if child is UILabel {
                snapped.size = CraftNativeFlexLayout.ceiled(frame.size, scale: scale, atLeast: snapped.size)
            }
            if child.transform.isIdentity {
                if child.frame != snapped { child.frame = snapped; moved = true }
            } else {
                // A transformed child (a sticky header, a scaled spinner) is
                // placed by bounds and center: its frame is undefined then.
                let size = CGRect(origin: child.bounds.origin, size: snapped.size)
                let center = CGPoint(x: snapped.midX, y: snapped.midY)
                if child.bounds != size { child.bounds = size; moved = true }
                if child.center != center { child.center = center; moved = true }
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

    /// The first baseline is the cross-axis anchor for a horizontal baseline
    /// flex line. Views without a baseline participate at their bottom edge,
    /// matching the CSS fallback for replaced and non-text elements.
    private static func firstBaseline(_ view: UIView, cross: CGFloat) -> CGFloat {
        let baseline: CGFloat?
        if let label = view as? CraftNativeLabel {
            // CraftNativeLabel draws inside its inset rect, so include the
            // authored top padding before the font's own baseline (UIKit's
            // labels expose no measured first-baseline offset).
            baseline = label.insets.top + label.font.ascender
        } else if let label = view as? UILabel {
            baseline = label.font.ascender
        } else if let field = view as? UITextField {
            baseline = field.font?.ascender
        } else if let textView = view as? UITextView {
            baseline = textView.font?.ascender
        } else {
            baseline = nil
        }
        guard let baseline, baseline.isFinite else { return cross }
        return min(max(0, baseline), cross)
    }

    /// Children that take part in the flow: shown, not a modal overlay.
    private var visibleChildren: [UIView] {
        flowChildren.enumerated()
            .filter { $0.element.superview === self && !$0.element.isHidden && !($0.element is CraftNativeModalView) }
            .sorted {
                if $0.element.craftLayoutStyle.order != $1.element.craftLayoutStyle.order {
                    return $0.element.craftLayoutStyle.order < $1.element.craftLayoutStyle.order
                }
                return $0.offset < $1.offset
            }
            .map(\.element)
    }

    /// Builds the eligible portion of this container for the host-neutral
    /// tree ABI. The local algorithm remains authoritative for absolute
    /// children and any subtree whose measurement cannot be represented by
    /// the shared contract.
    fileprivate func sharedTreeNode(parentWidth: CGFloat, parentHeight: CGFloat) -> CraftNativeTreeLayoutBridge.TreeNode? {
        let children = visibleChildren
        let flow = children.filter { $0.craftLayoutStyle.position != "absolute" }
        guard flow.count == children.count else { return nil }
        let style = craftLayoutStyle
        let width = style.width?.resolve(parentWidth)
        let height = style.height?.resolve(parentHeight)
        let intrinsic = CraftNativeFlexLayout.measure(
            self, width: width, height: height,
            maxWidth: max(0, parentWidth), maxHeight: max(0, parentHeight)
        )
        let measuredWidth = width ?? intrinsic.width
        let measuredHeight = height ?? intrinsic.height
        let contentWidth = max(0, measuredWidth - effectivePadding.left - effectivePadding.right)
        let contentHeight = max(0, measuredHeight - effectivePadding.top - effectivePadding.bottom)
        let nodes = flow.map { child -> CraftNativeTreeLayoutBridge.TreeNode? in
            let childStyle = child.craftLayoutStyle
            let childWidth = childStyle.width?.resolve(contentWidth)
            let childHeight = childStyle.height?.resolve(contentHeight)
            let childIntrinsic = CraftNativeFlexLayout.measure(
                child, width: childWidth, height: childHeight,
                maxWidth: contentWidth, maxHeight: contentHeight
            )
            let nested = child as? CraftNativeFlowView
            let nestedNode = nested?.sharedTreeNode(
                parentWidth: contentWidth, parentHeight: contentHeight
            )
            if nested != nil && nestedNode == nil { return nil }
            return CraftNativeTreeLayoutBridge.TreeNode(
                view: child,
                style: childStyle,
                intrinsic: childIntrinsic,
                baseline: Self.firstBaseline(child, cross: childIntrinsic.height),
                direction: nested?.axis ?? .horizontal,
                gap: nested.map { $0.axis == .horizontal ? ($0.columnGap ?? $0.gap) : ($0.rowGap ?? $0.gap) } ?? 0,
                rowGap: nested?.rowGap ?? 0,
                columnGap: nested?.columnGap ?? 0,
                wrap: nested?.wrap ?? false,
                justifyContent: nested?.justifyContent ?? "flex-start",
                alignItems: nested?.alignItems ?? "stretch",
                alignContent: nested?.alignContent ?? "flex-start",
                padding: nested?.effectivePadding ?? .zero,
                grid: nested?.grid ?? false,
                gridColumns: nested?.gridColumns ?? 1,
                gridRows: nested?.gridRows,
                gridAutoRows: nested?.gridAutoRows,
                reverse: nested?.reverse ?? false,
                wrapReverse: nested?.wrapReverse ?? false,
                children: nestedNode?.children ?? []
            )
        }
        guard nodes.allSatisfy({ $0 != nil }) else { return nil }
        return CraftNativeTreeLayoutBridge.TreeNode(
            view: self,
            style: style,
            intrinsic: intrinsic,
            baseline: 0,
            direction: axis,
            gap: axis == .horizontal ? (columnGap ?? gap) : (rowGap ?? gap),
            rowGap: rowGap ?? 0,
            columnGap: columnGap ?? 0,
            wrap: wrap,
            justifyContent: justifyContent,
            alignItems: alignItems,
            alignContent: alignContent,
            padding: effectivePadding,
            grid: grid,
            gridColumns: gridColumns,
            gridRows: gridRows,
            gridAutoRows: gridAutoRows,
            reverse: reverse,
            wrapReverse: wrapReverse,
            children: nodes.compactMap { $0 }
        )
    }

    private func sharedTreeFrames(_ children: [UIView], width: CGFloat?, height: CGFloat?) -> CraftNativeTreeLayoutBridge.TreeResult? {
        guard let width, let height,
              width.isFinite, height.isFinite, width >= 0, height >= 0 else { return nil }
        let nodes = children.map { child -> CraftNativeTreeLayoutBridge.TreeNode? in
            let style = child.craftLayoutStyle
            let intrinsic = CraftNativeFlexLayout.measure(child, width: style.width?.resolve(width), height: style.height?.resolve(height), maxWidth: width, maxHeight: height)
            let nested = child as? CraftNativeFlowView
            let nestedNode = nested?.sharedTreeNode(parentWidth: width, parentHeight: height)
            if nested != nil && nestedNode == nil { return nil }
            return CraftNativeTreeLayoutBridge.TreeNode(
                view: child,
                style: style,
                intrinsic: intrinsic,
                baseline: Self.firstBaseline(child, cross: intrinsic.height),
                direction: nested?.axis ?? .horizontal,
                gap: nested.map { $0.axis == .horizontal ? ($0.columnGap ?? $0.gap) : ($0.rowGap ?? $0.gap) } ?? 0,
                rowGap: nested?.rowGap ?? 0,
                columnGap: nested?.columnGap ?? 0,
                wrap: nested?.wrap ?? false,
                justifyContent: nested?.justifyContent ?? "flex-start",
                alignItems: nested?.alignItems ?? "stretch",
                alignContent: nested?.alignContent ?? "flex-start",
                padding: nested?.effectivePadding ?? .zero,
                grid: nested?.grid ?? false,
                gridColumns: nested?.gridColumns ?? 1,
                gridRows: nested?.gridRows,
                gridAutoRows: nested?.gridAutoRows,
                reverse: nested?.reverse ?? false,
                wrapReverse: nested?.wrapReverse ?? false,
                children: nestedNode?.children ?? []
            )
        }
        guard nodes.allSatisfy({ $0 != nil }) else { return nil }
        let root = CraftNativeTreeLayoutBridge.TreeNode(
            view: nil,
            style: .empty,
            intrinsic: .zero,
            baseline: 0,
            direction: axis,
            gap: axis == .horizontal ? (columnGap ?? gap) : (rowGap ?? gap),
            rowGap: rowGap ?? 0,
            columnGap: columnGap ?? 0,
            wrap: wrap,
            justifyContent: justifyContent,
            alignItems: alignItems,
            alignContent: alignContent,
            padding: effectivePadding,
            grid: grid,
            gridColumns: gridColumns,
            gridRows: gridRows,
            gridAutoRows: gridAutoRows,
            reverse: reverse,
            wrapReverse: wrapReverse,
            children: nodes.compactMap { $0 }
        )
        return CraftNativeTreeLayoutBridge.treeFrames(root: root, width: width, height: height)
    }

    /// The flexbox algorithm, single pass. `width`/`height` are this view's
    /// outer size when its parent fixes it, nil when it sizes to its content
    /// within `maxWidth`/`maxHeight`. Returns its outer size and, when
    /// placing, every child's frame in its own coordinates.
    private func sharedDirectFrames(_ children: [UIView], width: CGFloat?, height: CGFloat?) -> [(UIView, CGRect)]? {
        guard let width, let height, !grid, !reverse, !wrapReverse,
              width.isFinite, height.isFinite, width >= 0, height >= 0,
              children.allSatisfy({ child in
                  let style = child.craftLayoutStyle
                  return style.position != "absolute" && style.display != "none"
              }) else { return nil }

        let intrinsic = children.map { child in
            CraftNativeFlexLayout.measure(child, width: nil, height: nil, maxWidth: width, maxHeight: height)
        }
        let baselines = children.enumerated().map { index, child in
            CraftNativeFlowView.firstBaseline(child, cross: intrinsic[index].height)
        }
        let payload = zip(children, zip(intrinsic, baselines)).map { child, measured in
            (child, child.craftLayoutStyle, measured.0, measured.1)
        }
        return CraftNativeTreeLayoutBridge.frames(
            width: width, height: height, direction: axis, gap: gap, rowGap: rowGap, columnGap: columnGap, wrap: wrap,
            justifyContent: justifyContent, alignItems: alignItems, padding: effectivePadding, children: payload
        )
    }

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
        let contentPadding = effectivePadding
        let paddingWidth = contentPadding.left + contentPadding.right
        let paddingHeight = contentPadding.top + contentPadding.bottom
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
        if place, flow.count == children.count, let sharedTree = sharedTreeFrames(flow, width: width, height: height),
           (sharedTree.nodes.count > flow.count + 1 || grid || reverse || wrapReverse || gridAutoRows != nil || gridRows != nil) {
            frames = []
            for index in 1..<sharedTree.nodes.count {
                guard let view = sharedTree.nodes[index].view else { continue }
                let offset = sharedTree.frames[index]
                let parent = sharedTree.parents[index]
                let parentFrame = sharedTree.frames[parent]
                frames.append((view, CGRect(
                    x: CGFloat(offset.x - parentFrame.x), y: CGFloat(offset.y - parentFrame.y),
                    width: CGFloat(offset.width), height: CGFloat(offset.height)
                )))
            }
        } else if place, flow.count == children.count, let shared = sharedDirectFrames(flow, width: width, height: height) {
            frames = shared
        }
        let size = CGSize(width: width ?? contentSize.width + paddingWidth, height: height ?? contentSize.height + paddingHeight)

        if place {
            let content = CGRect(x: contentPadding.left, y: contentPadding.top, width: max(0, size.width - paddingWidth), height: max(0, size.height - paddingHeight))
            for child in children where child.craftLayoutStyle.position == "absolute" {
                let style = child.craftLayoutStyle
                var fixedWidth = style.left != nil && style.right != nil
                    ? max(0, content.width - (style.left ?? 0) - (style.right ?? 0))
                    : style.width?.resolve(content.width)
                var fixedHeight = style.top != nil && style.bottom != nil
                    ? max(0, content.height - (style.top ?? 0) - (style.bottom ?? 0))
                    : style.height?.resolve(content.height)
                let authoredWidth = fixedWidth != nil
                let authoredHeight = fixedHeight != nil
                (fixedWidth, fixedHeight) = aspectDimensions(style, width: fixedWidth, height: fixedHeight)
                var measured = CraftNativeFlexLayout.measure(child, width: fixedWidth, height: fixedHeight, maxWidth: content.width, maxHeight: content.height)
                var boundedWidth = clamp(measured.width, style.minWidth?.resolve(content.width), style.maxWidth?.resolve(content.width))
                let proposedHeight = !authoredHeight && style.aspectRatio != nil ? boundedWidth / style.aspectRatio! : fixedHeight
                if abs(boundedWidth - measured.width) > 0.0001 || proposedHeight != fixedHeight {
                    // A narrower label or container must wrap before its
                    // height and bottom anchor are resolved.
                    measured = CraftNativeFlexLayout.measure(child, width: boundedWidth, height: proposedHeight, maxWidth: content.width, maxHeight: content.height)
                }
                let boundedHeight = clamp(measured.height, style.minHeight?.resolve(content.height), style.maxHeight?.resolve(content.height))
                if !authoredWidth, authoredHeight, let ratio = style.aspectRatio {
                    boundedWidth = clamp(boundedHeight * ratio, style.minWidth?.resolve(content.width), style.maxWidth?.resolve(content.width))
                }
                let x = style.left ?? (style.right.map { content.width - $0 - boundedWidth } ?? 0)
                let y = style.top ?? (style.bottom.map { content.height - $0 - boundedHeight } ?? 0)
                frames.append((child, CGRect(x: content.minX + x, y: content.minY + y, width: boundedWidth, height: boundedHeight)))
            }
        }
        return (size, frames)
    }

    /// Resolves the missing side of an aspect-ratio box after its parent has
    /// supplied any definite width or height. Keeping this at the host edge
    /// lets grid and absolute children follow the same rule as flex items
    /// without adding platform-specific measurement behavior to native views.
    private func aspectDimensions(
        _ style: CraftNativeLayoutStyle,
        width: CGFloat?,
        height: CGFloat?
    ) -> (width: CGFloat?, height: CGFloat?) {
        guard let ratio = style.aspectRatio else { return (width, height) }
        if let width, height == nil { return (width, width / ratio) }
        if let height, width == nil { return (height * ratio, height) }
        return (width, height)
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
        let contentPadding = effectivePadding
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

        var items: [Item] = []

        func fallbackWidths(for line: Range<Int>, available: CGFloat, gap: CGFloat) -> [CGFloat] {
            let hypothetical = line.reduce(0) { $0 + items[$1].basis + items[$1].mainMargins } + CGFloat(max(0, line.count - 1)) * gap
            let free = available - hypothetical
            let growTotal = line.reduce(0) { $0 + items[$1].grow }
            let shrinkTotal = line.reduce(0) { $0 + items[$1].shrink * items[$1].basis }
            let growing = free > 0 && growTotal > 0
            let shrinking = free < 0 && shrinkTotal > 0
            var widths = line.map { items[$0].basis }
            guard growing || shrinking else { return widths }

            var frozen = Set<Int>()
            for _ in 0...line.count {
                var fixed = CGFloat(max(0, line.count - 1)) * gap
                var activeBasis: CGFloat = 0
                var factor: CGFloat = 0
                for (offset, index) in line.enumerated() {
                    let item = items[index]
                    fixed += item.mainMargins
                    if frozen.contains(offset) {
                        fixed += widths[offset]
                    } else {
                        activeBasis += item.basis
                        factor += growing ? item.grow : item.shrink * item.basis
                    }
                }
                guard factor > 0 else { break }
                let remaining = available - fixed - activeBasis
                var froze = false
                for (offset, index) in line.enumerated() where !frozen.contains(offset) {
                    let item = items[index]
                    let share = growing
                        ? remaining * item.grow / factor
                        : -remaining * item.shrink * item.basis / factor
                    let raw = growing ? item.basis + share : item.basis - share
                    let clamped = clamp(raw, item.minMain, item.maxMain)
                    widths[offset] = clamped
                    if abs(clamped - raw) > 0.0001 {
                        frozen.insert(offset)
                        froze = true
                    }
                }
                if !froze { break }
            }
            return widths
        }

        items = children.map { view in
            let style = view.craftLayoutStyle
            let mainLeading = horizontal ? style.marginLeft : style.marginTop
            let mainTrailing = horizontal ? style.marginRight : style.marginBottom
            let crossLeading = horizontal ? style.marginTop : style.marginLeft
            let crossTrailing = horizontal ? style.marginBottom : style.marginRight
            let align = style.alignSelf ?? alignItems
            let authoredMain = (horizontal ? style.width : style.height)?.resolve(definiteMain)
            let authoredCross = (horizontal ? style.height : style.width)?.resolve(definiteCross)
            let explicitMain = authoredMain ?? style.aspectRatio.flatMap { ratio in
                authoredCross.map { horizontal ? $0 * ratio : $0 / ratio }
            }
            let explicitCross = authoredCross ?? style.aspectRatio.flatMap { ratio in
                authoredMain.map { horizontal ? $0 / ratio : $0 * ratio }
            }
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
        if let lineIds = CraftNativeFlexLineBridge.lines(
            available: lineLimit,
            gap: mainGap,
            wrap: wrap,
            items: items.map { ($0.basis, $0.mainLeading, $0.mainTrailing) }
        ) {
            var start = 0
            for index in 1..<items.count where lineIds[index] != lineIds[index - 1] {
                lines.append(start..<index)
                start = index
            }
            lines.append(start..<items.count)
        } else {
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
        }
        // Reconciliation reverses the child order for the requested main
        // axis. A wrapped flex container must keep its lines in cross-axis
        // order, so restore the groups without changing each line's order.
        if reverse && wrap && lines.count > 1 { lines.reverse() }

        var lineMains: [CGFloat] = []
        var lineCrosses: [CGFloat] = []
        var sharedLines: [[(width: CGFloat, position: CGFloat)]?] = []
        for line in lines {
            let gaps = CGFloat(max(0, line.count - 1)) * mainGap
            let hypothetical = line.reduce(0) { $0 + items[$1].basis + items[$1].mainMargins } + gaps
            // A row sized by its content is as wide as that content, up to the
            // room it has; a column sized by its content is as tall as it is.
            let lineMain = definiteMain ?? (horizontal ? min(hypothetical, roomMain) : hypothetical)
            let sharedWidths = CraftNativeFlexBridge.widths(
                available: lineMain,
                gap: mainGap,
                justify: craftNativeJustifyCode(justifyContent),
                items: line.map { index in
                    let item = items[index]
                    return (item.basis, item.grow, item.shrink, item.minMain, item.maxMain, item.mainLeading, item.mainTrailing)
                }
            )
            sharedLines.append(sharedWidths)
            if let sharedWidths {
                for (offset, index) in line.enumerated() { items[index].main = sharedWidths[offset].width }
            } else {
                let fallback = fallbackWidths(for: line, available: lineMain, gap: mainGap)
                for (offset, index) in line.enumerated() { items[index].main = fallback[offset] }
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
        var contentCross = definiteCross
            ?? (lineCrosses.reduce(0, +) + CGFloat(max(0, lineCrosses.count - 1)) * crossGap)
        var crossLeading: CGFloat = 0
        var crossBetween = crossGap
        var sharedCrossOffsets: [CGFloat]? = nil
        if wrap, let definiteCross, lineCrosses.count > 1 {
            let alignment: UInt32 = switch alignContent {
            case "center": 1
            case "flex-end": 2
            case "space-between": 3
            case "space-around": 4
            case "space-evenly": 6
            case "stretch": 5
            default: 0
            }
            if let distributed = CraftNativeFlexLineDistributionBridge.distribute(
                available: definiteCross,
                gap: crossGap,
                alignment: alignment,
                lineCrosses: lineCrosses
            ) {
                sharedCrossOffsets = distributed.offsets
                lineCrosses = distributed.sizes
                for (lineIndex, line) in lines.enumerated() {
                    for index in line where items[index].fixedCross == nil && items[index].align == "stretch" {
                        let item = items[index]
                        items[index].cross = clamp(lineCrosses[lineIndex] - item.crossMargins, item.minCross, item.maxCross)
                    }
                }
            } else {
                let free = max(0, definiteCross - (lineCrosses.reduce(0, +) + CGFloat(lineCrosses.count - 1) * crossGap))
                switch alignContent {
                case "center": crossLeading = free / 2
                case "flex-end": crossLeading = free
                case "space-between": crossBetween = free / CGFloat(lineCrosses.count - 1) + crossGap
                case "space-around":
                    crossBetween = free / CGFloat(lineCrosses.count) + crossGap
                    crossLeading = free / CGFloat(lineCrosses.count * 2)
                case "space-evenly":
                    crossBetween = free / CGFloat(lineCrosses.count + 1) + crossGap
                    crossLeading = free / CGFloat(lineCrosses.count + 1)
                case "stretch":
                    let extra = free / CGFloat(lineCrosses.count)
                    lineCrosses = lineCrosses.map { $0 + extra }
                    for (lineIndex, line) in lines.enumerated() {
                        for index in line where items[index].fixedCross == nil && items[index].align == "stretch" {
                            let item = items[index]
                            items[index].cross = clamp(lineCrosses[lineIndex] - item.crossMargins, item.minCross, item.maxCross)
                        }
                    }
                default: break
                }
            }
            contentCross = definiteCross
        }

        if place {
            var crossOffset = crossLeading
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
                let lineOffset = sharedCrossOffsets?[lineIndex] ?? crossOffset
                let crossReversed = wrapReverse && wrap
                let physicalLineOffset = crossReversed ? contentCross - lineOffset - lineCross : lineOffset
                let sharedLine = sharedLines[lineIndex]
                    let useSharedPositions = !reverse && sharedLine != nil
                let baseline = horizontal
                    ? line.compactMap { index -> CGFloat? in
                        let item = items[index]
                        guard item.align == "baseline" else { return nil }
                        return item.crossLeading + Self.firstBaseline(item.view, cross: item.cross)
                    }.max()
                    : nil
                var mainOffset = leading
                for (offset, index) in line.enumerated() {
                    let item = items[index]
                    let crossPosition: CGFloat
                    if item.align == "baseline", let baseline {
                        let childBaseline = Self.firstBaseline(item.view, cross: item.cross)
                        crossPosition = CraftNativeCrossAxisBridge.position(
                            available: baseline,
                            size: childBaseline,
                            leading: item.crossLeading,
                            trailing: item.crossTrailing,
                            alignment: 3
                        ) ?? max(item.crossLeading, baseline - childBaseline)
                    } else {
                        let alignment = item.align == "center" ? UInt32(1) : item.align == "flex-end" ? UInt32(2) : UInt32(0)
                        crossPosition = CraftNativeCrossAxisBridge.position(
                            available: lineCross,
                            size: item.cross,
                            leading: item.crossLeading,
                            trailing: item.crossTrailing,
                            alignment: alignment
                        ) ?? {
                            switch alignment {
                            case 1: return item.crossLeading + (lineCross - item.crossMargins - item.cross) / 2
                            case 2: return lineCross - item.crossTrailing - item.cross
                            default: return item.crossLeading
                            }
                        }()
                    }
                    let physicalCrossPosition = crossReversed ? lineCross - crossPosition - item.cross : crossPosition
                    let mainPosition = useSharedPositions
                        ? (sharedLine?[offset].position ?? (mainOffset + item.mainLeading))
                        : mainOffset + item.mainLeading
                    let frame = horizontal
                        ? CGRect(x: contentPadding.left + mainPosition, y: contentPadding.top + physicalLineOffset + physicalCrossPosition, width: item.main, height: item.cross)
                        : CGRect(x: contentPadding.left + physicalLineOffset + physicalCrossPosition, y: contentPadding.top + mainPosition, width: item.cross, height: item.main)
                    frames.append((item.view, frame))
                    if !useSharedPositions { mainOffset += item.mainMargins + item.main + mainGap + between }
                }
                if sharedCrossOffsets == nil { crossOffset += lineCross + crossBetween }
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
        let contentPadding = effectivePadding
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
            var fixedWidth = style.width?.resolve(cellWidth)
            var fixedHeight = style.height?.resolve(innerHeight)
            // A cell's item is as wide as its column unless it sets a width
            // (or an aspect ratio derives one from its height), whatever its
            // height: a fixed-height swatch with no content was drawn 0 wide.
            if fixedWidth == nil && align == "stretch" && (fixedHeight == nil || style.aspectRatio == nil) { fixedWidth = available }
            (fixedWidth, fixedHeight) = aspectDimensions(style, width: fixedWidth, height: fixedHeight)
            let size = CraftNativeFlexLayout.measure(
                child,
                width: fixedWidth.map { min($0, available) },
                height: fixedHeight,
                maxWidth: available,
                maxHeight: CraftNativeFlexLayout.unbounded
            )
            sizes.append(size)
            let row = index / columns
            while rowHeights.count <= row { rowHeights.append(gridAutoRows?.resolve(innerHeight) ?? 0) }
            rowHeights[row] = max(rowHeights[row], size.height + style.marginTop + style.marginBottom)
        }
        let width = innerWidth ?? (CGFloat(columns) * cellWidth + gaps)
        if let explicitRows = gridRows, let innerHeight {
            let count = max(explicitRows, rowHeights.count)
            while rowHeights.count < count { rowHeights.append(0) }
            let available = max(0, innerHeight - CGFloat(max(0, count - 1)) * verticalGap)
            let equal = available / CGFloat(max(1, count))
            rowHeights = rowHeights.map { max($0, equal) }
        }
        let height = rowHeights.reduce(0, +) + CGFloat(max(0, rowHeights.count - 1)) * verticalGap
        // Older runtimes return nil for the optional symbol; the local layout
        // below remains the compatibility path in that case.
        let sharedFrames = gridRows == nil ? CraftNativeGridBridge.frames(
            availableWidth: innerWidth ?? width,
            availableHeight: innerHeight ?? height,
            columns: columns,
            columnGap: horizontalGap,
            rowGap: verticalGap,
            items: children.enumerated().map { index, child in
                let style = child.craftLayoutStyle
                let align = style.alignSelf ?? alignItems
                let size = sizes[index]
                let alignment: UInt32 = align == "center" ? 1 : align == "flex-end" ? 2 : 0
                var explicitWidth = style.width?.resolve(cellWidth)
                var explicitHeight = style.height?.resolve(innerHeight)
                if explicitWidth == nil && align == "stretch" && (explicitHeight == nil || style.aspectRatio == nil) {
                    explicitWidth = max(0, cellWidth - style.marginLeft - style.marginRight)
                }
                (explicitWidth, explicitHeight) = aspectDimensions(style, width: explicitWidth, height: explicitHeight)
                return (
                    size.width, size.height,
                    explicitWidth, explicitHeight,
                    style.minWidth?.resolve(cellWidth), style.maxWidth?.resolve(cellWidth),
                    style.minHeight?.resolve(innerHeight), style.maxHeight?.resolve(innerHeight),
                    style.marginLeft, style.marginRight, style.marginTop, style.marginBottom,
                    align == "stretch", alignment
                )
            },
            autoRowHeight: gridAutoRows.map { $0.resolve(innerHeight) ?? 0 },
            alignContent: craftNativeAlignContentCode(alignContent)
        ) : nil
        if place {
            if let sharedFrames {
                for (index, child) in children.enumerated() {
                    let frame = sharedFrames[index]
                    frames.append((child, CGRect(x: contentPadding.left + frame.x, y: contentPadding.top + frame.y, width: frame.width, height: frame.height)))
                }
                return CGSize(width: width, height: innerHeight ?? height)
            }
            let gridHeight = innerHeight ?? height
            let gridGaps = CGFloat(max(0, rowHeights.count - 1)) * verticalGap
            let gridFree = max(0, gridHeight - rowHeights.reduce(0, +) - gridGaps)
            var rowLeading: CGFloat = 0
            var rowBetween = verticalGap
            var rowExtra: CGFloat = 0
            switch alignContent {
            case "center": rowLeading = gridFree / 2
            case "flex-end": rowLeading = gridFree
            case "space-between":
                if rowHeights.count > 1 { rowBetween += gridFree / CGFloat(rowHeights.count - 1) }
            case "space-around":
                rowLeading = gridFree / CGFloat(rowHeights.count * 2)
                rowBetween += gridFree / CGFloat(rowHeights.count)
            case "space-evenly":
                rowLeading = gridFree / CGFloat(rowHeights.count + 1)
                rowBetween += gridFree / CGFloat(rowHeights.count + 1)
            case "stretch": rowExtra = gridFree / CGFloat(max(1, rowHeights.count))
            default: break
            }
            var rowTop = contentPadding.top + rowLeading
            for (index, child) in children.enumerated() {
                let style = child.craftLayoutStyle
                let row = index / columns
                let column = index % columns
                let rowHeight = rowHeights[row] + rowExtra
                let size = sizes[index]
                let align = style.alignSelf ?? alignItems
                let availableWidth = max(0, cellWidth - style.marginLeft - style.marginRight)
                let availableHeight = max(0, rowHeight - style.marginTop - style.marginBottom)
                let childWidth = min(availableWidth, size.width)
                let childHeight = align == "stretch" && style.height == nil && style.aspectRatio == nil ? availableHeight : min(availableHeight, size.height)
                let x = contentPadding.left + CGFloat(column) * (cellWidth + horizontalGap) + style.marginLeft
                    + (align == "center" ? (availableWidth - childWidth) / 2 : align == "flex-end" ? availableWidth - childWidth : 0)
                let y = rowTop + style.marginTop
                    + (align == "center" ? (availableHeight - childHeight) / 2 : align == "flex-end" ? availableHeight - childHeight : 0)
                frames.append((child, CGRect(x: x, y: y, width: childWidth, height: childHeight)))
                if column == columns - 1 || index == children.count - 1 { rowTop += rowHeight + rowBetween }
            }
        }
        return CGSize(width: width, height: innerHeight ?? height)
    }
}

/// A container that applies only the requested system safe-area edges. The
/// host keeps the root edge-to-edge when this node is the screen root so the
/// node, rather than the controller's outer stack, owns the insets.
private final class CraftNativeSafeAreaView: CraftNativeFlowView {
    private var edges: Set<String> = ["top", "right", "bottom", "left"]

    func setSafeAreaEdges(_ raw: Any?) {
        guard let values = raw as? [Any] else {
            edges = ["top", "right", "bottom", "left"]
            updateSafeAreaPadding()
            return
        }
        edges = Set(values.compactMap { value in
            guard let edge = value as? String, ["top", "right", "bottom", "left"].contains(edge) else { return nil }
            return edge
        })
        updateSafeAreaPadding()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateSafeAreaPadding()
    }

    private func updateSafeAreaPadding() {
        let insets = safeAreaInsets
        safeAreaPadding = UIEdgeInsets(
            top: edges.contains("top") ? insets.top : 0,
            left: edges.contains("left") ? insets.left : 0,
            bottom: edges.contains("bottom") ? insets.bottom : 0,
            right: edges.contains("right") ? insets.right : 0
        )
    }
}

/// A flex container that responds to the controller's keyboard overlap.
/// `padding` keeps the content visible without moving the field; `position`
/// lifts the whole container; `height` reduces its viewport.
private final class CraftNativeKeyboardAvoidingView: CraftNativeFlowView {
    private var authoredPadding = UIEdgeInsets.zero
    private var keyboardInset: CGFloat = 0
    private var keyboardVerticalOffset: CGFloat = 0
    private var keyboardBehavior = "padding"
    private var appliedHeightInset: CGFloat = 0
    private var adjustingHeight = false

    func configureKeyboard(props: [String: Any]) {
        let requestedBehavior = (props["behavior"] as? String) ?? "padding"
        keyboardBehavior = ["height", "position", "padding"].contains(requestedBehavior) ? requestedBehavior : "padding"
        keyboardVerticalOffset = number(props["keyboardVerticalOffset"]) ?? 0
        if keyboardBehavior != "height" { appliedHeightInset = 0 }
        authoredPadding = padding
        applyKeyboardAvoidance()
    }

    func setKeyboardInset(_ inset: CGFloat) {
        guard abs(keyboardInset - inset) > 0.5 else { return }
        keyboardInset = max(0, inset)
        applyKeyboardAvoidance()
    }

    private var effectiveInset: CGFloat { max(0, keyboardInset - keyboardVerticalOffset) }

    private func applyKeyboardAvoidance() {
        let inset = effectiveInset
        switch keyboardBehavior {
        case "position":
            transform = CGAffineTransform(translationX: 0, y: -inset)
            padding = authoredPadding
        case "height":
            transform = .identity
            padding = authoredPadding
        default:
            transform = .identity
            padding = UIEdgeInsets(
                top: authoredPadding.top,
                left: authoredPadding.left,
                bottom: authoredPadding.bottom + inset,
                right: authoredPadding.right
            )
        }
        invalidateMeasurements()
    }

    override func layoutSubviews() {
        if keyboardBehavior == "height", !adjustingHeight {
            let inset = effectiveInset
            let target = max(0, bounds.height + appliedHeightInset - inset)
            if abs(target - bounds.height) > 0.5 {
                adjustingHeight = true
                appliedHeightInset = inset
                bounds.size.height = target
                super.layoutSubviews()
                adjustingHeight = false
                return
            }
        }
        super.layoutSubviews()
    }
}

/// An image-backed flex container. The image stays behind ordinary native
/// children so `ImageBackground` keeps the same layout and interaction
/// semantics as a `View` while using the shared image loader.
private final class CraftNativeImageBackgroundView: UIImageView {
    let contentStack = CraftNativeFlowView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        contentMode = .scaleAspectFill
        clipsToBounds = true
        contentStack.backgroundColor = .clear
        addSubview(contentStack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentStack.frame = bounds
    }
}

private final class CraftNativeSegmentElement: UIAccessibilityElement {
    weak var control: CraftNativeSegmentedControl?
    let index: Int
    init(control: CraftNativeSegmentedControl, index: Int) {
        self.control = control
        self.index = index
        super.init(accessibilityContainer: control)
    }
    override func accessibilityActivate() -> Bool {
        guard let control, control.isEnabled, control.values.indices.contains(index), control.isEnabledForSegment(at: index) else { return false }
        if control.selectedSegmentIndex != index {
            control.selectedSegmentIndex = index
            control.sendActions(for: .valueChanged)
        }
        return true
    }
}

private final class CraftNativeSegmentedControl: UISegmentedControl {
    var values: [String] = []
    private var segments: [CraftNativeSegmentElement] = []
    override var accessibilityElements: [Any]? {
        get { segments }
        set { /* The native segments, not the labelled group, own activation. */ }
    }
    func configureAccessibility(items: [[String: Any]]) {
        if segments.count != items.count { segments = items.indices.map { CraftNativeSegmentElement(control: self, index: $0) } }
        for (index, item) in items.enumerated() {
            segments[index].accessibilityLabel = item["spoken"] as? String ?? item["label"] as? String ?? values[index]
        }
        refreshAccessibilityState()
        setNeedsLayout()
    }
    func refreshAccessibilityState() {
        for (index, segment) in segments.enumerated() {
            segment.accessibilityTraits = [.button]
            if selectedSegmentIndex == index { segment.accessibilityTraits.insert(.selected) }
            if !isEnabled || !isEnabledForSegment(at: index) { segment.accessibilityTraits.insert(.notEnabled) }
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !segments.isEmpty else { return }
        let width = bounds.width / CGFloat(segments.count)
        for (index, segment) in segments.enumerated() {
            let visualIndex = effectiveUserInterfaceLayoutDirection == .rightToLeft ? segments.count - index - 1 : index
            segment.accessibilityFrameInContainerSpace = CGRect(x: CGFloat(visualIndex) * width, y: 0, width: width, height: bounds.height)
        }
    }
}

private final class CraftNativeSheetController: UIViewController {
    weak var screen: CraftNativeScreenController?
    weak var content: CraftNativeFlowView?
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        content?.frame = view.bounds.inset(by: view.safeAreaInsets)
    }
}

private final class CraftNativeModalView: UIView, UIGestureRecognizerDelegate, UISheetPresentationControllerDelegate {
    let contentStack = CraftNativeFlowView()
    private let blocker = UIView()
    private let backdropTap = UITapGestureRecognizer()
    private var renderedVisible = false
    private var animationGeneration = 0
    var onRequestClose: ((String) -> Void)?
    weak var sheetPresenter: CraftNativeScreenController?
    var presentationStyle = "overFullScreen"
    var sheetDetents: [String] = ["medium", "large"]
    var selectedDetent: String?
    var grabberVisible = true
    private var sheetController: CraftNativeSheetController?
    var isPresentedAsSheet: Bool { sheetController != nil }

    private func configureSheet(_ controller: CraftNativeSheetController) {
        controller.isModalInPresentation = onRequestClose == nil
        guard let sheet = controller.sheetPresentationController else { return }
        let choices = sheetDetents.filter { $0 == "medium" || $0 == "large" }
        let values = choices.isEmpty ? ["large"] : Array(Set(choices)).sorted { $0 == "medium" && $1 == "large" }
        sheet.detents = values.map { $0 == "medium" ? .medium() : .large() }
        sheet.prefersGrabberVisible = grabberVisible
        if let selectedDetent, values.contains(selectedDetent) {
            sheet.selectedDetentIdentifier = selectedDetent == "medium" ? .medium : .large
        }
        sheet.delegate = self
    }

    private func restoreSheetContent(_ controller: CraftNativeSheetController) {
        guard sheetController === controller else { return }
        contentStack.removeFromSuperview()
        addSubview(contentStack)
        sheetController = nil
        setNeedsLayout()
    }

    private func setSheetVisible(_ visible: Bool, animated: Bool) {
        renderedVisible = visible
        isHidden = true // UIKit owns the scrim, safe area, grabber and pan.
        guard visible else {
            guard let controller = sheetController else { return }
            controller.view.endEditing(true)
            controller.dismiss(animated: animated) { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.restoreSheetContent(controller)
                if self.renderedVisible { self.setSheetVisible(true, animated: animated) }
            }
            return
        }
        if let controller = sheetController { configureSheet(controller); return }
        // A newly rendered modal is attached to its screen after this pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.renderedVisible, self.sheetController == nil,
                  let presenter = self.sheetPresenter, presenter.view.window != nil else { return }
            let controller = CraftNativeSheetController()
            controller.screen = presenter
            controller.modalPresentationStyle = self.presentationStyle == "formSheet" ? .formSheet : .pageSheet
            controller.view.backgroundColor = .systemBackground
            self.contentStack.removeFromSuperview()
            controller.view.addSubview(self.contentStack)
            controller.content = self.contentStack
            self.sheetController = controller
            self.configureSheet(controller)
            var top: UIViewController = presenter
            while let presented = top.presentedViewController { top = presented }
            top.present(controller, animated: animated)
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let controller = presentationController.presentedViewController as? CraftNativeSheetController else { return }
        restoreSheetContent(controller)
        renderedVisible = false
        onRequestClose?("swipe")
    }

    var transparent = false {
        didSet { blocker.backgroundColor = transparent ? .clear : UIColor.black.withAlphaComponent(0.32) }
    }

    /// Existing Modal nodes block by default. A non-modal popup keeps the
    /// screen-level overlay but lets hit testing fall through outside its
    /// interactive content.
    var blocksBackground = true {
        didSet { blocker.isUserInteractionEnabled = blocksBackground }
    }
    /// An opt-in non-modal dismissal policy. The default popup remains
    /// pass-through; when enabled, an outside tap is consumed and routed to
    /// onRequestClose instead of reaching the view below.
    var dismissOnOutsideTap = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        blocker.isUserInteractionEnabled = true
        blocker.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        backdropTap.addTarget(self, action: #selector(backdropTapped))
        backdropTap.cancelsTouchesInView = false
        backdropTap.delegate = self
        addGestureRecognizer(backdropTap)
        addSubview(blocker)
        contentStack.backgroundColor = .clear
        addSubview(contentStack)
    }

    required init?(coder: NSCoder) { nil }

    /// Whether the modal takes touches is its own to say: shown, it takes
    /// every one (the scrim and its controls); the screen's press and long
    /// press bookkeeping once turned that off for a view with no handler of
    /// its own, and a shown modal let every tap through to the screen behind.
    func setVisible(_ visible: Bool, opacity: CGFloat, animationType: String?) {
        if blocksBackground && (presentationStyle == "pageSheet" || presentationStyle == "formSheet") {
            setSheetVisible(visible, animated: animationType != "none")
            return
        }
        if visible { isUserInteractionEnabled = true }
        if renderedVisible == visible && isHidden == !visible {
            if visible, alpha != opacity { alpha = opacity }
            return
        }
        let wasVisible = renderedVisible && !isHidden
        renderedVisible = visible
        animationGeneration += 1
        let generation = animationGeneration
        layer.removeAllAnimations()
        guard visible else {
            craftScreenController?.forgetFocusedInput(in: self)
            endEditing(true)
            if animationType == "slide" && wasVisible {
                let distance = max(bounds.height, superview?.bounds.height ?? UIScreen.main.bounds.height)
                UIView.animate(withDuration: 0.24, animations: {
                    self.transform = CGAffineTransform(translationX: 0, y: distance)
                    self.alpha = 0
                }, completion: { _ in
                    guard self.animationGeneration == generation else { return }
                    self.isHidden = true
                    self.transform = .identity
                })
            } else {
                isHidden = true
                transform = .identity
                alpha = 0
            }
            return
        }
        isHidden = false
        if animationType == "none" {
            transform = .identity
            alpha = opacity
        } else if animationType == "slide" {
            let distance = max(bounds.height, superview?.bounds.height ?? UIScreen.main.bounds.height)
            transform = CGAffineTransform(translationX: 0, y: distance)
            alpha = opacity
            DispatchQueue.main.async {
                guard self.animationGeneration == generation, !self.isHidden else { return }
                let distance = max(self.bounds.height, self.superview?.bounds.height ?? UIScreen.main.bounds.height)
                self.transform = CGAffineTransform(translationX: 0, y: distance)
                UIView.animate(withDuration: 0.24) { self.transform = .identity }
            }
        } else {
            transform = .identity
            alpha = 0
            UIView.animate(withDuration: 0.18) { self.alpha = opacity }
        }
    }

    func resetForTeardown() {
        renderedVisible = false
        sheetPresenter = nil
        if let controller = sheetController {
            controller.dismiss(animated: false)
            restoreSheetContent(controller)
        }
        craftScreenController?.forgetFocusedInput(in: self)
        endEditing(true)
        animationGeneration += 1
        layer.removeAllAnimations()
        isHidden = true
        transform = .identity
        alpha = 0
        isUserInteractionEnabled = true
        blocksBackground = true
        dismissOnOutsideTap = false
        onRequestClose = nil
    }

    func requestClose(reason: String = "backdrop") {
        guard blocksBackground || dismissOnOutsideTap else { return }
        guard let onRequestClose else { return }
        isUserInteractionEnabled = false
        onRequestClose(reason)
    }

    @objc private func backdropTapped() { requestClose(reason: "backdrop") }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === backdropTap else { return true }
        var candidate = touch.view
        while let view = candidate, view !== self {
            if view === blocker { return true }
            if view is UIControl || !(view.gestureRecognizers?.isEmpty ?? true) { return false }
            candidate = view.superview
        }
        return true
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
        let contentPoint = contentStack.convert(point, from: self)
        if contentStack.bounds.contains(contentPoint), let hit = contentStack.hitTest(contentPoint, with: event), hit !== contentStack {
            // Flow/layout views occupy the modal's entire content rect, but a
            // blank part of one must still be a scrim tap. Preserve touches
            // only when the hit view (or one of its ancestors) actually owns
            // a control or gesture recognizer.
            var candidate: UIView? = hit
            while let view = candidate, view !== contentStack {
                if view is UIControl || !(view.gestureRecognizers?.isEmpty ?? true) { return hit }
                candidate = view.superview
            }
        }
        if !blocksBackground {
            // A dismissible popup consumes its outside hit so the close event
            // cannot also activate the screen below. Otherwise it owns the
            // hit only when a blocking modal is underneath it; with no modal
            // below, the screen remains pass-through.
            if dismissOnOutsideTap { return self }
            return craftScreenController?.hasBlockingModalBelow(self) == true ? self : nil
        }
        return blocker.hitTest(blocker.convert(point, from: self), with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blocker.frame = bounds
        guard sheetController == nil else { return }
        // The scrim covers the whole screen; what the modal holds stays
        // clear of the bars and the home indicator it is drawn over.
        contentStack.frame = bounds.inset(by: UIEdgeInsets(top: contentInsets.top, left: 0, bottom: contentInsets.bottom, right: 0))
    }

    /// Where the screen's own content starts and ends: the scrim covers the
    /// whole screen, what the modal holds stays clear of the bars.
    var contentInsets: UIEdgeInsets = .zero {
        didSet { if contentInsets != oldValue { setNeedsLayout() } }
    }
}

/// The delegate of a map's own tap (`Map`'s onPress): it watches beside
/// MapKit's recognizers, so a tap on a pin still selects it.
final class CraftMapTapDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = CraftMapTapDelegate()

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

/// A pressable wrapper must yield to an actionable descendant. Without this
/// ordering UIKit may let the ancestor's tap recognizer win the same touch,
/// so a nested Button never receives its physical action. A descendant
/// control or tap recognizer is the source of the event; STX handles the
/// logical bubbling from there.
final class CraftPressGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = CraftPressGestureDelegate()

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let parent = gestureRecognizer.view,
              let child = otherGestureRecognizer.view,
              child !== parent else { return false }
        return child.isDescendant(of: parent)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let container = gestureRecognizer.view else { return true }
        let hitView = container.hitTest(touch.location(in: container), with: nil)
        guard var candidate = hitView ?? touch.view else { return true }
        while candidate !== container {
            if candidate is UIControl { return false }
            if candidate.gestureRecognizers?.contains(where: { $0 !== gestureRecognizer && $0 is UITapGestureRecognizer }) == true {
                return false
            }
            candidate = candidate.superview ?? container
        }
        return true
    }
}

/// The delegate of a Pressable's press-in/out feedback. That recognizer is
/// a long press of no duration, so it begins the moment a finger lands; on its
/// own it would claim the touch, and the tap that is the Pressable's onPress
/// failed whenever onPressIn or onPressOut were set too. It only watches.
final class CraftPressFeedbackDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = CraftPressFeedbackDelegate()

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

/// Whether a scrolling view's gesture runs together with `other`. A scroll
/// view is the delegate of its own pan as well as of its keyboard tap, so this
/// answers for both. Everything runs together (the keyboard tap watches
/// alongside a control's own gestures; the back-swipe and the tab swipe decide
/// for themselves) except two scroll views' pans: run together, a drag on a
/// nested scroll view scrolled its parent at the same time.
func craftScrollGesture(_ gesture: UIGestureRecognizer, runsWith other: UIGestureRecognizer) -> Bool {
    guard let scroll = gesture.view as? UIScrollView, gesture === scroll.panGestureRecognizer,
          let otherScroll = other.view as? UIScrollView, other === otherScroll.panGestureRecognizer else { return true }
    return false
}

/// Scroll containers observe taps without cancelling native input focus or
/// selection. Text views are not UIControls, and their selection subviews may
/// have recognizers of their own, so inspect the whole ancestor chain.
func craftHandleKeyboardTap(in container: UIView, hit: UIView?, persistTaps: String, forgetFocus: () -> Void) {
    guard persistTaps != "always" else { return }
    var candidate = hit
    var onControl = false
    while let view = candidate, view !== container {
        if view is UITextField || view is UITextView || view is UIButton { return }
        if view is UIControl || !(view.gestureRecognizers ?? []).isEmpty { onControl = true }
        candidate = view.superview
    }
    if persistTaps == "handled", onControl { return }
    if !onControl { forgetFocus() }
    container.window?.endEditing(true)
}

private final class CraftNativeScrollView: UIScrollView, UIGestureRecognizerDelegate {
    let contentStack = CraftNativeFlowView()
    private let keyboardTapGesture = UITapGestureRecognizer()
    private var keyboardShouldPersistTaps = "never"
    private var contentNeedsLayout = true
    private var laidOutSize: CGSize = .zero
    private let pullToRefresh = UIRefreshControl()
    private var refreshHandler: (() -> Void)?
    private var authoredPageIndex: Int?
    private var pendingPageIndex: Int?
    private var currentPageIndex = 0
    private var pageAnimating = false
    private var reportedPage: (Int, Int)?
    private var pageHandler: ((Int, Int) -> Void)?

    /// Opt-in viewport-sized pages. Ordinary horizontal scroll strips retain
    /// their intrinsic widths; only a controlled pageIndex enables this mode.
    func configurePager(_ raw: Any?, onSelect: ((Int, Int) -> Void)?) {
        let next = craftNativeNumber(raw).flatMap { number -> Int? in
            let value = number.doubleValue
            return value.isFinite ? Int(min(Double(Int.max / 2), max(0, value))) : nil
        }
        if next != authoredPageIndex { pendingPageIndex = next; contentNeedsLayout = true }
        authoredPageIndex = next
        pageHandler = onSelect
        if next == nil { contentStack.pageViewport = nil; reportedPage = nil; pageAnimating = false }
        setNeedsLayout()
    }

    func beginPageDrag() { pageAnimating = false }

    func finishPageMotion() {
        pageAnimating = false
        DispatchQueue.main.async { [weak self] in self?.settlePage() }
    }

    func settlePage() {
        guard authoredPageIndex != nil, bounds.width > 0, !pageAnimating,
              !isTracking, !isDragging, !isDecelerating else { return }
        let pages = contentStack.arrangedSubviews.filter { !$0.isHidden }
        let index = min(max(0, Int((contentOffset.x / bounds.width).rounded())), max(0, pages.count - 1))
        currentPageIndex = index
        for (i, child) in pages.enumerated() { child.accessibilityElementsHidden = i != index }
        if reportedPage?.0 != index || reportedPage?.1 != pages.count {
            reportedPage = (index, pages.count)
            pageHandler?(index, pages.count)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Let native controls finish tracking taps before the scroll view decides
        // whether the gesture is a drag. This matches UIKit's table-view
        // behavior and prevents switches, sliders, and date pickers from
        // losing most taps when they live inside a ScrollView.
        delaysContentTouches = false
        keyboardTapGesture.cancelsTouchesInView = false
        keyboardTapGesture.delegate = self
        keyboardTapGesture.addTarget(self, action: #selector(keyboardTap))
        addGestureRecognizer(keyboardTapGesture)
        pullToRefresh.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        addSubview(contentStack)
        setAxis(.vertical)
    }

    required init?(coder: NSCoder) { nil }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        // Buttons and text fields yield once a scroll drag begins; an
        // ordinary tap still reaches them immediately. Value controls such
        // as sliders, switches and date pickers keep their tracking gesture.
        if view is UIButton || view is UITextField { return true }
        if view is UIControl { return false }
        return super.touchesShouldCancel(in: view)
    }

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
        if authoredPageIndex != nil && !isVertical {
            let pageWidth = max(0, width ?? bounds.width)
            let pageHeight = max(0, height ?? bounds.height)
            return CGSize(width: pageWidth * CGFloat(contentStack.arrangedSubviews.filter { !$0.isHidden }.count), height: pageHeight)
        }
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
            let resized = laidOutSize != bounds.size
            laidOutSize = bounds.size
            if authoredPageIndex != nil && !isVertical { contentStack.pageViewport = bounds.size }
            var size = contentFitting(width: bounds.width, height: bounds.height)
            if isVertical {
                size.width = max(0, bounds.width - adjustedContentInset.left - adjustedContentInset.right)
            } else {
                size.height = max(0, bounds.height - adjustedContentInset.top - adjustedContentInset.bottom)
            }
            let frame = CGRect(origin: .zero, size: size)
            if contentStack.frame != frame { contentStack.frame = frame }
            if contentSize != size { contentSize = size }
            if authoredPageIndex != nil && !isVertical {
                contentStack.layoutIfNeeded()
                let count = contentStack.arrangedSubviews.filter { !$0.isHidden }.count
                let index = min(max(0, pendingPageIndex ?? currentPageIndex), max(0, count - 1))
                let target = CGPoint(x: CGFloat(index) * bounds.width, y: 0)
                let moves = pendingPageIndex != nil || resized || index != currentPageIndex
                let animated = moves && target != contentOffset && !resized && !UIAccessibility.isReduceMotionEnabled
                if moves {
                    pageAnimating = animated
                    setContentOffset(target, animated: animated)
                }
                pendingPageIndex = nil
                currentPageIndex = index
                if !animated && !isTracking && !isDragging && !isDecelerating { settlePage() }
            }
        }
        // A scroll view lays out on every frame of a scroll: the sticky
        // headers follow it here, over content placed by this same pass.
        if !stickyIndices.isEmpty || pendingScrollTarget != nil { contentStack.layoutIfNeeded() }
        updateStickyHeaders()
        scrollToPendingTarget()
        // A nonanimated target changes the offset synchronously inside this
        // layout pass. Rebase the headers against that actual viewport, not
        // the viewport from before the target was applied.
        updateStickyHeaders()
    }

    // MARK: Sticky headers

    private var stickyIndices: [Int] = []
    private var stickyViews: [UIView] = []

    /// `stickyHeaderIndices`, as in React Native: the content's children at
    /// these indices stay at the top of the visible area once scrolled to,
    /// each pushed up by the next. Vertical scroll views only.
    func setStickyHeaderIndices(_ value: Any?) {
        let next = Array(Set(((value as? [Any]) ?? []).compactMap { number($0).map { Int($0) } }.filter { $0 >= 0 })).sorted()
        guard next != stickyIndices else { return }
        stickyIndices = next
        setNeedsLayout()
    }

    /// Where a header sits in the content when it is not stuck.
    private func naturalTop(_ view: UIView) -> CGFloat {
        view.center.y - view.bounds.height / 2
    }

    fileprivate func updateStickyHeaders() {
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

    /// Applies the shared RefreshControl appearance props. UIKit's refresh
    /// control owns the spinner and optional title; keep the authored values
    /// on the control so a later reconciliation can clear them as well.
    func setRefreshAppearance(_ props: [String: Any]) {
        pullToRefresh.tintColor = (props["tintColor"] as? String).flatMap { UIColor(hex: $0) }
        guard let title = props["title"] as? String, !title.isEmpty else {
            pullToRefresh.attributedTitle = nil
            return
        }
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let titleColor = (props["titleColor"] as? String).flatMap({ UIColor(hex: $0) }) {
            attributes[.foregroundColor] = titleColor
        }
        pullToRefresh.attributedTitle = NSAttributedString(string: title, attributes: attributes)
    }

    var isRefreshingNow: Bool { pullToRefresh.isRefreshing }

    @objc private func refreshPulled() {
        refreshHandler?()
        // Once the script has answered the pull (and its render has landed):
        // a script on its own thread answers a turn or two later.
        CraftNativeScriptThread.afterScript { [weak self] in
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
        let point = keyboardTapGesture.location(in: self)
        craftHandleKeyboardTap(in: self, hit: hitTest(point, with: nil), persistTaps: keyboardShouldPersistTaps) {
            self.craftScreenController?.forgetFocusedInput()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        craftScrollGesture(gestureRecognizer, runsWith: otherGestureRecognizer)
    }

    func setAxis(_ axis: NSLayoutConstraint.Axis, resetBounce: Bool = true) {
        if contentStack.axis != axis { setContentNeedsLayout() }
        contentStack.axis = axis
        if resetBounce {
            alwaysBounceVertical = axis == .vertical
            alwaysBounceHorizontal = axis == .horizontal
        }
    }
}

/// Text with padding of its own: the padding is inside the label, around
/// the text, and counts in its measured size.
/// A vector drawing (stx `svg.ts`): an `Svg` node and the shapes below it,
/// replayed from each shape's `geometry` commands - 0 move, 1 line, 2 cubic,
/// 3 quadratic, 4 close, in viewBox units - and scaled to the view. Paint is
/// inherited down the tree as SVG does; `dark:` classes arrive already
/// resolved for the appearance, so a redraw is all a theme change needs.
final class CraftNativeSvgView: UIView {
    var drawing: [String: Any] = [:] {
        didSet {
            animates = Self.hasAnimation(drawing["children"] as? [Any] ?? [])
            setNeedsDisplay()
            updateFrames()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { CraftNativeFrameClock.shared.cancel(self) }

    // MARK: Animation

    /// Whether a shape carries keyframes (SMIL `<animate attributeName="d">`,
    /// stx's `Animate`: an exercise's moving figure).
    private var animates = false
    /// When this drawing's repetition began: each one starts from its first
    /// pose when it comes on screen, as a page's SMIL starts when it loads.
    private var animationStart: CFTimeInterval?

    /// Moving now: on display, and the person has not asked for less motion,
    /// when each shape keeps its own outline (the still pose).
    var isAnimating: Bool { animates && window != nil && !isHidden && !UIAccessibility.isReduceMotionEnabled }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateFrames()
    }

    override var isHidden: Bool {
        didSet { if isHidden != oldValue { updateFrames() } }
    }

    @objc private func reduceMotionChanged() {
        updateFrames()
        setNeedsDisplay()
    }

    /// Frames from the screens' display link (CraftNativeFrameClock, up to
    /// 120Hz) while moving; none at all while still or out of sight.
    private func updateFrames() {
        if isAnimating {
            if animationStart == nil { animationStart = CACurrentMediaTime() }
            CraftNativeFrameClock.shared.request(self) { [weak self] _ in self?.nextFrame() }
        } else {
            animationStart = nil
            CraftNativeFrameClock.shared.cancel(self)
        }
    }

    private func nextFrame() {
        guard isAnimating else { return updateFrames() }
        // Drawn only while some of it is on screen; a row scrolled away keeps
        // its time and is right when it comes back.
        if let window, window.bounds.intersects(convert(bounds, to: window)) { setNeedsDisplay() }
        CraftNativeFrameClock.shared.request(self) { [weak self] _ in self?.nextFrame() }
    }

    private static func hasAnimation(_ children: [Any]) -> Bool {
        children.contains { child in
            guard let node = child as? [String: Any] else { return false }
            if node["type"] as? String == "Animate" { return (node["props"] as? [String: Any])?["frames"] != nil }
            return hasAnimation(node["children"] as? [Any] ?? [])
        }
    }

    /// A shape's outline now: between the keyframes either side of `elapsed`
    /// seconds into its animation (SMIL's linear `calcMode`), or its own
    /// outline when it has none, the animation has ended, or motion is reduced.
    private func outline(of shape: [String: Any]) -> Any? {
        let geometry = (shape["props"] as? [String: Any])?["geometry"]
        guard isAnimating, let start = animationStart,
              let animate = (shape["children"] as? [Any])?.lazy.compactMap({ $0 as? [String: Any] }).first(where: { $0["type"] as? String == "Animate" }),
              let current = Self.keyframe(animate["props"] as? [String: Any] ?? [:], at: CACurrentMediaTime() - start) else { return geometry }
        return current
    }

    /// The outline `elapsed` seconds into an `Animate`'s repetitions; nil
    /// when it does not animate path data or its repetitions are over.
    static func keyframe(_ props: [String: Any], at elapsed: CFTimeInterval) -> [Any]? {
        guard props["attributeName"] as? String == "d",
              let duration = number(props["duration"]), duration > 0, duration.isFinite,
              let frames = (props["frames"] as? [Any])?.compactMap({ ($0 as? [Any])?.compactMap(number) }),
              frames.count >= 2, elapsed >= 0 else { return nil }
        if let count = number(props["repeatCount"]), elapsed >= Double(count * duration) { return nil }
        let given = (props["frameTimes"] as? [Any])?.compactMap(number) ?? []
        let times = given.count == frames.count ? given : frames.indices.map { CGFloat($0) / CGFloat(frames.count - 1) }
        let phase = CGFloat(elapsed.truncatingRemainder(dividingBy: Double(duration))) / duration
        var index = 0
        while index < frames.count - 2, times[index + 1] <= phase { index += 1 }
        let from = frames[index]
        let to = frames[index + 1]
        let span = times[index + 1] - times[index]
        let share = span > 0 ? min(1, max(0, (phase - times[index]) / span)) : 0
        return interpolate(from, to, share).map { NSNumber(value: Double($0)) }
    }

    /// Two outlines with the same commands, a share of the way from one to
    /// the other; the first as it is when their commands differ.
    static func interpolate(_ from: [CGFloat], _ to: [CGFloat], _ share: CGFloat) -> [CGFloat] {
        guard from.count == to.count, share > 0 else { return from }
        var out = from
        var i = 0
        while i < from.count {
            let command = Int(from[i])
            guard to[i] == from[i] else { return from }
            let count: Int
            switch command {
            case 0, 1: count = 2
            case 2: count = 6
            case 3: count = 4
            case 4: count = 0
            default: return from
            }
            guard i + count < from.count else { return from }
            if count > 0 { for k in 1...count { out[i + k] = from[i + k] + (to[i + k] - from[i + k]) * share } }
            i += count + 1
        }
        return out
    }

    var viewBox: CGRect? {
        let props = drawing["props"] as? [String: Any] ?? [:]
        guard let box = props["viewBox"] as? [Any], box.count == 4 else { return nil }
        let n = box.compactMap(number)
        guard n.count == 4, n.allSatisfy(\.isFinite), n[2] > 0, n[3] > 0 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }

    /// Height from the viewBox's proportions, when no style gave one.
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        guard let box = viewBox, size.width > 0, size.width < CraftNativeFlexLayout.unbounded else { return CGSize(width: 0, height: 0) }
        return CGSize(width: size.width, height: size.width * box.height / box.width)
    }

    private struct Paint {
        var fill: String? = "#000000"
        var stroke: String?
        var strokeWidth: CGFloat = 1
        var color: String? = "#000000"
        var opacity: CGFloat = 1
        var fillOpacity: CGFloat = 1
        var strokeOpacity: CGFloat = 1
        var strokeDashoffset: CGFloat = 0
        var strokeMiterlimit: CGFloat = 4
        var fillRule: String = "nonzero"
        var linecap: String?
        var linejoin: String?
        var dashes: [CGFloat]?
        var vectorEffect: String?
        var fontWeight: String?
        var dominantBaseline: String?

        func merged(_ node: [String: Any]) -> Paint {
            var next = self
            let props = node["props"] as? [String: Any] ?? [:]
            let style = node["style"] as? [String: Any] ?? [:]
            func value(_ key: String) -> Any? { style[key] ?? props[key] }
            func finite(_ raw: Any?) -> CGFloat? {
                return number(raw)
            }
            func string(_ raw: Any?) -> String? {
                if let value = raw as? String { return value }
                if let number = raw as? NSNumber { return number.stringValue }
                return nil
            }
            if let color = style["color"] as? String { next.color = color }
            if let fill = style["fill"] as? String ?? props["fill"] as? String { next.fill = fill }
            if let stroke = style["stroke"] as? String ?? props["stroke"] as? String { next.stroke = stroke }
            if let width = finite(style["strokeWidth"] ?? props["strokeWidth"]) { next.strokeWidth = width }
            // Computed style wins over the component prop, matching Android
            // and the browser's cascade when both provide opacity.
            if let opacity = finite(style["opacity"] ?? props["opacity"]) { next.opacity *= opacity }
            if let opacity = finite(value("fillOpacity")) { next.fillOpacity = opacity }
            if let opacity = finite(value("strokeOpacity")) { next.strokeOpacity = opacity }
            if let offset = finite(value("strokeDashoffset")) { next.strokeDashoffset = offset }
            if let limit = finite(value("strokeMiterlimit")), limit > 0 { next.strokeMiterlimit = limit }
            if let rule = value("fillRule") as? String { next.fillRule = rule }
            if let cap = value("strokeLinecap") as? String { next.linecap = cap }
            if let join = value("strokeLinejoin") as? String { next.linejoin = join }
            if let dashes = value("strokeDasharray") as? [Any] { next.dashes = dashes.compactMap(finite).filter { $0 >= 0 } }
            if let vectorEffect = value("vectorEffect") as? String { next.vectorEffect = vectorEffect }
            if let fontWeight = string(value("fontWeight")) { next.fontWeight = fontWeight }
            if let baseline = value("dominantBaseline") as? String { next.dominantBaseline = baseline }
            return next
        }

        func resolve(_ value: String?) -> UIColor? {
            guard let value, value != "none", value != "transparent" else { return nil }
            let text = value == "currentColor" ? (color ?? "#000000") : value
            return UIColor(css: text) ?? UIColor(hex: text)
        }
    }

    /// viewBox units to the view's points, set by each draw.
    private var viewTransform = CGAffineTransform.identity

    /// viewBox to view: centred at one scale (SVG's default, `xMidYMid meet`),
    /// or each axis stretched to fill (`preserveAspectRatio="none"`), as a
    /// chart a page sizes to its width and a fixed height asks for.
    static func transform(box: CGRect, bounds: CGSize, preserveAspectRatio: String?) -> CGAffineTransform? {
        var sx = bounds.width / box.width
        var sy = bounds.height / box.height
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if preserveAspectRatio?.trimmingCharacters(in: .whitespaces) != "none" {
            let scale = min(sx, sy)
            sx = scale
            sy = scale
            dx = (bounds.width - box.width * scale) / 2
            dy = (bounds.height - box.height * scale) / 2
        }
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { return nil }
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: sx, y: sy).translatedBy(x: -box.minX, y: -box.minY)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        viewTransform = .identity
        if let box = viewBox {
            let props = drawing["props"] as? [String: Any] ?? [:]
            guard let transform = CraftNativeSvgView.transform(box: box, bounds: bounds.size, preserveAspectRatio: props["preserveAspectRatio"] as? String) else { return }
            viewTransform = transform
            context.concatenate(transform)
        }
        draw(children: drawing["children"] as? [Any] ?? [], paint: Paint().merged(drawing), in: context)
    }

    private func draw(children: [Any], paint: Paint, in context: CGContext) {
        for case let shape as [String: Any] in children {
            let style = shape["style"] as? [String: Any] ?? [:]
            if style["display"] as? String == "none" { continue }
            let own = paint.merged(shape)
            switch shape["type"] as? String {
            case "G":
                draw(children: shape["children"] as? [Any] ?? [], paint: own, in: context)
            case "SvgText":
                drawText(shape, paint: own)
            case "Animate":
                continue
            default:
                guard let path = CraftNativeSvgView.path(outline(of: shape)) else { continue }
                context.saveGState()
                path.usesEvenOddFillRule = own.fillRule == "evenodd"
                if let fill = own.resolve(own.fill) {
                    context.saveGState()
                    context.setAlpha(max(0, min(1, own.opacity * own.fillOpacity)))
                    fill.setFill()
                    path.fill()
                    context.restoreGState()
                }
                if let stroke = own.resolve(own.stroke), own.strokeWidth > 0 {
                    // `vector-effect="non-scaling-stroke"`: the stroke is in the
                    // view's points, so a stretched chart's line keeps its width
                    // and a round cap stays a round dot.
                    let nonScaling = own.vectorEffect == "non-scaling-stroke"
                    let line: UIBezierPath
                    if nonScaling, let copy = path.copy() as? UIBezierPath {
                        copy.apply(viewTransform)
                        context.concatenate(viewTransform.inverted())
                        line = copy
                    }
                    else {
                        line = path
                    }
                    stroke.setStroke()
                    context.setAlpha(max(0, min(1, own.opacity * own.strokeOpacity)))
                    line.lineWidth = own.strokeWidth
                    line.miterLimit = own.strokeMiterlimit
                    line.lineCapStyle = own.linecap == "round" ? .round : own.linecap == "square" ? .square : .butt
                    line.lineJoinStyle = own.linejoin == "round" ? .round : own.linejoin == "bevel" ? .bevel : .miter
                    if let dashes = own.dashes, !dashes.isEmpty { line.setLineDash(dashes, count: dashes.count, phase: own.strokeDashoffset) }
                    line.stroke()
                }
                context.restoreGState()
            }
        }
    }

    private func drawText(_ node: [String: Any], paint: Paint) {
        let text = (node["children"] as? [Any] ?? []).compactMap { $0 as? String }.joined()
        guard !text.isEmpty else { return }
        let props = node["props"] as? [String: Any] ?? [:]
        let style = node["style"] as? [String: Any] ?? [:]
        let size = number(props["fontSize"]) ?? number(style["fontSize"]) ?? 12
        let weight: UIFont.Weight = {
            switch paint.fontWeight?.lowercased() {
            case "500": return .medium
            case "600": return .semibold
            case "bold", "700", "800", "900": return .bold
            default: return .regular
            }
        }()
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        let resolvedTextColor = paint.resolve(paint.fill) ?? UIColor.label
        let textAlpha = max(0, min(1, paint.opacity * paint.fillOpacity))
        let textColor = resolvedTextColor.withAlphaComponent(resolvedTextColor.cgColor.alpha * textAlpha)
        let string = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: textColor,
        ])
        var x = number(props["x"]) ?? 0
        let y = number(props["y"]) ?? 0
        switch props["textAnchor"] as? String {
        case "middle": x -= string.size().width / 2
        case "end": x -= string.size().width
        default: break
        }
        let baseline: CGFloat
        switch paint.dominantBaseline {
        case "middle", "central", "mathematical": baseline = y - (font.ascender + font.descender) / 2
        case "hanging", "text-before-edge", "before-edge": baseline = y + font.ascender
        case "text-after-edge", "after-edge": baseline = y + font.descender
        default: baseline = y
        }
        string.draw(at: CGPoint(x: x, y: baseline - font.ascender))
    }

    static func path(_ value: Any?) -> UIBezierPath? {
        guard let list = value as? [Any] else { return nil }
        let n = list.compactMap(number)
        guard !n.isEmpty, n.count == list.count, n.allSatisfy(\.isFinite) else { return nil }
        let path = UIBezierPath()
        var i = 0
        func point(_ at: Int) -> CGPoint { CGPoint(x: n[at], y: n[at + 1]) }
        while i < n.count {
            switch Int(n[i]) {
            case 0 where i + 2 < n.count: path.move(to: point(i + 1)); i += 3
            case 1 where i + 2 < n.count: path.addLine(to: point(i + 1)); i += 3
            case 2 where i + 6 < n.count: path.addCurve(to: point(i + 5), controlPoint1: point(i + 1), controlPoint2: point(i + 3)); i += 7
            case 3 where i + 4 < n.count: path.addQuadCurve(to: point(i + 3), controlPoint: point(i + 1)); i += 5
            case 4: path.close(); i += 1
            default: return path
            }
        }
        return path
    }
}

/// A view's linear gradient (stx `bg-gradient-to-br from-* via-* to-*`), kept
/// as its first sublayer - under its subviews - and following its bounds and
/// corners as they change.
private final class CraftNativeGradientLayer: CAGradientLayer {
    private var observations: [NSKeyValueObservation] = []

    static func apply(to view: UIView, direction: String?, colors: [UIColor?]) {
        let existing = view.layer.sublayers?.first as? CraftNativeGradientLayer
        guard let direction, let from = colors[0], let to = colors[2] else {
            existing?.removeFromSuperlayer()
            return
        }
        let layer = existing ?? CraftNativeGradientLayer()
        layer.colors = [from, colors[1], to].compactMap { $0?.cgColor }
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
        layer.startPoint = points.0
        layer.endPoint = points.1
        layer.follow(view)
        guard existing == nil else { return }
        view.layer.insertSublayer(layer, at: 0)
        // The layer's bounds, not the view's: UIKit does not promise KVO for
        // UIView.bounds, and a screen laid out by frame never reported it, so
        // every gradient stayed zero-sized. CALayer's own bounds always do.
        layer.observations = [
            view.layer.observe(\.bounds) { [weak layer, weak view] _, _ in if let view { layer?.follow(view) } },
            view.layer.observe(\.cornerRadius) { [weak layer, weak view] _, _ in if let view { layer?.follow(view) } },
        ]
    }

    private func follow(_ view: UIView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = view.bounds
        cornerRadius = view.layer.cornerRadius
        maskedCorners = view.layer.maskedCorners
        masksToBounds = cornerRadius > 0
        CATransaction.commit()
    }
}

/// A button that keeps the padding its style asks for (`px-4 py-2`). A bare
/// UIButton sizes to its title and ignores it, so a styled button drew as a
/// pill with its label touching the edges. The padding is added to its size
/// and the label laid out inside it, at the alignment the style asked for.
private final class CraftNativeButton: UIButton {
    var padding: UIEdgeInsets = .zero {
        didSet {
            guard padding != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + padding.left + padding.right, height: size.height + padding.top + padding.bottom)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = super.sizeThatFits(CGSize(
            width: max(0, size.width - padding.left - padding.right),
            height: max(0, size.height - padding.top - padding.bottom)
        ))
        return CGSize(width: inner.width + padding.left + padding.right, height: inner.height + padding.top + padding.bottom)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard padding != .zero, let label = titleLabel else { return }
        let area = bounds.inset(by: padding)
        let fitted = label.sizeThatFits(area.size)
        let width = min(ceil(fitted.width), area.width)
        let height = min(ceil(fitted.height), area.height)
        let x: CGFloat
        switch contentHorizontalAlignment {
        case .left, .leading: x = area.minX
        case .right, .trailing: x = area.maxX - width
        default: x = area.midX - width / 2
        }
        label.frame = CGRect(x: x, y: area.midY - height / 2, width: width, height: height)
    }
}

/// Opt-in solid switch. Draws only public UIControl content; it neither walks
/// UISwitch's private views nor changes UIKit animations elsewhere in the app.
final class CraftNativeSolidSwitch: UIControl {
    private(set) var isOn = false
    var onColor: UIColor? { didSet { setNeedsDisplay() } }
    var offColor: UIColor? { didSet { setNeedsDisplay() } }
    var thumbColor: UIColor? { didSet { setNeedsDisplay() } }
    private let naturalSize = UISwitch().intrinsicContentSize
    private var touchOrigin: CGPoint?
    private var dragPosition: CGFloat?
    override var intrinsicContentSize: CGSize { naturalSize }
    override var isEnabled: Bool {
        didSet {
            if !isEnabled { cancelTracking(with: nil) }
            refreshAccessibility()
            setNeedsDisplay()
        }
    }
    override var canBecomeFirstResponder: Bool { isEnabled }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = true
        refreshAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setOn(_ value: Bool) {
        isOn = value
        refreshAccessibility()
        setNeedsDisplay()
    }

    func refreshAccessibility() {
        accessibilityTraits = .button
        if #available(iOS 17.0, *) { accessibilityTraits.insert(.toggleButton) }
        if isOn { accessibilityTraits.insert(.selected) }
        if !isEnabled { accessibilityTraits.insert(.notEnabled) }
        accessibilityValue = isOn ? "1" : "0"
    }

    private var trackRect: CGRect {
        let size = CGSize(width: min(bounds.width, naturalSize.width), height: min(bounds.height, naturalSize.height))
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    var thumbRect: CGRect {
        let track = trackRect.insetBy(dx: 2, dy: 2)
        let onRight = effectiveUserInterfaceLayoutDirection != .rightToLeft
        let position = dragPosition ?? ((isOn == onRight) ? 1 : 0)
        return CGRect(x: track.minX + (track.width - track.height) * position, y: track.minY, width: track.height, height: track.height)
    }
    override func draw(_ rect: CGRect) {
        let track = trackRect
        guard track.width > 4, track.height > 4 else { return }
        (isEnabled ? (isOn ? onColor ?? .systemGreen : offColor ?? .systemGray4) : UIColor.systemGray4).setFill()
        UIBezierPath(roundedRect: track, cornerRadius: track.height / 2).fill()
        // The solid variant deliberately ignores thumb alpha. No transient
        // glass, scaling, fade, implicit layer animation or delayed redraw.
        (thumbColor ?? .white).withAlphaComponent(1).setFill()
        UIBezierPath(ovalIn: thumbRect).fill()
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsDisplay()
    }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled else { return false }
        touchOrigin = touch.location(in: self)
        dragPosition = nil
        return true
    }
    func updateDrag(to point: CGPoint) {
        let track = trackRect.insetBy(dx: 2, dy: 2)
        dragPosition = min(1, max(0, (point.x - track.minX - track.height / 2) / max(1, track.width - track.height)))
        setNeedsDisplay()
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, let origin = touchOrigin else { return false }
        let point = touch.location(in: self)
        if dragPosition != nil || abs(point.x - origin.x) > 6 { updateDrag(to: point) }
        return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        defer { touchOrigin = nil; dragPosition = nil; setNeedsDisplay() }
        guard isEnabled, let touch, touchOrigin != nil,
              bounds.insetBy(dx: -10, dy: -10).contains(touch.location(in: self)) else { return }
        let next = dragPosition.map { ($0 >= 0.5) == (effectiveUserInterfaceLayoutDirection != .rightToLeft) } ?? !isOn
        if next != isOn { setOn(next); sendActions(for: .valueChanged) }
    }
    override func cancelTracking(with event: UIEvent?) {
        touchOrigin = nil
        dragPosition = nil
        setNeedsDisplay()
    }
    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        setOn(!isOn)
        sendActions(for: .valueChanged)
        return true
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if isEnabled, presses.contains(where: { $0.key?.keyCode == .keyboardSpacebar || $0.key?.keyCode == .keyboardReturnOrEnter }) {
            _ = accessibilityActivate()
        } else { super.pressesEnded(presses, with: event) }
    }
}

/// A native checkbox button. UIKit has no checkbox control, so use the system
/// square/checkmark symbols while keeping the control's title and accessibility
/// state native and keyboard/touch reachable.
private final class CraftNativeCheckboxButton: UIButton {
    var indeterminate = false
}

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

/// A non-editable text view used when a native Text explicitly opts into
/// selection. UILabel has no selection model; UITextView supplies UIKit's
/// standard loupe, menu and copy behavior while remaining a plain text leaf.
private final class CraftNativeSelectableTextView: UITextView {
    convenience init() {
        self.init(frame: .zero, textContainer: nil)
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        self.textContainer.lineFragmentPadding = 0
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        self.textContainer.lineFragmentPadding = 0
    }
}

/// A one-line TextInput. Its style's padding is where the text and the
/// placeholder start, as in a web input; UITextField has no padding of its own.
final class CraftNativeTextField: UITextField {
    var padding = UIEdgeInsets.zero {
        didSet {
            guard padding != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        super.textRect(forBounds: bounds.inset(by: padding))
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        super.editingRect(forBounds: bounds.inset(by: padding))
    }

    override func placeholderRect(forBounds bounds: CGRect) -> CGRect {
        super.placeholderRect(forBounds: bounds.inset(by: padding))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + padding.left + padding.right, height: size.height + padding.top + padding.bottom)
    }
}

private final class CraftNativeFlexSpacer: UIView {}

/// An SF Symbol leaf. Its natural size is the symbol's, or a 20 pt square
/// when the style gives it no size at all.
private final class CraftNativeIconView: UIImageView {
    var defaultBox: CGFloat? { didSet { if defaultBox != oldValue { invalidateIntrinsicContentSize() } } }

    /// An icon says only what the screen labels it. iOS gives a symbol image
    /// a description of its own ("Circle", "Chevron"), which VoiceOver read
    /// as an extra stop and a row read as part of its text; an unlabelled
    /// icon is decoration, as UIKit's own glyph accessories are.
    private var authoredLabel: String?

    override var accessibilityLabel: String? {
        get { authoredLabel }
        set { authoredLabel = newValue }
    }

    override var isAccessibilityElement: Bool {
        get { authoredLabel != nil && super.isAccessibilityElement }
        set { super.isAccessibilityElement = newValue }
    }

    override var intrinsicContentSize: CGSize {
        if let defaultBox { return CGSize(width: defaultBox, height: defaultBox) }
        return super.intrinsicContentSize
    }
}

private final class CraftNativeTextView: UITextView {
    private let placeholderLabel = UILabel()
    private var nativeTextContainerInset: UIEdgeInsets?
    private var nativeLineFragmentPadding: CGFloat?
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

    func applyAuthoredPadding(_ padding: UIEdgeInsets) {
        if nativeTextContainerInset == nil {
            nativeTextContainerInset = textContainerInset
            nativeLineFragmentPadding = textContainer.lineFragmentPadding
        }
        if padding == .zero {
            textContainerInset = nativeTextContainerInset ?? .zero
            textContainer.lineFragmentPadding = nativeLineFragmentPadding ?? 0
        } else {
            textContainerInset = padding
            textContainer.lineFragmentPadding = 0
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A multiline input grows with its text up to its `maxHeight`, then
        // scrolls inside itself. Never scrolling, the text past that height
        // was cut off and could not be reached (a long workout comment).
        // With scrolling off, contentSize is the view's own height: measure
        // the text itself.
        let needed = isEditable ? sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height : 0
        let overflows = isEditable && bounds.height > 0 && needed > bounds.height + 1
        if isScrollEnabled != overflows {
            isScrollEnabled = overflows
            if overflows, isFirstResponder { scrollRangeToVisible(selectedRange) }
        }
        // Showing all its text, it has nothing to scroll. An offset left from
        // UIKit keeping the caret in view while the view was a layout short
        // of its text moved every line down inside it, and the caret of a
        // growing comment sat below the part of the screen it was kept in.
        if !isScrollEnabled, contentOffset != .zero { contentOffset = .zero }
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
        isScrollEnabled = false
        placeholderLabel.numberOfLines = 0
        placeholderLabel.font = font
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
        refreshPlaceholder()
    }
}

/// Where native screens run their JavaScript.
///
/// On the main thread by default. With `nativeScriptThread: "background"` in
/// craft.config.json, every screen's script runs on one serial thread of its
/// own (the shared virtual machine's only thread): evaluating its bundle,
/// handling events and timers, and working out each render all leave the main
/// thread, which only applies the results to UIKit. Messages between the two
/// were already asynchronous JSON, so the order of everything is kept.
enum CraftNativeScriptThread {
    static var isBackground = false
    static let queue = DispatchQueue(label: "craft.native.script", qos: .userInteractive)

    /// `work` where the screens' JavaScript runs: now on the main thread, or
    /// queued in order on the script thread. With frame pacing on
    /// (`CRAFT_FRAME_PACING=1`), work that waited or ran for 4ms or more is
    /// logged under `label`, so a slow screen can be told from a queued one.
    static func run(label: @autoclosure @escaping () -> String = "script", _ work: @escaping () -> Void) {
        let pacing = CraftFramePacing.shared
        guard pacing.enabled else {
            if isBackground { queue.async(execute: work) } else { work() }
            return
        }
        let queued = CACurrentMediaTime()
        let timed = {
            let started = CACurrentMediaTime()
            work()
            let ran = CACurrentMediaTime() - started
            let waited = started - queued
            if waited + ran >= 0.004 { pacing.scriptWork(label(), waited: waited, ran: ran) }
        }
        if isBackground { queue.async(execute: timed) } else { timed() }
    }

    /// From the script thread, `work` on the main thread, not waited for.
    static func toMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// From the script thread, `work` on the main thread, waited for: for the
    /// few host functions a script calls synchronously that read main-thread
    /// state (the Web Audio graph). The main thread never waits for the
    /// script thread, so this cannot deadlock.
    static func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    /// `work` on the main thread once a script has handled what was sent to
    /// it before now, and what it sent back has been applied.
    static func afterScript(_ work: @escaping () -> Void) {
        if isBackground { queue.async { DispatchQueue.main.async(execute: work) } }
        else { DispatchQueue.main.async(execute: work) }
    }
}

extension CAAnimation {
    /// Asks for the display's full rate, up to 120Hz on ProMotion. Core
    /// Animation otherwise picks a rate for the motion and often stays at 60;
    /// a transition or a spring the eye follows reads smoother at 120.
    func atDisplayRate() {
        if #available(iOS 15.0, *) { preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120) }
    }
}

/// `requestAnimationFrame` for native screens: one display link, at the
/// display's own rate (up to 120Hz on a ProMotion iPhone, which the app
/// allows with `CADisableMinimumFrameDurationOnPhone`), running only while a
/// screen on display is waiting for a frame. Each frame hands every waiting
/// screen one `__craftNativeFireFrame`, where its script runs; a screen asks
/// again for the frame after, as a browser's page does. A screen out of sight
/// waits until it is shown, as a browser pauses a hidden tab's frames, and as
/// Craft's Android host does (Choreographer). Main thread only.
final class CraftNativeFrameClock: NSObject {
    static let shared = CraftNativeFrameClock()

    private var waiting: [ObjectIdentifier: (CFTimeInterval) -> Void] = [:]
    private var link: CADisplayLink?
    /// The display's monotonic timestamp, captured before handing off scripts.
    private var lastTimestamp: CFTimeInterval = 0

    /// How many screens wait for the next frame.
    var waitingCount: Int { waiting.count }
    /// Whether the display link is counting frames now.
    var isRunning: Bool { link.map { !$0.isPaused } ?? false }

    /// `deliver` on the next frame, once. Asking again before it comes keeps one.
    func request(_ owner: AnyObject, _ deliver: @escaping (CFTimeInterval) -> Void) {
        waiting[ObjectIdentifier(owner)] = deliver
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            if #available(iOS 15.0, *) {
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
            }
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
    }

    /// `owner` no longer waits: it went out of sight or away.
    func cancel(_ owner: AnyObject) {
        waiting.removeValue(forKey: ObjectIdentifier(owner))
        if waiting.isEmpty { link?.isPaused = true }
    }

    @objc private func frame(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        // Keep waiting for a new vsync rather than delivering a duplicate or
        // stale display timestamp after the link is paused and requested again.
        guard timestamp.isFinite, timestamp > lastTimestamp else { return }
        lastTimestamp = timestamp
        let due = waiting
        waiting.removeAll()
        if waiting.isEmpty { link.isPaused = true }
        due.values.forEach { $0(timestamp) }
    }
}

/// The native screens' JavaScript. A screen is a JavaScriptCore context of
/// its own and evaluates the whole file it is given, so each route has a file
/// of its own when stx wrote one (`dist/native-screens/<route>.js`, stx's
/// `routesDir`): a screen then parses its own code rather than every
/// screen's. The one-file `dist/native-screen.js` remains the fallback.
enum CraftNativeBundle {
    /// Every screen's context lives in this one virtual machine. They all run
    /// on one thread (main, or the script thread: CraftNativeScriptThread),
    /// the machine's only one, and sharing it shares its
    /// code cache: a screen opened again (a second workout, a tab rebuilt)
    /// is not parsed again. Each screen keeps a global object of its own.
    static let virtualMachine = JSVirtualMachine()!

    /// JavaScriptCore's first machine and context, made on the script thread
    /// at launch instead of on the main thread by the first screen: that one-
    /// time setup was a quarter of a second of the first tab's mount, all of
    /// it in front of the first frame. Nothing is evaluated, so the main
    /// thread never waits on the machine for it.
    static func prewarm() {
        CraftNativeScriptThread.queue.async {
            _ = JSContext(virtualMachine: virtualMachine)
        }
    }

    private static let sources: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        // Room for the one-file bundle, or a dozen route files.
        cache.totalCostLimit = 24 << 20
        return cache
    }()

    /// The file a route runs from: its own, else the one-file bundle.
    static func url(for route: String?) -> URL? {
        if let route, !route.isEmpty, !route.contains("/"), !route.hasPrefix("."),
           let own = Bundle.main.url(forResource: route, withExtension: "js", subdirectory: "dist/native-screens") {
            return own
        }
        return Bundle.main.url(forResource: "native-screen", withExtension: "js", subdirectory: "dist")
            ?? Bundle.main.url(forResource: "native-screen", withExtension: "js")
    }

    /// Whether the app has native screens to run at all.
    static var isAvailable: Bool {
        url(for: nil) != nil || Bundle.main.url(forResource: "native-screens", withExtension: nil, subdirectory: "dist") != nil
    }

    /// The runtime a route file runs on (stx's `__runtime.js`): evaluated
    /// first in each screen's context, as a source of its own, so the shared
    /// virtual machine parses it once for every screen. Nil for a one-file
    /// bundle, which carries its runtime itself, and for route files from an
    /// stx that wrote none.
    static func runtime(for route: URL) -> (source: String, url: URL)? {
        guard route.deletingLastPathComponent().lastPathComponent == "native-screens",
              let url = Bundle.main.url(forResource: "__runtime", withExtension: "js", subdirectory: "dist/native-screens") else { return nil }
        return read(url)
    }

    /// A language's messages for an area, as JSON text: stx's
    /// `__messages/<language>/<area>.json` beside the route files. Nil for a
    /// language or area the build has none for, and for a name that is not
    /// one (no path outside the messages).
    static func messages(language: String, area: String) -> String? {
        guard language.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              area.range(of: #"^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*$"#, options: .regularExpression) != nil,
              let routes = Bundle.main.url(forResource: "native-screens", withExtension: nil, subdirectory: "dist") else { return nil }
        let url = routes.appendingPathComponent("__messages", isDirectory: true)
            .appendingPathComponent(language, isDirectory: true)
            .appendingPathComponent("\(area).json")
        return read(url)?.source
    }

    /// The route's source, read from disk once and kept while memory allows:
    /// a push read and decoded the file on the main thread every time.
    static func source(for route: String?) -> (source: String, url: URL)? {
        guard let url = url(for: route) else { return nil }
        return read(url)
    }

    /// gzip assets are immutable, decoded lazily and held in the same bounded cache.
    private static func unpack(_ bytes: Data) -> Data? {
        guard bytes.starts(with: [0x1f, 0x8b]) else { return bytes }
        return bytes.withUnsafeBytes { raw -> Data? in
            var stream = z_stream()
            guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
            defer { inflateEnd(&stream) }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(bytes.count)
            var result = Data()
            var chunk = [UInt8](repeating: 0, count: 32768)
            var status = Z_OK
            repeat {
                status = chunk.withUnsafeMutableBytes { output in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { return nil }
                result.append(contentsOf: chunk.prefix(chunk.count - Int(stream.avail_out)))
                guard result.count <= 64 << 20 else { return nil }
            } while status != Z_STREAM_END
            return result
        }
    }

    private static func read(_ url: URL) -> (source: String, url: URL)? {
        let key = url.path as NSString
        if let cached = sources.object(forKey: key) { return (cached as String, url) }
        guard let bytes = try? Data(contentsOf: url), let decoded = unpack(bytes), let text = String(data: decoded, encoding: .utf8) else { return nil }
        sources.setObject(text as NSString, forKey: key, cost: text.utf8.count)
        return (text, url)
    }
}

private final class CraftNativeScreenRootView: UIView {
    weak var controller: CraftNativeScreenController?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // A popup's host frame is only its authored card, so UIKit would not
        // ask it about an outside point. Shield that point at the screen root
        // only when a blocking modal is underneath; ordinary non-modal
        // overlays remain pass-through.
        if let controller {
            for modal in controller.view.subviews.compactMap({ $0 as? CraftNativeModalView }).reversed()
                where !modal.blocksBackground && !modal.isHidden && modal.alpha > 0.01 {
                let local = modal.convert(point, from: self)
                if !modal.bounds.contains(local) && (modal.dismissOnOutsideTap || controller.hasBlockingModalBelow(modal)) { return modal }
            }
        }
        return super.hitTest(point, with: event)
    }
}

final class CraftNativeScreenController: UIViewController, UIScrollViewDelegate, UITextFieldDelegate, UITextViewDelegate, UIPickerViewDataSource, UIPickerViewDelegate {
    private final class RenderedNode {
        /// A recycled list row's root takes the identity of the row it shows next.
        var identity: String
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

    // A reparented popup must keep the live native view that owns its draft,
    // focus and selection. The mutation protocol identifies nodes globally;
    // retain the previous render by that ID when the new parent has no local
    // identity entry for it.
    private var previousNodesByProtocolID: [String: RenderedNode] = [:]
    private var adoptedPreviousProtocolIDs = Set<String>()

    private let config: CraftConfig
    private let routeName: String?
    private(set) var routeParams: [String: Any]
    private(set) var routeProps: [String: Any]
    private let jsContext = JSContext(virtualMachine: CraftNativeBundle.virtualMachine)!
    private let rootStack = CraftNativeFlowView()
    private var handlers: [ObjectIdentifier: String] = [:]
    private var pressInHandlers: [ObjectIdentifier: String] = [:]
    private var pressOutHandlers: [ObjectIdentifier: String] = [:]
    private var underlayShowHandlers: [ObjectIdentifier: String] = [:]
    private var underlayHideHandlers: [ObjectIdentifier: String] = [:]
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
    /// A controlled switch can be reconciled while UIKit is still animating
    /// the user's tap. Remember that native value briefly so the echo does not
    /// interrupt the animation and leave the thumb painted at its old edge.
    private var switchUserValues: [ObjectIdentifier: Bool] = [:]
    private var pickerOptions: [ObjectIdentifier: [(value: String, label: String)]] = [:]
    private var modalVisibility: [ObjectIdentifier: Bool] = [:]
    private var modalFocusRestore: [ObjectIdentifier: UIView] = [:]
    private var layoutHandlers: [ObjectIdentifier: String] = [:]
    private var lastLayoutFrames: [ObjectIdentifier: CGRect] = [:]
    private var tapRecognizers: [ObjectIdentifier: UITapGestureRecognizer] = [:]
    private var longPressRecognizers: [ObjectIdentifier: UILongPressGestureRecognizer] = [:]
    private var pressFeedbackRecognizers: [ObjectIdentifier: UILongPressGestureRecognizer] = [:]
    private var imageSources: [ObjectIdentifier: String] = [:]
    private var imageTasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var imageErrors: [ObjectIdentifier: String] = [:]
    /// Text inputs retain UIKit's generated accessibility value unless the
    /// bundle authored one; remember that distinction so removing the prop
    /// restores the native value instead of leaving stale metadata behind.
    private var authoredAccessibilityValues = Set<ObjectIdentifier>()
    private var checkboxIndeterminate: [ObjectIdentifier: Bool] = [:]
    private var tintedImages = Set<ObjectIdentifier>()
    private var imageLoadStartHandlers: [ObjectIdentifier: String] = [:]
    private var imageLoadHandlers: [ObjectIdentifier: String] = [:]
    private var imageLoadEndHandlers: [ObjectIdentifier: String] = [:]
    private var imageErrorHandlers: [ObjectIdentifier: String] = [:]
    /// Native links keep their target separate from optional press handlers.
    /// The compiler can emit an anchor as `TouchableOpacity`, so this map is
    /// intentionally shared by Link and the generic pressable path.
    private var linkTargets: [ObjectIdentifier: String] = [:]
    /// Views by their `transitionID`: one element across an animated change.
    private var transitionIDs: [ObjectIdentifier: String] = [:]
    /// `craft.animation.next`: the screen as it was, waiting for the change.
    private var animationTransaction: CraftNativeAnimationTransaction?
    /// The animation of the last change, still running.
    private var runningAnimation: CraftNativeRunningAnimation?
    private var renderedRoot: RenderedNode?
    private weak var lastFocusedInput: UIView?

    /// The person put the keyboard away (Return, or a tap on nothing in a
    /// scroll view): the last input is let go. Kept, the next render or
    /// button press focused it again and the keyboard came straight back.
    func forgetFocusedInput(_ input: UIView? = nil) {
        if input == nil || lastFocusedInput === input { lastFocusedInput = nil }
    }
    func forgetFocusedInput(in container: UIView) {
        if let input = lastFocusedInput, input === container || input.isDescendant(of: container) {
            lastFocusedInput = nil
        }
    }
    private var flatListRows: [ObjectIdentifier: [String: RenderedNode]] = [:]
    /// Rows their cells left for reuse, by list and by the row's root view.
    private var flatListRecycled: [ObjectIdentifier: [ObjectIdentifier: RenderedNode]] = [:]
    private var flatListOwners: [String: String] = [:]
    /// A drawing's shapes are not views: a change to one redraws its `Svg`.
    private var svgOwners: [String: String] = [:]
    private let mutationDocument = CraftNativeMutationDocument()
    /// The screen's Web Audio (CraftWebAudio.swift): its `AudioContext`s.
    private let audio = CraftWebAudio()
    /// `craft.audio`'s sounds and the streaming responses this screen reads.
    private let sounds = CraftNativeSounds()
    private let streams = CraftNativeEventStreams()
    /// A request a screen-owned module answers, by request token, and how to
    /// call it off when it times out or is cancelled.
    private var screenRequestCancellers: [String: () -> Void] = [:]
    /// Whether the script was last told the screen is on screen; nil until the
    /// first report. A screen first reported hidden - an adjacent tab the
    /// shell prepares ahead of a swipe - must hear that, or its script takes
    /// itself to be in front and acts on it: a sign-in guard on a prepared
    /// Record tab pushed Login over the Feed at launch.
    private var reportedVisible: Bool?
    private var voiceRecordingOwner: String?
    private let capabilityScope = UUID().uuidString
    private var pendingCapabilityRequests = Set<String>()
    private var pendingCapabilityDeadlines: [String: DispatchWorkItem] = [:]
    /// The script's timers. Touched only where the script runs.
    private final class Timers {
        var pending: [Int: DispatchWorkItem] = [:]
    }
    private let timers = Timers()
    /// The script asked for an animation frame it has not had yet
    /// (`requestAnimationFrame`, CraftNativeFrameClock). Main thread only.
    private var frameWanted = false
    private let frameTimeOrigin = CACurrentMediaTime()
    private var lastFrameTimestamp = -Double.infinity
    /// Vsync is delivered on main but may wait on the script queue. Closing
    /// on main invalidates queued delivery without retaining the controller
    /// or holding a lock while JavaScript calls synchronous UIKit APIs.
    private final class FrameDelivery {
        private let lock = NSLock()
        private var open = true
        var isOpen: Bool { lock.withLock { open } }
        func close() { lock.withLock { open = false } }
    }
    private let frameDelivery = FrameDelivery()
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var deepLinkListener: UUID?
    private var keyboardSafeAreaInset: CGFloat = 0
    /// Where the keyboard is on the screen while it is up, in screen coordinates.
    private var keyboardScreenFrame: CGRect?
    private var keyboardInsetsScheduled = false
    /// The hybrid shell (CraftHybrid.swift), when this screen is one of a web
    /// app's native screens: told of the first frame, of a first frame that
    /// could not be drawn, and of `craft.navigation.open(path)`.
    weak var hybridEvents: CraftHybridScreenEvents?
    private var hybridRendered = false
    private var runtimeDisposed = false
    private let storageLifetime = CraftNativeStorageLifetime()
    /// The app script (`nativeApp`, CraftHybrid.swift): a bundle route with
    /// no screen, loaded once and never shown, that runs for the app's life.
    /// It hears every `APP_STATE` and the app's events (`CRAFT_EVENT`), no
    /// `DEEP_LINK`; it can open paths but not push, pop or style a bar.
    let isAppScript: Bool

    init(config: CraftConfig, routeName: String? = nil, routeParams: [String: Any] = [:], routeProps: [String: Any] = [:], isAppScript: Bool = false) {
        self.config = config
        self.routeName = routeName
        self.routeParams = routeParams
        self.routeProps = routeProps
        self.isAppScript = isAppScript
        super.init(nibName: nil, bundle: nil)
        CraftVoiceRecording.prepareForLaunch(includeLegacy: config.enableAudioRecording)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = CraftNativeScreenRootView()
        root.controller = self
        view = root
    }

    deinit {
        disposeRuntime()
        imageTasks.values.forEach { $0.cancel() }
        pendingCapabilityDeadlines.values.forEach { $0.cancel() }
        let timers = self.timers
        CraftNativeScriptThread.run { timers.pending.values.forEach { $0.cancel() } }
        pendingCapabilityRequests.forEach { CraftNativeActions.cancel(requestToken: $0) }
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        if let deepLinkListener = deepLinkListener { DeepLinkManager.shared.removeNativeListener(deepLinkListener) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        CraftInterfaceStyleController.apply(to: self, config: config)
        navigationItem.title = routeName ?? config.appName
        view.backgroundColor = config.resolvedBackgroundColor
        if let tint = config.tintColor.flatMap({ UIColor(hex: $0) }) { view.tintColor = tint }
        rootStack.axis = .vertical
        rootStack.alignItems = "stretch"
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)
        rootTopToSafeArea = rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        rootTopToView = rootStack.topAnchor.constraint(equalTo: view.topAnchor)
        rootBottomToSafeArea = rootStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        rootBottomToView = rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        rootLeadingToSafeArea = rootStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor)
        rootLeadingToView = rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        rootTrailingToSafeArea = rootStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        rootTrailingToView = rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        NSLayoutConstraint.activate([
            rootTopToSafeArea!,
            rootBottomToSafeArea!,
            rootLeadingToSafeArea!,
            rootTrailingToSafeArea!
        ])
        let pacing = CraftFramePacing.shared
        let inputs = scriptInputs()
        let name = routeName ?? "screen"
        CraftNativeScriptThread.run(label: "mount \(name)") { [self] in
            pacing.measure("mount \(name) setup") { setupJavaScript(inputs) }
            pacing.measure("mount \(name) bundle") { loadBundle() }
        }
        observeNativeEvents()
        if isAppScript {
            // Its bundle has run, so its listeners are in place: the app's
            // events that waited for it arrive now, in order.
            CraftEventManager.shared.appScriptReady { [weak self] event, detail in
                self?.send(type: "CRAFT_EVENT", payload: ["event": event, "detail": detail])
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        let colorChanged = previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle
        let textSizeChanged = previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
        guard colorChanged || textSizeChanged else { return }
        refreshTraitDefaults()
        sendAppearance()
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
        applyNavigationBarAppearance()
        // Each screen says whether it wants the tab bar, so one that hid it
        // never leaves it hidden for the next. Only the screen on screen:
        // UIKit tells a tab's screen prepared in a hidden stack that it
        // appears too, and that one took the accessory of the screen showing.
        if isShownOnScreen { restoreShellChrome() }
        refreshTraitDefaults()
    }

    /// In the window with nothing above it hidden: the screen the person
    /// sees, not a tab prepared behind it.
    private var isShownOnScreen: Bool {
        guard let window = view.window else { return false }
        if let shell = navigationController?.parent as? CraftHybridController,
           !shell.isFocusedScreen(self) { return false }
        var candidate: UIView? = view
        while let current = candidate, current !== window {
            if current.isHidden { return false }
            candidate = current.superview
        }
        return true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        screenVisibilityChanged(false)
        stopCelebrations(in: view)
        // Release only this screen's accessory. A retained or prepared screen
        // can disappear after the destination has already published its own;
        // released, it stays drawn until the destination says what it wants.
        CraftChrome.shared.releaseTabAccessory(ownedBy: self)
        // Popped (or its stack dismissed) while the bar was away: it comes
        // back for whatever shows next, a web page included.
        if tabBarHidden, isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            CraftChrome.shared.setHiddenByScreen(false)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A tab prepared in a hidden stack "appears" to UIKit as well; the
        // shell says when it really shows (screenVisibilityChanged).
        if isShownOnScreen {
            hasAppeared = true
            screenVisibilityChanged(true)
            // A navigation breadcrumb for the crash reporter: the trail a
            // crash report carries is the screens that led to it.
            if !isAppScript, let routeName, !routeName.isEmpty {
                CraftCrashReporter.shared.screenAppeared(routeName)
            }
        }
        // onLayout reports views that are on screen: a pushed screen lays
        // out before it has a window, and nothing moved again once it had
        // one, so its rows never reported.
        emitLayoutEvents()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Gone for good only when its stack no longer holds it. UIKit's
        // `isMovingFromParent` is no witness: a tab's first screen covered
        // by a push while its own first appearance was still settling (an
        // app script opening the sign-in screen at launch) reports it true
        // while still the root of its stack, and the screen's script was
        // torn down under it, frozen on whatever it showed then.
        let inStack = navigationController?.viewControllers.contains(where: { $0 === self }) ?? false
        if !inStack {
            disposeRuntime()
        } else {
            screenVisibilityChanged(false)
        }
    }

    private func restoreShellChrome() {
        guard !isAppScript else { return }
        CraftChrome.shared.setHiddenByScreen(tabBarHidden)
        // A screen not yet asked about the accessory (one shown for the first
        // time, before its script has run) leaves the bar as it is; one that
        // has drawn without asking for it takes off what nobody claims.
        if tabAccessoryDeclared { CraftChrome.shared.updateTabAccessory(tabAccessory, owner: self) }
        else if hybridRendered { CraftChrome.shared.clearUnclaimedTabAccessory() }
    }

    /// `requestAnimationFrame`: the next display frame, for a screen on display
    /// (or the app script, which is never shown). One out of sight keeps the
    /// request until it is shown again (screenVisibilityChanged).
    private func requestFrame() {
        guard !runtimeDisposed, !frameWanted else { return }
        frameWanted = true
        guard isAppScript || reportedVisible != false else { return }
        CraftNativeFrameClock.shared.request(self) { [weak self] timestamp in self?.fireFrame(timestamp: timestamp) }
    }

    // Native display-delivery boundary; internal so the native fixture can
    // exercise stale startup ticks without depending on simulator timing.
    func fireFrame(timestamp displayTimestamp: CFTimeInterval) {
        guard frameWanted, !runtimeDisposed else { return }
        // Another screen's callback can hide this screen after the clock has
        // captured its batch. Keep the request pending until it is shown.
        guard isAppScript || reportedVisible != false else { return }
        let timestamp = (displayTimestamp - frameTimeOrigin) * 1000
        // A display tick may predate a newly created controller. Clamping
        // those ticks to zero delivers multiple frames at the same time.
        // Wait for a valid tick instead, keeping the JS batch cancellable.
        guard displayTimestamp.isFinite, timestamp.isFinite, timestamp >= 0,
              timestamp > lastFrameTimestamp else {
            CraftNativeFrameClock.shared.request(self) { [weak self] timestamp in self?.fireFrame(timestamp: timestamp) }
            return
        }
        lastFrameTimestamp = timestamp
        frameWanted = false
        let context = jsContext
        let route = routeName ?? "screen"
        let delivery = frameDelivery
        CraftNativeScriptThread.run(label: "frame \(route)") {
            guard delivery.isOpen else { return }
            context.objectForKeyedSubscript("__craftNativeFireFrame")?.call(withArguments: [timestamp])
        }
    }

    /// The screen came on screen or went off it: a screen pushed over it was
    /// popped, or the hybrid shell switched to or away from its tab (which
    /// hides a stack rather than moving it, so UIKit says nothing). The first
    /// appearance of a screen shown as it mounts is the mount, not news; every
    /// later one is `SCREEN_FOCUS { focused: true }`, and going away is
    /// `focused: false`. A screen that mounts hidden is told `focused: false`
    /// first, so its first showing is news too.
    func screenVisibilityChanged(_ visible: Bool) {
        guard !runtimeDisposed else { return }
        if !visible, isViewLoaded { stopCelebrations(in: view) }
        // Hidden tab stacks receive no UIKit appearance callback. A cancelled
        // preview also restores a screen that never lost focus, so restore its
        // chrome even when no new SCREEN_FOCUS event is needed.
        if visible { restoreShellChrome() }
        // A prepared tab the shell now shows has appeared once its frame is
        // drawn; what its script asks for until then is there from the start.
        if visible, !hasAppeared {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isViewLoaded, self.isShownOnScreen else { return }
                self.hasAppeared = true
            }
        }
        if visible, frameWanted { CraftNativeFrameClock.shared.request(self) { [weak self] timestamp in self?.fireFrame(timestamp: timestamp) } }
        if !visible { CraftNativeFrameClock.shared.cancel(self) }
        guard visible != reportedVisible else { return }
        let first = reportedVisible == nil
        reportedVisible = visible
        if visible { DeepLinkManager.shared.replayNativeLinks() }
        if first, visible { return }
        send(type: "SCREEN_FOCUS", payload: ["focused": visible])
    }

    /// New params or props for the screen already showing a path: opened
    /// again with another query or a structured handoff. The two namespaces
    /// stay separate so props cannot collide with path/query params.
    func receiveRouteParams(_ params: [String: Any], props: [String: Any] = [:]) {
        routeParams = params
        routeProps = props
        guard isViewLoaded, !runtimeDisposed else { return }
        let context = jsContext
        let route = routeName ?? "screen"
        CraftNativeScriptThread.run(label: "params \(route)") {
            context.setObject(params as NSDictionary, forKeyedSubscript: "__stxNativeParams" as NSString)
            context.setObject(props as NSDictionary, forKeyedSubscript: "__stxNativeProps" as NSString)
        }
        send(type: "ROUTE_PARAMS", payload: ["params": params, "props": props])
    }

    private func disposeRuntime() {
        guard !runtimeDisposed else { return }
        runtimeDisposed = true
        frameDelivery.close()
        storageLifetime.close()
        pendingCapabilityDeadlines.values.forEach { $0.cancel() }
        pendingCapabilityDeadlines.removeAll()
        pendingCapabilityRequests.forEach { CraftNativeActions.cancel(requestToken: $0) }
        pendingCapabilityRequests.removeAll()
        if let owner = voiceRecordingOwner {
            voiceRecordingOwner = nil
            CraftVoiceRecording.shared.perform(method: "cancel", args: [owner]) { _ in }
        }
        frameWanted = false
        CraftNativeFrameClock.shared.cancel(self)
        disposeRenderedTree()
        let context = jsContext
        let route = routeName ?? "screen"
        let storageLifetime = self.storageLifetime
        CraftNativeScriptThread.run(label: "unmount \(route)") {
            storageLifetime.unmount { context.objectForKeyedSubscript("__stxNativeUnmount")?.call(withArguments: []) }
        }
        audio.close()
        sounds.close()
        streams.close()
        screenRequestCancellers.values.forEach { $0() }
        screenRequestCancellers.removeAll()
    }

    /// Runtime disposal happens before UIKit necessarily deallocates the
    /// controller. Release the rendered tree now so recycled rows, native
    /// delegates, media, and map callbacks cannot outlive their screen.
    private func disposeRenderedTree() {
        guard let root = renderedRoot else { return }
        forgetHandlers(root)
        rootStack.removeArrangedSubview(root.view)
        root.view.removeFromSuperview()
        renderedRoot = nil
        flatListRows.removeAll()
        flatListRecycled.removeAll()
        flatListOwners.removeAll()
        svgOwners.removeAll()
    }

    private var appliedTraitDefaults: String?

    private func refreshTraitDefaults() {
        // Tab navigation is not a theme change. Reapplying the entire tree
        // discards every measurement just as an interactive transition starts.
        let traits = "\(colorScheme):\(traitCollection.preferredContentSizeCategory.rawValue):\(UIAccessibility.isReduceTransparencyEnabled)"
        guard traits != appliedTraitDefaults else { return }
        appliedTraitDefaults = traits
        view.backgroundColor = screenBackgroundColor ?? config.resolvedBackgroundColor
        applyNavigationBarAppearance()
        if let document = mutationDocument.node("root") {
            renderCommitted(document)
        } else {
            rootStack.setNeedsLayout()
        }
        refreshTraitDefaults(in: renderedRoot)
    }

    private func refreshTraitDefaults(in node: RenderedNode?) {
        guard let node else { return }
        (node.view as? CraftNativeMapView)?.refreshThemeDefaults()
        (node.view as? CraftNativeFlatList)?.refreshThemeDefaults()
        node.children.forEach { refreshTraitDefaults(in: $0) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Containment, bar visibility and accessory insets can change after
        // rendering. Recheck once the scroll viewport has its actual frame.
        trackContentScrollView()
        positionModals()
        emitLayoutEvents()
        sendViewportIfChanged()
        scheduleKeyboardInsets()
    }

    /// The width the bundle last heard, so a layout pass at the same size says nothing.
    private var reportedViewportWidth: CGFloat = -1

    /// The screen's own width once laid out, else its window's: what a web
    /// page's media queries would measure.
    private func currentViewportWidth() -> CGFloat {
        let width = view.bounds.width > 0 ? view.bounds.width : (view.window ?? CraftPresenter.keyWindow())?.bounds.width ?? 0
        reportedViewportWidth = width
        return width
    }

    /// A rotation, iPad split view or a resized Stage Manager window: the
    /// bundle's width classes (`md:`, `lg:`) follow the screen's new width.
    private func sendViewportIfChanged() {
        let width = view.bounds.width
        guard width > 0, abs(width - reportedViewportWidth) >= 0.5 else { return }
        reportedViewportWidth = width
        send(type: "VIEWPORT", payload: ["width": Double(width), "height": Double(view.bounds.height)])
    }

    /// Modals cover the screen; their content starts below its bars (the
    /// status bar is all the safe area counts on a native screen, and a
    /// modal's first control sat under the navigation bar).
    private func positionModals() {
        let modals = view.subviews.compactMap { $0 as? CraftNativeModalView }
        guard !modals.isEmpty else { return }
        var insets = view.safeAreaInsets
        // The navigation bar floats over the screen without counting in its
        // safe area, and it is drawn above anything the screen adds.
        if let nav = navigationController, !nav.isNavigationBarHidden, nav.navigationBar.window != nil {
            let bar = nav.navigationBar.convert(nav.navigationBar.bounds, to: view)
            if bar.intersects(view.bounds) { insets.top = max(insets.top, bar.maxY) }
        }
        for modal in modals {
            guard !modal.blocksBackground else {
                if modal.frame != view.bounds { modal.frame = view.bounds }
                modal.contentInsets = insets
                continue
            }

            // Non-modal overlays are viewport children, not full-screen
            // scrims. Their absolute style uses the same full screenViewport
            // origin that View.measure returns. Safe-area-aware placement is
            // owned by the caller (for example, STX's anchor/clamp logic), so
            // an authored left/top is never shifted by an implicit inset.
            let viewport = view.bounds
            let style = modal.craftLayoutStyle
            let width = style.left != nil && style.right != nil
                ? max(0, viewport.width - (style.left ?? 0) - (style.right ?? 0))
                : style.width?.resolve(viewport.width)
                    ?? min(viewport.width, modal.contentStack.sizeThatFits(viewport.size).width)
            let height = style.top != nil && style.bottom != nil
                ? max(0, viewport.height - (style.top ?? 0) - (style.bottom ?? 0))
                : style.height?.resolve(viewport.height)
                    ?? min(viewport.height, modal.contentStack.sizeThatFits(viewport.size).height)
            let x = viewport.minX + (style.left ?? (style.right.map { viewport.width - $0 - width } ?? 0))
            let y = viewport.minY + (style.top ?? (style.bottom.map { viewport.height - $0 - height } ?? 0))
            let frame = CGRect(x: x, y: y, width: width, height: height)
            if modal.frame != frame { modal.frame = frame }
            // The frame already excludes the safe area; inset the content no
            // further or authored top/left coordinates would be shifted twice.
            modal.contentInsets = .zero
        }
    }

    /// A non-modal popup above a blocking modal must not leak its outside tap
    /// to the modal's scrim and dismiss the wrong layer.
    fileprivate func hasBlockingModalBelow(_ modal: CraftNativeModalView) -> Bool {
        guard let index = view.subviews.firstIndex(where: { $0 === modal }) else { return false }
        return view.subviews[..<index].contains { candidate in
            guard let other = candidate as? CraftNativeModalView else { return false }
            return other.blocksBackground && !other.isHidden && other.alpha > 0.01
        }
    }

    /// The native route's Back button dismisses the top presented modal before
    /// it pops the route, matching Android's activity back callback.
    @discardableResult
    func handleBackForModal() -> Bool {
        let modal = view.subviews.reversed().compactMap { $0 as? CraftNativeModalView }.first {
            ($0.isPresentedAsSheet || (!$0.isHidden && $0.alpha > 0.01)) && ($0.blocksBackground || $0.dismissOnOutsideTap)
        }
        guard let modal else { return false }
        let hasHandler = modal.onRequestClose != nil
        modal.requestClose(reason: "back")
        return hasHandler
    }

    private static func safeJavaScriptString(_ value: JSValue?) -> String? {
        guard let value, !value.isUndefined, !value.isNull, value.isString else { return nil }
        return value.toString()
    }

    /// What a screen's script starts with that only the main thread may read:
    /// the app's state, the appearance, initial visibility, what the device can do.
    private struct ScriptInputs {
        let capabilityJSON: String
        let appState: String
        let colorScheme: String
        let appearanceJSON: String
        let sessionTokenKey: String
        let focused: Bool?
        /// The screen's width in points, for the bundle's `sm:`/`md:`/`lg:` classes.
        let viewportWidth: Double
    }

    private func scriptInputs() -> ScriptInputs {
        let capabilities = CraftNativeActions.capabilities(config: config)
        let capabilityData = try? JSONSerialization.data(withJSONObject: capabilities)
        return ScriptInputs(
            capabilityJSON: capabilityData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]",
            appState: CraftNativeActions.currentAppState(),
            colorScheme: colorScheme,
            appearanceJSON: appearanceJSON(),
            sessionTokenKey: Self.jsonString(CraftSession.tokenKey(config)),
            focused: reportedVisible,
            viewportWidth: Double(currentViewportWidth())
        )
    }

    private func setupJavaScript(_ inputs: ScriptInputs) {
        if let routeName = routeName {
            jsContext.setObject(routeName, forKeyedSubscript: "__stxNativeRoute" as NSString)
        }
        jsContext.setObject(routeParams as NSDictionary, forKeyedSubscript: "__stxNativeParams" as NSString)
        jsContext.setObject(routeProps as NSDictionary, forKeyedSubscript: "__stxNativeProps" as NSString)
        // Hidden before its script ran: the SCREEN_FOCUS saying so reached no
        // callback, so the script reads it as it starts instead.
        if inputs.focused == false {
            jsContext.setObject(false, forKeyedSubscript: "__stxNativeFocused" as NSString)
        }
        jsContext.exceptionHandler = { [weak self] context, exception in
            // Never stringify an arbitrary JS object here. JavaScriptCore can
            // re-enter this handler while coercing an exception whose
            // `toString` is broken, turning a page error into a native crash.
            let message = Self.safeJavaScriptString(exception?.objectForKeyedSubscript("message"))
                ?? Self.safeJavaScriptString(exception)
                ?? "unknown"
            let stack = Self.safeJavaScriptString(exception?.objectForKeyedSubscript("stack")) ?? ""
            let screen = self?.screenName(in: context) ?? "screen"
            CraftNativeConsole.write("error", category: screen, message: stack.isEmpty || stack == "undefined" ? "Uncaught \(message)" : "Uncaught \(message)\n\(stack)")
            let name = Self.safeJavaScriptString(exception?.objectForKeyedSubscript("name"))
            CraftNativeScriptThread.toMain { [weak self] in
                // To the app's crash reporter too (bughq, when configured):
                // an uncaught error in a shipped screen is otherwise only in
                // a log nobody reads on someone else's phone.
                CraftCrashReporter.shared.captureJavaScript(
                    name: name,
                    message: message,
                    stack: stack,
                    route: screen,
                    isAppScript: self?.isAppScript ?? false
                )
                self?.hybridFailed(message)
            }
        }
        let postMessage: @convention(block) (String) -> Void = { [weak self] json in
            self?.receive(json)
        }
        jsContext.setObject(postMessage, forKeyedSubscript: "craftNativePostMessage" as NSString)
        // A language's messages for an area, as JSON text, the first time the
        // screen looks inside them (stx's `messages`): a screen parses only
        // the language it is shown in, and only the areas it uses. Called
        // from the screen's script, on its thread, and answered there.
        let readMessages: @convention(block) (String, String) -> Any = { language, area in
            CraftNativeBundle.messages(language: language, area: area) ?? NSNull()
        }
        jsContext.setObject(readMessages, forKeyedSubscript: "__stxNativeReadMessages" as NSString)
        // JavaScriptCore has no timers of its own. The callbacks stay in
        // JavaScript; native only owns the main-queue deadline, so route
        // teardown cancels every pending timer with the controller.
        let timers = self.timers
        let context = jsContext
        let scheduleTimer: @convention(block) (Int, Double) -> Void = { id, delay in
            let work = DispatchWorkItem { [weak context] in
                guard timers.pending.removeValue(forKey: id) != nil else { return }
                context?.objectForKeyedSubscript("__craftNativeFireTimer")?.call(withArguments: [id])
            }
            timers.pending[id] = work
            let milliseconds = delay.isFinite ? Int(min(max(delay, 0), 2_147_483_647)) : 0
            // Fired where the script runs.
            let queue = CraftNativeScriptThread.isBackground ? CraftNativeScriptThread.queue : .main
            queue.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: work)
        }
        let cancelTimer: @convention(block) (Int) -> Void = { id in
            timers.pending.removeValue(forKey: id)?.cancel()
        }
        jsContext.setObject(scheduleTimer, forKeyedSubscript: "craftNativeScheduleTimer" as NSString)
        jsContext.setObject(cancelTimer, forKeyedSubscript: "craftNativeCancelTimer" as NSString)
        // The next display frame, from the script's thread; the frame itself
        // comes back there as `__craftNativeFireFrame`.
        let requestFrame: @convention(block) () -> Void = { [weak self] in
            CraftNativeScriptThread.toMain { self?.requestFrame() }
        }
        jsContext.setObject(requestFrame, forKeyedSubscript: "craftNativeRequestFrame" as NSString)
        let capabilityJSON = inputs.capabilityJSON
        // The app's site and build, as JSON strings: the site an all-native
        // app's paths and links belong to (`devServerURL`), and the version a
        // request or a crash report names.
        let info = Bundle.main.infoDictionary
        let appURL = Self.jsonString(config.devServerURL ?? "")
        let appVersion = Self.jsonString(info?["CFBundleShortVersionString"] as? String ?? "")
        let appBuild = Self.jsonString(info?["CFBundleVersion"] as? String ?? "")
        let sessionTokenKey = inputs.sessionTokenKey
        jsContext.evaluateScript("""
            // JavaScriptCore has no DOM window, but browser-safe SDK bridges
            // address the host through `window.craft`. Keep native screens
            // compatible without pretending a document exists.
            if (typeof globalThis.window === "undefined") { globalThis.window = globalThis; }
            globalThis.__stxNativeCallback = null;
            globalThis.__stxNativeBridge = {
                platform: "ios",
                mutationProtocolVersion: 1,
                capabilityProtocolVersion: \(craftNativeCapabilityProtocolVersion),
                capabilityTimeoutMs: \(craftNativeCapabilityTimeoutMilliseconds),
                capabilities: \(capabilityJSON),
                initialAppState: "\(inputs.appState)",
                colorScheme: "\(inputs.colorScheme)",
                viewportWidth: \(inputs.viewportWidth),
                appearance: \(inputs.appearanceJSON),
                appURL: \(appURL),
                appVersion: \(appVersion),
                appBuild: \(appBuild),
                sessionTokenKey: \(sessionTokenKey),
                postMessage: function(message) { craftNativePostMessage(message); },
                onMessage: function(callback) { globalThis.__stxNativeCallback = callback; }
            };
        """)
        jsContext.evaluateScript(Self.nativeWebAPICompatibilityPrelude)
        installHostAPIs()
        jsContext.evaluateScript("""
            // requestAnimationFrame on the display's frames (CraftNativeFrameClock),
            // at its own rate, 120 a second on ProMotion: a timer guessing at 60
            // would cap every animation a screen draws itself. One request covers
            // every callback for the frame; a callback that throws does not stop
            // the others, and is reported after them.
            if (typeof globalThis.requestAnimationFrame !== 'function') {
                (function() {
                    var frames = [];
                    var callbacks = new Map();
                    var nextFrame = 0;
                    globalThis.requestAnimationFrame = function(callback) {
                        if (typeof callback !== 'function') return 0;
                        var id = ++nextFrame;
                        callbacks.set(id, callback);
                        frames.push(id);
                        if (frames.length === 1) craftNativeRequestFrame();
                        return id;
                    };
                    globalThis.cancelAnimationFrame = function(id) {
                        callbacks.delete(id);
                    };
                    globalThis.__craftNativeFireFrame = function(now) {
                        var due = frames;
                        frames = [];
                        var failures = [];
                        for (var i = 0; i < due.length; i++) {
                            var callback = callbacks.get(due[i]);
                            callbacks.delete(due[i]);
                            if (!callback) continue;
                            try { callback(now); } catch (error) { failures.push(error); }
                        }
                        failures.forEach(function(error) { globalThis.setTimeout(function() { throw error; }, 0); });
                    };
                })();
            }
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

    /// JavaScriptCore has the language core but not browser URL/encoding
    /// globals. Keep their absence actionable for shared modules instead of
    /// surfacing an opaque ReferenceError from an unrelated load path. Full
    /// implementations belong to the shared STX runtime.
    private static let nativeWebAPICompatibilityPrelude = """
        (function() {
          function unavailable(name, hint) {
            var failure = function() {
              throw new ReferenceError(name + ' is not available on a native screen — ' + hint);
            };
            failure.prototype.constructor = failure;
            return failure;
          }
          if (typeof globalThis.URL === 'undefined') globalThis.URL = unavailable('URL', 'use an absolute URL or build the path with encodeURIComponent');
          if (typeof globalThis.URLSearchParams === 'undefined') globalThis.URLSearchParams = unavailable('URLSearchParams', 'build query strings with encodeURIComponent');
          if (typeof globalThis.TextEncoder === 'undefined') globalThis.TextEncoder = unavailable('TextEncoder', 'use a native-supported encoding helper');
        })();
    """

    /// `value` as a JavaScript string literal (JSON), quotes and all.
    static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8), array.count >= 2 else { return "\"\"" }
        return String(array.dropFirst().dropLast())
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

    private func sendAppearance() {
        let style: UIUserInterfaceStyle = colorScheme == "dark" ? .dark : .light
        send(type: "APPEARANCE", payload: CraftPageAppearance.snapshot(style: style))
    }

    private func appearanceJSON() -> String {
        let style: UIUserInterfaceStyle = colorScheme == "dark" ? .dark : .light
        guard let data = try? JSONSerialization.data(withJSONObject: CraftPageAppearance.snapshot(style: style)),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// The screen's name as its script knows it: the route the host opened,
    /// else the one a route bundle selected for itself.
    private func screenName(in context: JSContext? = nil) -> String {
        if let routeName, !routeName.isEmpty { return routeName }
        // The script's own context is read only where the script runs.
        if context == nil, CraftNativeScriptThread.isBackground { return navigationItem.title ?? "screen" }
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
    ///   `clear(keep?)` (a promise) deletes every snapshot but the names in
    ///   `keep`, as a sign-out does; each removal is a `SNAPSHOT_CHANGED`
    ///   for every screen.
    /// - `craft.secureStorage.getSync(key)`: the Keychain item the web page's
    ///   `craft.secureStorage.set` wrote.
    /// - `craft.navigation.setOptions({ title, largeTitle, hidden, backTitle,
    ///   tabBarHidden, swipeBack, contentSwipeBack, tabSwipeEnabled,
    ///   backgroundColor, navigationBarSolid, rightButtons, tabAccessory })`;
    ///   a right button's tap is the event `navButton`.
    ///
    /// A runtime that assigns `craft.storage` (or the others) afterwards keeps
    /// these: each namespace is a property whose setter adds them back to the
    /// object it is given.
    private func installHostAPIs() {
        let log: @convention(block) (String, String, String) -> Void = { level, category, message in
            CraftNativeConsole.write(level, category: category, message: message)
        }
        let storageLifetime = self.storageLifetime
        let storageGet: @convention(block) (String) -> String? = { key in
            storageLifetime.access(closedValue: nil) {
                do { return try CraftNativeActions.storageJSON(forKey: key) }
                catch {
                    if let context = JSContext.current() {
                        context.exception = JSValue(newErrorFromMessage: "STORAGE_ERROR: Unable to read stored value", in: context)
                    }
                    return nil
                }
            }
        }
        let storageSet: @convention(block) (String, JSValue) -> Bool = { key, value in
            storageLifetime.access(closedValue: false) {
                CraftNativeActions.setStorageJSON(value.isNull || value.isUndefined ? nil : value.toString(), forKey: key)
            }
        }
        let snapshotGet: @convention(block) (String) -> String? = { name in
            storageLifetime.access(closedValue: nil) { CraftSnapshots.read(name) }
        }
        // JavaScriptCore retains these outer host blocks. A weak capture only
        // on the nested completion still makes the host block retain self,
        // forming controller -> JSContext -> host block -> controller.
        let snapshotSet: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] name, value, done in
            let json = value.isNull || value.isUndefined ? nil : value.toString()
            // Refuse before queueing disk work. Rejecting only its completion
            // still lets a closed screen overwrite another screen's checkpoint.
            storageLifetime.access(closedValue: ()) {
                CraftSnapshots.write(name, json: json) { [weak self] ok in
                    CraftNativeScriptThread.run {
                        // A writer can finish after UIKit has disposed this
                        // screen. Resolve the pending promise as a cancellation,
                        // never as a successful write into a dead runtime.
                        done.call(withArguments: [self?.runtimeDisposed != false ? false : ok])
                    }
                }
            }
        }
        let snapshotClear: @convention(block) (JSValue, JSValue) -> Void = { [weak self] keep, done in
            let names = (keep.isUndefined || keep.isNull ? [] : (keep.toArray() ?? [])).compactMap { $0 as? String }
            storageLifetime.access(closedValue: ()) {
                CraftSnapshots.clear(keeping: Set(names)) { [weak self] ok in
                    CraftNativeScriptThread.run {
                        done.call(withArguments: [self?.runtimeDisposed != false ? false : ok])
                    }
                }
            }
        }
        let config = self.config
        let secureGet: @convention(block) (String) -> String? = { key in
            config.enableSecureStorage ? CraftNativeActions.webSecureValue(forKey: key) : nil
        }
        let setAppearance: @convention(block) (String) -> Bool = { value in
            if Thread.isMainThread { return CraftInterfaceStyleController.set(value) }
            var accepted = false
            DispatchQueue.main.sync { accepted = CraftInterfaceStyleController.set(value) }
            return accepted
        }
        let getAppearance: @convention(block) () -> String = {
            if Thread.isMainThread { return CraftInterfaceStyleController.currentName() }
            var value = "light"
            DispatchQueue.main.sync { value = CraftInterfaceStyleController.currentName() }
            return value
        }
        let setOptions: @convention(block) (String) -> Void = { [weak self] json in
            guard let data = json.data(using: .utf8),
                  let options = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            CraftNativeScriptThread.toMain { self?.applyNavigationOptions(options) }
        }
        jsContext.setObject(log, forKeyedSubscript: "craftNativeLog" as NSString)
        jsContext.setObject(storageGet, forKeyedSubscript: "craftNativeStorageGet" as NSString)
        jsContext.setObject(storageSet, forKeyedSubscript: "craftNativeStorageSet" as NSString)
        jsContext.setObject(snapshotGet, forKeyedSubscript: "craftNativeSnapshotGet" as NSString)
        jsContext.setObject(snapshotSet, forKeyedSubscript: "craftNativeSnapshotSet" as NSString)
        jsContext.setObject(snapshotClear, forKeyedSubscript: "craftNativeSnapshotClear" as NSString)
        jsContext.setObject(secureGet, forKeyedSubscript: "craftNativeSecureGet" as NSString)
        jsContext.setObject(setAppearance, forKeyedSubscript: "craftNativeSetAppearance" as NSString)
        jsContext.setObject(getAppearance, forKeyedSubscript: "craftNativeGetAppearance" as NSString)
        jsContext.setObject(setOptions, forKeyedSubscript: "craftNativeSetOptions" as NSString)
        // Older native bundles call the page-shaped `craft.dialog` API
        // directly. Keep that API backed by the same capability protocol as
        // current stx bundles, rather than letting their DOM fallback draw a
        // fake sheet in a JavaScriptCore screen.
        jsContext.evaluateScript("""
            (function() {
                var bridge = globalThis.__stxNativeBridge;
                if (!bridge || typeof bridge.postMessage !== 'function') return;
                var listeners = [];
                var runtimeCallback = null;
                bridge.onMessage = function(callback) {
                    runtimeCallback = typeof callback === 'function' ? callback : null;
                };
                bridge.addMessageListener = function(callback) {
                    if (typeof callback !== 'function') return function() {};
                    listeners.push(callback);
                    return function() {
                        var index = listeners.indexOf(callback);
                        if (index >= 0) listeners.splice(index, 1);
                    };
                };
                globalThis.__stxNativeCallback = function(raw) {
                    listeners.slice().forEach(function(callback) {
                        try { callback(raw); } catch (error) {}
                    });
                    if (runtimeCallback) runtimeCallback(raw);
                };
                var nextRequest = 0;
                function request(module, method, args, untimed) {
                    return new Promise(function(resolve, reject) {
                        var id = 'craft-host-' + (++nextRequest);
                        var remove = bridge.addMessageListener(function(raw) {
                            var message;
                            try { message = typeof raw === 'string' ? JSON.parse(raw) : raw; } catch (error) { return; }
                            var payload = message && message.payload;
                            if (!payload || payload.requestId !== id) return;
                            if (message.type !== 'API_ERROR' && message.type !== 'API_RESPONSE') return;
                            remove();
                            if (message.type === 'API_ERROR') {
                                var failure = new Error(payload.message || 'Native capability failed');
                                failure.code = payload.code || 'NATIVE_CALL_FAILED';
                                reject(failure);
                            } else if (message.type === 'API_RESPONSE') {
                                resolve(payload.data === undefined ? null : payload.data);
                            }
                        });
                        try { bridge.postMessage(JSON.stringify({
                            type: 'API_REQUEST',
                            id: id,
                            payload: {
                                version: bridge.capabilityProtocolVersion || 1,
                                module: module,
                                method: method,
                                args: args,
                                untimed: untimed === true
                            }
                        })); } catch (error) { remove(); reject(error); }
                    });
                }
                // Native capability ownership wins over any browser-shaped
                // dialog object the bundle installed before the bridge ran.
                // Leaving the old guard here sends actionSheet through the
                // DOM fallback even though this screen can present UIKit.
                function installNativeDialog() {
                    var craft = globalThis.craft = globalThis.craft || {};
                    if (Array.isArray(bridge.capabilities) && bridge.capabilities.indexOf('dialog') >= 0) {
                        craft.dialog = {
                            alert: function(options) { return request('Dialog', 'alert', [options || {}], true).then(function() {}); },
                            confirm: function(options) { return request('Dialog', 'confirm', [options || {}], true).then(Boolean); },
                            actionSheet: function(options) { return request('Dialog', 'actionSheet', [options || {}], true).then(function(id) { return typeof id === 'string' ? id : null; }); }
                        };
                    }
                    if (Array.isArray(bridge.capabilities) && bridge.capabilities.indexOf('health') >= 0) {
                        var health = craft.health || {};
                        var discardWorkout = function() { return request('Health', 'discardWorkout', []); };
                        health.discardWorkout = discardWorkout;
                        Object.defineProperty(craft, 'health', {
                            configurable: true, enumerable: true,
                            get: function() { return health; },
                            set: function(value) {
                                if (!value || typeof value !== 'object') return;
                                value.discardWorkout = discardWorkout;
                                health = value;
                            }
                        });
                    }
                    if (Array.isArray(bridge.capabilities) && bridge.capabilities.indexOf('shortcuts') >= 0) {
                        var shortcuts = {
                            set: function(items) { return request('Shortcuts', 'set', [items]); },
                            clear: function() { return request('Shortcuts', 'clear', []); }
                        };
                        // An older STX bundle may install a browser-only
                        // namespace. Preserve extras, but keep set/clear native.
                        Object.defineProperty(craft, 'shortcuts', {
                            configurable: true, enumerable: true,
                            get: function() { return shortcuts; },
                            set: function(value) {
                                if (!value || typeof value !== 'object') return;
                                value.set = shortcuts.set;
                                value.clear = shortcuts.clear;
                                shortcuts = value;
                            }
                        });
                    }
                }
                globalThis.__craftInstallNativeDialog = installNativeDialog;
                installNativeDialog();
            })();
        """)
        // `AudioContext` and the rest of Web Audio, rendered natively.
        audio.install(in: jsContext)
        // `crypto` for code shared with the page (a sign-in's nonce and its
        // SHA-256): JavaScriptCore has none. Random bytes from the system's
        // generator, digests from CryptoKit, both as hex.
        let randomBytes: @convention(block) (Int) -> String? = { count in
            guard count >= 0, count <= 65_536 else { return nil }
            var bytes = [UInt8](repeating: 0, count: count)
            guard count == 0 || SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return nil }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        let digest: @convention(block) (String, String) -> String? = { algorithm, hex in
            var data = Data(capacity: hex.count / 2)
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
                guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
                data.append(byte)
                index = next
            }
            let bytes: [UInt8]
            switch algorithm.uppercased() {
            case "SHA-1": bytes = Array(Insecure.SHA1.hash(data: data))
            case "SHA-256": bytes = Array(SHA256.hash(data: data))
            case "SHA-384": bytes = Array(SHA384.hash(data: data))
            case "SHA-512": bytes = Array(SHA512.hash(data: data))
            default: return nil
            }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        jsContext.setObject(randomBytes, forKeyedSubscript: "craftNativeRandomBytes" as NSString)
        jsContext.setObject(digest, forKeyedSubscript: "craftNativeDigest" as NSString)
        jsContext.evaluateScript("""
            (function() {
                var cryptoObject = globalThis.crypto || {};
                function hexToBytes(hex) {
                    var bytes = new Uint8Array(hex.length / 2);
                    for (var i = 0; i < bytes.length; i++) bytes[i] = parseInt(hex.substr(i * 2, 2), 16);
                    return bytes;
                }
                function toHex(bytes) {
                    var out = '';
                    for (var i = 0; i < bytes.length; i++) out += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
                    return out;
                }
                function viewOf(data) {
                    if (data instanceof ArrayBuffer) return new Uint8Array(data);
                    if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
                    throw new TypeError('crypto.subtle.digest needs an ArrayBuffer or a typed array');
                }
                if (typeof cryptoObject.getRandomValues !== 'function') {
                    cryptoObject.getRandomValues = function(array) {
                        if (!ArrayBuffer.isView(array)) throw new TypeError('crypto.getRandomValues needs a typed array');
                        var hex = craftNativeRandomBytes(array.byteLength);
                        if (hex == null) throw new Error('No random bytes from the system');
                        new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(hexToBytes(hex));
                        return array;
                    };
                }
                if (typeof cryptoObject.randomUUID !== 'function') {
                    cryptoObject.randomUUID = function() {
                        var b = cryptoObject.getRandomValues(new Uint8Array(16));
                        b[6] = (b[6] & 0x0f) | 0x40;
                        b[8] = (b[8] & 0x3f) | 0x80;
                        var h = toHex(b);
                        return h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' + h.slice(16, 20) + '-' + h.slice(20);
                    };
                }
                if (!cryptoObject.subtle || typeof cryptoObject.subtle.digest !== 'function') {
                    cryptoObject.subtle = Object.assign(cryptoObject.subtle || {}, {
                        digest: function(algorithm, data) {
                            try {
                                var name = typeof algorithm === 'string' ? algorithm : algorithm && algorithm.name;
                                var out = craftNativeDigest(String(name || ''), toHex(viewOf(data)));
                                if (out == null) return Promise.reject(new Error('Unsupported digest: ' + name));
                                return Promise.resolve(hexToBytes(out).buffer);
                            } catch (error) {
                                return Promise.reject(error);
                            }
                        }
                    });
                }
                globalThis.crypto = cryptoObject;
            })();
        """)
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
                    },
                    // Every snapshot but the names in `keep` (a sign-out).
                    clear: function(keep) {
                        var names = Array.isArray(keep) ? keep.map(String) : [];
                        return new Promise(function(resolve, reject) {
                            craftNativeSnapshotClear(names, function(ok) {
                                if (ok) resolve();
                                else reject(new Error('craft.snapshots.clear could not remove every snapshot'));
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
                keep('app', {
                    setAppearance: function(value) {
                        value = String(value);
                        if (value !== 'light' && value !== 'dark' && value !== 'system') {
                            return Promise.reject(new TypeError('craft.app.setAppearance needs light, dark or system'));
                        }
                        if (!craftNativeSetAppearance(value)) {
                            return Promise.reject(new Error('craft.app.setAppearance was rejected'));
                        }
                        return Promise.resolve();
                    },
                    getAppearance: function() { return Promise.resolve(craftNativeGetAppearance()); }
                });
                // The signed-in account (CraftSession): the token under
                // `sessionTokenKey`, and each change of it, which the host
                // reports through `__craftSessionChanged` after the Keychain
                // holds it, beside the `SESSION_CHANGED` bridge message.
                var sessionListeners = [];
                var sessionKey = globalThis.__stxNativeBridge && __stxNativeBridge.sessionTokenKey || 'auth.token';
                function sessionToken() {
                    var value = craftNativeSecureGet(String(sessionKey));
                    return typeof value === 'string' && value !== '' ? value : null;
                }
                globalThis.__craftSessionChanged = function(token, previous) {
                    sessionListeners.slice().forEach(function(callback) {
                        try { callback(token, previous); } catch (error) { console.error('[session] ' + (error && error.stack || error)); }
                    });
                };
                keep('session', {
                    key: sessionKey,
                    token: sessionToken,
                    onChange: function(callback) {
                        if (typeof callback !== 'function') throw new TypeError('craft.session.onChange needs a function');
                        sessionListeners.push(callback);
                        return function() {
                            var index = sessionListeners.indexOf(callback);
                            if (index >= 0) sessionListeners.splice(index, 1);
                        };
                    }
                });
                keep('navigation', {
                    setOptions: function(options) { craftNativeSetOptions(JSON.stringify(options || {})); }
                });
                // shortcuts already has a capability-owned accessor above.
                // Do not wrap it in keep(): its adopt setter would let a
                // bundle replace native set/clear during bootstrap.
            })();
        """)
    }

    /// Runs where the script runs (CraftNativeScriptThread).
    private func loadBundle() {
        guard let bundle = CraftNativeBundle.source(for: routeName) else {
            CraftNativeScriptThread.toMain { [weak self] in
                self?.showError("Missing dist/native-screen.js. Compile a .stx screen with `stx native compile` first.")
            }
            return
        }
        if let runtime = CraftNativeBundle.runtime(for: bundle.url) {
            jsContext.evaluateScript(runtime.source, withSourceURL: runtime.url)
        }
        jsContext.evaluateScript(bundle.source, withSourceURL: bundle.url)
        // The STX runtime may install its browser-shaped craft.dialog after
        // the host prelude. Re-assert the native capability once the bundle
        // has finished so native screens cannot fall through to a DOM sheet.
        jsContext.evaluateScript("if (typeof globalThis.__craftInstallNativeDialog === 'function') globalThis.__craftInstallNativeDialog();")
        // A bundle that names no route leaves `__stxNativeRoute` undefined;
        // its title is the app's, not the word "undefined". A title the
        // script set with `navigation.setOptions` wins over both.
        guard routeName == nil,
              let selected = jsContext.objectForKeyedSubscript("__stxNativeRoute"), selected.isString,
              let name = selected.toString(), !name.isEmpty else { return }
        CraftNativeScriptThread.toMain { [weak self] in
            guard let self, !self.titleFromOptions else { return }
            self.navigationItem.title = name
        }
    }

    // MARK: Navigation bar options

    private var titleFromOptions = false
    private var rootTopToSafeArea: NSLayoutConstraint?
    private var rootTopToView: NSLayoutConstraint?
    private var rootBottomToSafeArea: NSLayoutConstraint?
    private var rootBottomToView: NSLayoutConstraint?
    private var rootLeadingToSafeArea: NSLayoutConstraint?
    private var rootLeadingToView: NSLayoutConstraint?
    private var rootTrailingToSafeArea: NSLayoutConstraint?
    private var rootTrailingToView: NSLayoutConstraint?
    private var rootIsSafeAreaView = false
    private(set) var navigationBarHidden: Bool?
    /// A native `<StatusBar>` node overrides the app default for this screen.
    private var statusBarStyleOverride: UIStatusBarStyle?
    private var statusBarHiddenOverride: Bool?
    /// The app's tab bar away while this screen shows (`tabBarHidden`).
    private var tabBarHidden = false
    private var tabAccessory: [String: Any]?
    /// Whether the screen has said anything about the accessory yet
    /// (`tabAccessory`, null included): until it has, the bar keeps showing
    /// the one it had (CraftChrome.releaseTabAccessory).
    private var tabAccessoryDeclared = false
    /// Whether a back-swipe may leave this screen at all, the edge's
    /// included (`swipeBack: false`): a screen that steps through its own
    /// pages with a Back of its own (a first-run tour's questions) would
    /// otherwise lose its place to a stray swipe.
    private(set) var swipeBack = true
    /// Whether iOS 26's content-wide back-swipe may begin on this screen.
    /// Setting `contentSwipeBack: false` leaves the 32-point edge gesture.
    private(set) var contentSwipeBack = true
    /// Whether the shell's horizontal tab switch gesture may begin here.
    /// This is separate so a screen can keep navigation back while owning its
    /// own horizontal pager or chart gesture.
    private(set) var tabSwipeEnabled = true
    private var prefersLargeTitle: Bool?
    /// Whether the screen has been on screen. Until then, a bar its script
    /// asks for is simply there in its first frame: a tab opened for the
    /// first time (HQ's Me) mounts in the window, and its bar and large title
    /// slid in from the side as the screen appeared.
    private var hasAppeared = false
    /// A bar shown or hidden after the screen has appeared animates; before,
    /// it is in place from the start.
    var animatesNavigationBarChanges: Bool { hasAppeared && view.window != nil }
    /// Whether this screen opts into an opaque navigation bar filled with its
    /// own background colour. The default keeps UIKit's material appearance.
    private var navigationBarSolid = false
    /// The screen's own colour (`backgroundColor`), under the status bar and
    /// the home indicator too, where its content never reaches: a black
    /// full-screen timer is black edge to edge. nil is the app's.
    private var screenBackgroundColor: UIColor?

    override var preferredStatusBarStyle: UIStatusBarStyle {
        statusBarStyleOverride ?? .default
    }

    override var prefersStatusBarHidden: Bool {
        statusBarHiddenOverride ?? false
    }

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
        if let tab = options["tabItem"] as? [String: Any] {
            CraftChrome.shared.updateTab(tab)
        }
        // The app script has no screen, so no bar and no tab bar to change.
        guard !isAppScript else { return }
        // Prepared tabs have a window and a top controller too. Keep their
        // options, but only the focused screen may change the shared chrome.
        if options.keys.contains("tabAccessory") {
            tabAccessory = options["tabAccessory"] as? [String: Any]
            tabAccessoryDeclared = true
            if navigationController?.topViewController === self, isShownOnScreen {
                CraftChrome.shared.updateTabAccessory(tabAccessory, owner: self)
            }
        }
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
        if let hidden = options["tabBarHidden"] as? Bool {
            tabBarHidden = hidden
            if navigationController?.topViewController === self, isShownOnScreen {
                CraftChrome.shared.setHiddenByScreen(hidden)
            }
        }
        if let swipeBack = options["swipeBack"] as? Bool {
            self.swipeBack = swipeBack
        }
        if let contentSwipeBack = options["contentSwipeBack"] as? Bool {
            self.contentSwipeBack = contentSwipeBack
        }
        if let tabSwipeEnabled = options["tabSwipeEnabled"] as? Bool {
            self.tabSwipeEnabled = tabSwipeEnabled
        }
        if options.keys.contains("backgroundColor") {
            screenBackgroundColor = color(options["backgroundColor"])
            view.backgroundColor = screenBackgroundColor ?? config.resolvedBackgroundColor
        }
        if let solid = options["navigationBarSolid"] as? Bool {
            navigationBarSolid = solid
        }
        if let hidden = options["hidden"] as? Bool {
            navigationBarHidden = hidden
            if navigationController?.topViewController === self {
                navigationController?.setNavigationBarHidden(hidden, animated: animatesNavigationBarChanges)
            }
        }
        if options.keys.contains("leftButtons") {
            let buttons = (options["leftButtons"] as? [[String: Any]]) ?? []
            navigationItem.leftItemsSupplementBackButton = true
            navigationItem.leftBarButtonItems = buttons.compactMap(navigationButton)
        }
        if options.keys.contains("rightButtons") {
            let buttons = (options["rightButtons"] as? [[String: Any]]) ?? []
            navigationItem.rightBarButtonItems = buttons.compactMap(navigationButton).reversed()
        }
        if options.keys.contains("backgroundColor") || options.keys.contains("navigationBarSolid") {
            applyNavigationBarAppearance()
            trackContentScrollView()
        }
        // Asked for after the bar was hidden for a bare root screen.
        if navigationBarHidden == nil, wantsNavigationBar, navigationController?.topViewController === self,
           navigationController?.isNavigationBarHidden == true {
            navigationController?.setNavigationBarHidden(false, animated: animatesNavigationBarChanges)
        }
    }

    /// Applies the screen's optional opaque bar without changing the default
    /// UIKit material when the screen did not opt in.
    private func applyNavigationBarAppearance() {
        guard navigationBarSolid else {
            navigationItem.standardAppearance = nil
            navigationItem.scrollEdgeAppearance = nil
            navigationItem.compactAppearance = nil
            navigationItem.compactScrollEdgeAppearance = nil
            return
        }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = screenBackgroundColor ?? config.resolvedBackgroundColor
        appearance.shadowColor = .clear
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
        navigationItem.compactScrollEdgeAppearance = appearance
    }

    private func applyStatusBar(_ props: [String: Any]) {
        let style: UIStatusBarStyle?
        switch (props["barStyle"] as? String)?.lowercased() {
        case "light-content", "light": style = .lightContent
        case "dark-content", "dark": style = .darkContent
        case "default": style = .default
        default: style = nil
        }
        let hidden = props["hidden"] as? Bool
        if statusBarStyleOverride != style || statusBarHiddenOverride != hidden {
            statusBarStyleOverride = style
            statusBarHiddenOverride = hidden
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    /// A bar button from `{ id, symbol | title }`. Its tap is the event
    /// `navButton` with `{ id }`.
    private func navigationButton(_ spec: [String: Any]) -> UIBarButtonItem? {
        guard let id = spec["id"] as? String, !id.isEmpty else { return nil }
        let action = UIAction { [weak self] _ in
            self?.send(type: "EVENT", payload: ["handlerName": "navButton", "nativeEvent": ["id": id]])
        }
        if spec["variant"] as? String == "accent" || spec["variant"] as? String == "account" {
            return accountNavigationButton(spec, action: action)
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
        if spec["variant"] as? String == "neutral" { item.tintColor = .label }
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

    /// Shared account/chat controls: the same 44-point target, independent
    /// circular surface and unread indicator on every native screen.
    private func accountNavigationButton(_ spec: [String: Any], action: UIAction) -> UIBarButtonItem {
        let button = UIButton(type: .custom)
        button.addAction(action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 44), button.heightAnchor.constraint(equalToConstant: 44)])
        // Floating, as the tab bar floats: a round piece of glass on iOS 26
        // (the bar's own material), the thin material with the tab bar's
        // hairline and shadow before it. The content scrolls on under it, and
        // it follows light, dark and Increase Contrast by itself.
        let surface = Self.floatingSurface(diameter: 44)
        button.addSubview(surface)
        // Pinned to the button rather than resized with it: the button starts
        // at zero size, so a 44-point surface that grew with its superview
        // came out 88 points, a rounded card twice the button's size that
        // spilled off the bar's edge and covered its neighbour.
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            surface.topAnchor.constraint(equalTo: button.topAnchor),
            surface.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        // Glass lifts itself off the content; the material needs the tab
        // bar's shadow to.
        if surface.effect is UIBlurEffect {
            button.layer.shadowColor = UIColor.black.cgColor
            button.layer.shadowOpacity = 0.12
            button.layer.shadowRadius = 8
            button.layer.shadowOffset = CGSize(width: 0, height: 3)
            button.layer.shadowPath = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 44, height: 44)).cgPath
        }
        button.tintColor = .systemBlue
        button.setTitleColor(button.tintColor, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        if let title = spec["title"] as? String, !title.isEmpty { button.setTitle(title, for: .normal) }
        else if let symbol = spec["symbol"] as? String { button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)), for: .normal) }
        button.accessibilityIdentifier = spec["id"] as? String
        button.accessibilityLabel = spec["accessibilityLabel"] as? String
        if let value = craftNativeNumber(spec["badge"]), value.intValue > 0 {
            let dot = spec["badgeStyle"] as? String == "dot"
            let size: CGFloat = dot ? 9 : 18
            // The fill is a tinted symbol, not a background colour: on iOS 26
            // a bar item's custom view keeps its tint but drew a plain
            // backgroundColor white, so the red unread dot came out white
            // (invisible in light mode) and the count lost its blue.
            let fill = UIImageView(image: UIImage(systemName: "circle.fill"))
            fill.tintColor = dot ? .systemRed : .systemBlue
            fill.contentMode = .scaleToFill
            fill.frame = CGRect(x: 44 - size, y: 0, width: size, height: size)
            fill.isAccessibilityElement = false
            button.addSubview(fill)
            if !dot {
                let count = UILabel(frame: fill.frame)
                count.text = value.intValue > 99 ? "99+" : String(value.intValue)
                count.font = .systemFont(ofSize: 10, weight: .bold)
                count.textColor = .white
                count.textAlignment = .center
                count.adjustsFontSizeToFitWidth = true
                count.isAccessibilityElement = false
                button.addSubview(count)
            }
            button.accessibilityValue = "\(value.intValue) unread"
        }
        if let source = spec["image"] as? String, let url = URL(string: source), url.scheme == "https" {
            loadBarImage(url) { [weak button] image in
                guard let button, let image else { return }
                let size = CGSize(width: 36, height: 36)
                let round = UIGraphicsImageRenderer(size: size).image { _ in
                    UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).addClip()
                    let scale = max(size.width / image.size.width, size.height / image.size.height)
                    let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
                }
                button.setTitle(nil, for: .normal)
                button.setImage(round.withRenderingMode(.alwaysOriginal), for: .normal)
                if let surface = button.subviews.first(where: { $0 is UIVisualEffectView }) { button.sendSubviewToBack(surface) }
            }
        }
        // Under the symbol, the initials, the picture and the badge.
        if let surface = button.subviews.first(where: { $0 is UIVisualEffectView }) { button.sendSubviewToBack(surface) }
        let item = UIBarButtonItem(customView: button)
        // iOS 26 groups adjacent bar items on one glass platter and tints
        // their custom views with it: the two 44-point circles came out as
        // solid accent ovals inside a capsule, unlike the web screens' bar.
        // The button draws its own surface, so it opts out of the platter.
        // Guarded by compiler too, for the older SDKs in the release matrix.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { item.hidesSharedBackground = true; item.sharesBackground = false }
        #endif
        return item
    }

    /// The round surface under a bar button: glass on iOS 26, the tab bar's
    /// thin material and hairline before it. It takes no touches.
    private static func floatingSurface(diameter: CGFloat) -> UIVisualEffectView {
        let effect: UIVisualEffect
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { effect = UIGlassEffect() } else { effect = UIBlurEffect(style: .systemUltraThinMaterial) }
        #else
        effect = UIBlurEffect(style: .systemUltraThinMaterial)
        #endif
        let surface = UIVisualEffectView(effect: effect)
        // The caller pins it to its button; it is exactly `diameter` across.
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.isUserInteractionEnabled = false
        surface.layer.cornerRadius = diameter / 2
        surface.layer.cornerCurve = .circular
        surface.clipsToBounds = true
        if effect is UIBlurEffect {
            surface.layer.borderWidth = 0.5
            surface.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        }
        return surface
    }

    /// A bar picture, kept for the app's life so each screen does not fetch it again.
    private static let barImages = NSCache<NSURL, UIImage>()

    private func loadBarImage(_ url: URL, _ done: @escaping (UIImage?) -> Void) {
        if let cached = Self.barImages.object(forKey: url as NSURL) { done(cached); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap(UIImage.init(data:)).map { $0.preparingForDisplay() ?? $0 }
            if let image { Self.barImages.setObject(image, forKey: url as NSURL) }
            DispatchQueue.main.async { done(image) }
        }.resume()
    }

    /// The first vertical scroll view of the screen drives the bar: a large
    /// title collapses as it scrolls, and the bar's background follows it.
    private func trackContentScrollView() {
        guard let renderedRoot else { return }
        // UIKit can resize the root before nested flex wrappers lay out.
        // Resolve their frames before checking empty siblings or edges so
        // old child frames cannot toggle the root constraints each pass.
        rootStack.layoutIfNeeded()
        func find(_ node: RenderedNode) -> UIScrollView? {
            // Modal content belongs to a separate presentation. Hidden
            // branches must not steal tracking from the visible screen.
            guard node.type != "Modal", !node.view.isHidden else { return nil }
            if let scroll = node.view as? CraftNativeScrollView, scroll.isVertical, scroll.isScrollEnabled { return scroll }
            if let list = node.view as? CraftNativeFlatList, list.isScrollEnabled,
               (list.collectionViewLayout as? UICollectionViewFlowLayout)?.scrollDirection != .horizontal { return list }
            for child in node.children {
                if let match = find(child) { return match }
            }
            return nil
        }
        /// The scroll view the screen starts with, when nothing sits above it:
        /// the root's first child, its first, and so on, none padded on top.
        func leading(_ node: RenderedNode) -> RenderedNode? {
            if let scroll = node.view as? CraftNativeScrollView { return scroll.isVertical && scroll.isScrollEnabled ? node : nil }
            if let list = node.view as? CraftNativeFlatList {
                return list.isScrollEnabled && (list.collectionViewLayout as? UICollectionViewFlowLayout)?.scrollDirection != .horizontal ? node : nil
            }
            guard paddingInsets(node.style).top == 0,
                  let first = node.children.first(where: { $0.type != "Modal" && !$0.view.isHidden && $0.view.bounds.height > 0 }) else { return nil }
            return leading(first)
        }
        let scroll = find(renderedRoot)
        let leadingScroll = leading(renderedRoot)
        // The leading scroller may overflow beneath navigation chrome.
        // A bounded list inside a form must clip its rows to its viewport.
        if let leadingScroll, leadingScroll.style["overflow"] as? String != "hidden" {
            leadingScroll.view.clipsToBounds = false
        }
        // Under a large title the screen runs edge to edge, as UIKit's own
        // screens do: the scroll view starts under the bar and insets its
        // content by it, so the title collapses and pull to refresh draws
        // in the bar's space. So does a screen that starts with its scroll
        // view: its content scrolls up under the bar behind iOS's scroll edge
        // effect, rather than over the bar's back button. Other screens stay
        // inside the safe area.
        let edgeToEdge = scroll != nil && (prefersLargeTitle == true || scroll === leadingScroll?.view)
        let fullEdgeToEdge = rootIsSafeAreaView
        let topEdgeToEdge = fullEdgeToEdge || edgeToEdge
        // Bottom clearance does not depend on the leading-scroll rule for
        // navigation titles. Follow the visible scroller through wrappers,
        // even after a header or empty sibling. Its laid-out viewport must
        // reach the root's bottom; zero-size/hidden siblings do not shorten
        // it. A bounded list, fixed footer, plain screen or presented sheet
        // must retain its safe-area bottom.
        // Use UIKit's automatic inset for tab/accessory clearance, rather
        // than adding a second explicit inset (also owned by keyboard code).
        var tabbedScroll = false
        if let scroll, scroll.bounds.height > 0,
           let tabBar = tabBarController?.tabBar, !tabBar.isHidden, tabBar.alpha > 0,
           let window = view.window, tabBar.window === window,
           tabBar.convert(tabBar.bounds, to: view).intersects(view.bounds) {
            let viewport = scroll.convert(scroll.bounds, to: rootStack)
            tabbedScroll = abs(viewport.maxY - rootStack.bounds.maxY) < 0.5
        }
        let bottomEdgeToEdge = fullEdgeToEdge || tabbedScroll
        rootTopToSafeArea?.isActive = !topEdgeToEdge
        rootTopToView?.isActive = topEdgeToEdge
        if bottomEdgeToEdge {
            rootBottomToSafeArea?.isActive = false
            rootBottomToView?.isActive = true
        } else {
            rootBottomToView?.isActive = false
            rootBottomToSafeArea?.isActive = true
        }
        rootLeadingToSafeArea?.isActive = !fullEdgeToEdge
        rootLeadingToView?.isActive = fullEdgeToEdge
        rootTrailingToSafeArea?.isActive = !fullEdgeToEdge
        rootTrailingToView?.isActive = fullEdgeToEdge
        scroll?.contentInsetAdjustmentBehavior = (edgeToEdge || tabbedScroll) ? .automatic : .never
        if scroll !== trackedScrollView {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                trackedScrollView?.topEdgeEffect.isHidden = false
                trackedScrollView?.bottomEdgeEffect.isHidden = false
            }
            #endif
            trackedScrollView = scroll
            // Keep UIKit's title collapse, tab selection and minimization
            // tracking; only the full-width edge backdrop changes below.
            setContentScrollView(scroll, for: [.top, .bottom])
        }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // Floating button groups carry their own material. UIKit's
            // separate scroll-edge wash would cover the content behind
            // and beyond them even with a transparent bar appearance.
            scroll?.topEdgeEffect.isHidden = topEdgeToEdge && !navigationBarSolid
            scroll?.bottomEdgeEffect.isHidden = tabbedScroll
        }
        #endif
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
        for name in [UIContentSizeCategory.didChangeNotification, UIAccessibility.reduceMotionStatusDidChangeNotification, UIAccessibility.reduceTransparencyStatusDidChangeNotification, .craftColorSchemeChanged] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refreshTraitDefaults()
                self?.sendAppearance()
            })
        }
        // The app script has no screen for the keyboard to cover.
        if !isAppScript {
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
        }
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: CraftSnapshots.changed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let name = notification.userInfo?["name"] as? String else { return }
            self?.send(type: "SNAPSHOT_CHANGED", payload: ["name": name])
        })
        if config.enableSecureStorage {
            // A sign-in, sign-out or another account, made on any screen or
            // the page (CraftSession): `SESSION_CHANGED { key, token,
            // previous }` for the runtime, then craft.session's listeners.
            lifecycleObservers.append(NotificationCenter.default.addObserver(
                forName: CraftSession.changed,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, let info = notification.userInfo, let key = info["key"] as? String else { return }
                let token = info["token"] as? String
                let previous = info["previous"] as? String
                self.send(type: "SESSION_CHANGED", payload: ["key": key, "token": token ?? NSNull(), "previous": previous ?? NSNull()])
                let context = self.jsContext
                CraftNativeScriptThread.run(label: "session \(self.routeName ?? "screen")") { context.objectForKeyedSubscript("__craftSessionChanged")?.call(withArguments: [token ?? NSNull(), previous ?? NSNull()]) }
            })
        }
        if config.enablePushNotifications {
            // A new device token (iOS hands one out after a reinstall or a
            // restore): every screen's `craft.push.onToken` hears it.
            lifecycleObservers.append(NotificationCenter.default.addObserver(
                forName: .craftPushToken,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let token = notification.object as? String else { return }
                self?.send(type: "PUSH_TOKEN", payload: ["token": token])
            })
        }
        // The coordinator's location events (a watch, a recording's fixes):
        // to this screen's script as the page's own CustomEvents.
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: CraftWebServices.event,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let name = notification.userInfo?["event"] as? String else { return }
            self?.send(type: "CRAFT_EVENT", payload: ["event": name, "detail": notification.userInfo?["detail"] ?? [:]])
        })
        sounds.emit = { [weak self] payload in self?.send(type: "SOUND_EVENT", payload: payload) }
        streams.emit = { [weak self] payload in self?.send(type: "NETWORK_STREAM", payload: payload) }
        sendAppState(CraftNativeActions.currentAppState())
        // Links are the screens' to show; the app script hears none.
        guard !isAppScript else { return }
        deepLinkListener = DeepLinkManager.shared.addNativeListener(canReceive: { [weak self] in
            guard let self = self else { return false }
            return self.reportedVisible == true && !self.runtimeDisposed && self.navigationController?.topViewController === self
        }) { [weak self] url, initial in
            guard let self = self else { return }
            var payload = CraftNativeActions.deepLinkData(url)
            payload["initial"] = initial
            self.send(type: "DEEP_LINK", payload: payload)
        }
    }

    private func applyKeyboardSafeArea(_ notification: Notification, hidden: Bool = false) {
        let inset: CGFloat
        let keyboardFrame: CGRect?
        if hidden {
            inset = 0
            keyboardFrame = nil
        } else if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
            keyboardFrame = frame.cgRectValue
            let local = view.convert(frame.cgRectValue, from: nil)
            // The safe area without the keyboard's own share, which an earlier
            // change of the keyboard's height added to it.
            inset = max(0, view.bounds.intersection(local).height - (view.safeAreaInsets.bottom - additionalSafeAreaInsets.bottom))
        } else {
            return
        }
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        let globalInset = containsKeyboardAvoidingView() ? 0 : inset
        let safeAreaChanged = abs(additionalSafeAreaInsets.bottom - globalInset) > 0.5
        keyboardSafeAreaInset = inset
        keyboardScreenFrame = keyboardFrame
        updateKeyboardAvoidingViews()
        UIView.animate(withDuration: duration, delay: 0, options: UIView.AnimationOptions(rawValue: UInt(curve << 16))) {
            if safeAreaChanged {
                self.additionalSafeAreaInsets.bottom = globalInset
                self.view.layoutIfNeeded()
            }
            self.insetScrollViewsForKeyboard()
            self.scrollFocusedInputIntoView(animated: false)
        }
    }

    private func updateKeyboardAvoidingViews() {
        func visit(_ node: RenderedNode?) {
            guard let node else { return }
            if let keyboard = node.view as? CraftNativeKeyboardAvoidingView {
                keyboard.setKeyboardInset(keyboardSafeAreaInset)
            }
            node.children.forEach(visit)
        }
        visit(renderedRoot)
    }

    private func containsKeyboardAvoidingView() -> Bool {
        func visit(_ node: RenderedNode?) -> Bool {
            guard let node else { return false }
            if node.view is CraftNativeKeyboardAvoidingView { return true }
            return node.children.contains(where: visit)
        }
        return visit(renderedRoot)
    }

    private func syncGlobalKeyboardSafeArea() {
        let globalInset = containsKeyboardAvoidingView() ? 0 : keyboardSafeAreaInset
        guard abs(additionalSafeAreaInsets.bottom - globalInset) > 0.5 else { return }
        additionalSafeAreaInsets.bottom = globalInset
        view.setNeedsLayout()
    }

    /// A scroll view the keyboard still covers part of (one that does not end
    /// at the screen's bottom edge, or a keyboard taller than the safe area
    /// took account of) insets its content by that much, so everything in it
    /// can be scrolled above the keyboard. Internal for XCTest.
    func insetScrollViewsForKeyboard() {
        var scrolls: [UIScrollView] = []
        func collect(_ node: RenderedNode?) {
            guard let node else { return }
            if let scroll = node.view as? CraftNativeScrollView, scroll.isVertical { scrolls.append(scroll) }
            node.children.forEach(collect)
        }
        collect(renderedRoot)
        for scroll in scrolls {
            var overlap: CGFloat = 0
            if let keyboard = keyboardScreenFrame, let window = scroll.window {
                let frame = scroll.convert(scroll.bounds, to: window)
                overlap = max(0, frame.maxY - window.convert(keyboard, from: nil).minY)
                // An edge-to-edge scroller already receives the keyboard's
                // safe-area share through UIKit. Add only uncovered overlap.
                let automaticBottom = max(0, scroll.adjustedContentInset.bottom - scroll.contentInset.bottom)
                overlap = max(0, overlap - automaticBottom)
            }
            if abs(scroll.contentInset.bottom - overlap) > 0.5 { scroll.contentInset.bottom = overlap }
            if abs(scroll.verticalScrollIndicatorInsets.bottom - overlap) > 0.5 { scroll.verticalScrollIndicatorInsets.bottom = overlap }
        }
    }

    /// A layout moved a view while the keyboard is up: once that pass is
    /// over, each scroll view's keyboard inset is measured again where the
    /// scroll view now ends. Measured only when the keyboard moved, a form
    /// that grew down under the keyboard (a footer below it shrank, a
    /// banner above it went away) kept the inset of where it used to end,
    /// and its last lines stayed under the keyboard.
    fileprivate func scheduleKeyboardInsets() {
        guard keyboardScreenFrame != nil, !keyboardInsetsScheduled else { return }
        keyboardInsetsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.keyboardInsetsScheduled = false
            if self.keyboardScreenFrame != nil { self.insetScrollViewsForKeyboard() }
        }
    }

    /// The focused field, scrolled into the part of its scroll view the
    /// keyboard leaves, with a little room around it.
    func scrollFocusedInputIntoView(animated: Bool) {
        guard let input = firstResponder(in: rootStack) else { return }
        scrollIntoView(input, animated: animated)
    }

    /// `input`, scrolled into the visible part of the scroll view it is in.
    /// Internal for XCTest.
    func scrollIntoView(_ input: UIView, animated: Bool) {
        guard let scroll = enclosingVerticalScroll(of: input) else { return }
        // Measured against the keyboard where the scroll view is now.
        if keyboardScreenFrame != nil { insetScrollViewsForKeyboard() }
        var rect = input.convert(input.bounds, to: scroll).insetBy(dx: 0, dy: -16)
        // A field taller than the part the keyboard leaves (a long comment
        // with no max height) shows its caret rather than its top: scrolled
        // to its top, the caret at the end of the text stayed under the
        // keyboard with no way to scroll it out.
        let visible = scroll.bounds.inset(by: scroll.adjustedContentInset)
        if rect.height > visible.height, let caret = caretRect(of: input, in: scroll) { rect = caret }
        scroll.scrollRectToVisible(rect, animated: animated)
    }

    /// The vertical scroll view `view` sits in, if any.
    private func enclosingVerticalScroll(of view: UIView) -> CraftNativeScrollView? {
        var ancestor = view.superview
        while let current = ancestor, !(current is CraftNativeScrollView) { ancestor = current.superview }
        guard let scroll = ancestor as? CraftNativeScrollView, scroll.isVertical else { return nil }
        return scroll
    }

    /// A focused input's caret in `scroll`'s coordinates, with a little room
    /// around it, kept within the input (one scrolling inside itself has its
    /// caret beyond its own frame until it scrolls to it).
    private func caretRect(of input: UIView, in scroll: UIScrollView) -> CGRect? {
        guard input.isFirstResponder, let text = input as? UITextInput,
              let end = text.selectedTextRange?.end else { return nil }
        let caret = text.caretRect(for: end)
        guard caret.minY.isFinite, caret.height > 0 else { return nil }
        let frame = input.convert(input.bounds, to: scroll)
        var rect = input.convert(caret, to: scroll)
        rect.origin.y = min(max(rect.minY, frame.minY), max(frame.minY, frame.maxY - rect.height))
        return rect.insetBy(dx: 0, dy: -16)
    }

    private func sendAppState(_ state: String) {
        // A screen hears it while it is on top of its stack; the app script,
        // which is on no stack, always.
        guard isAppScript || navigationController?.topViewController === self else { return }
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
        // The app script draws nothing for anything to stand in for: logged
        // (by the caller) and left to run on.
        guard !isAppScript else { return }
        hybridEvents?.nativeScreen(self, didFail: message)
    }

    /// A message from the screen's script, where the script runs: parsed
    /// there, then applied on the main thread in the order it was sent.
    private func receive(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["type"] is String else { return }
        CraftNativeScriptThread.toMain { [weak self] in self?.handle(message) }
    }

    private func handle(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
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
                // In the log as well: the screen redraws itself on this, so
                // nothing on screen says a batch was refused.
                CraftNativeConsole.write("error", category: screenName(), message: "mutation \(error["batchId"] ?? "") refused: \(failure.code) \(failure.message)")
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
            // A screen's own stack; the app script has none (it opens paths).
            guard !isAppScript, navigationController?.topViewController === self,
                  let screen = payload["screen"] as? String, !screen.isEmpty,
                  let navigation = navigationController else { return }
            if type == "NAVIGATE_REPLACE", screen.hasPrefix("/") {
                hybridEvents?.nativeScreen(self, replace: screen)
                return
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            let next = CraftNativeScreenController(config: config, routeName: screen, routeParams: params)
            next.hybridEvents = hybridEvents
            next.whenFirstRendered(within: 0.3) { [weak self, weak navigation] in
                guard let self, let navigation, navigation.topViewController === self else { return }
                if type == "NAVIGATE" {
                    navigation.pushViewController(next, animated: true)
                } else {
                    self.disposeRuntime()
                    navigation.setViewControllers(Array(navigation.viewControllers.dropLast()) + [next], animated: true)
                }
            }
        case "NAVIGATION_SET_OPTIONS":
            applyNavigationOptions(payload)
        case "ANIMATE_NEXT":
            // The next change the screen makes animates (craft.animation.next).
            beginAnimatedChange(payload)
        case "NAVIGATE_OPEN":
            // A path rather than a screen: the hybrid shell opens it, natively
            // or in the web view.
            guard let path = payload["path"] as? String, !path.isEmpty else { return }
            hybridEvents?.nativeScreen(self, open: path, props: payload["props"] as? [String: Any] ?? [:])
        case "NAVIGATE_BACK":
            if !isAppScript, navigationController?.topViewController === self {
                navigationController?.popViewController(animated: true)
            }
        case "NAVIGATE_POP_TO_ROOT":
            // Back to the first screen of this screen's stack in one move: a
            // finished task (a saved workout) closes the way it was reached.
            if !isAppScript, navigationController?.topViewController === self {
                navigationController?.popToRootViewController(animated: true)
            }
        case "API_REQUEST":
            guard !runtimeDisposed else { return }
            guard let id = message["id"] as? String else { return }
            let args = payload["args"] as? [Any] ?? []
            let requestToken = "\(capabilityScope)/\(id)"
            pendingCapabilityRequests.insert(requestToken)
            let deadline = DispatchWorkItem { [weak self] in
                guard let self = self, self.pendingCapabilityRequests.remove(requestToken) != nil else { return }
                self.pendingCapabilityDeadlines.removeValue(forKey: requestToken)
                self.screenRequestCancellers.removeValue(forKey: requestToken)?()
                CraftNativeActions.cancel(requestToken: requestToken)
                self.send(type: "API_ERROR", payload: [
                    "version": craftNativeCapabilityProtocolVersion,
                    "requestId": id,
                    "code": "TIMEOUT",
                    "message": "Native API request timed out",
                ], correlationId: id)
            }
            // A request a person answers (a share sheet, a dialog, the photo
            // picker, Face ID) says so (`untimed`, stx's callPersonFacingAPI)
            // and waits for them: a deadline would answer TIMEOUT while the
            // sheet is still up and they are still choosing.
            if payload["untimed"] as? Bool != true {
                pendingCapabilityDeadlines[requestToken] = deadline
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + .milliseconds(craftNativeCapabilityTimeoutMilliseconds),
                    execute: deadline
                )
            }
            let module = payload["module"] as? String ?? ""
            let method = payload["method"] as? String ?? ""
            // With frame pacing on: how long the capability took to answer,
            // which a screen's script waits on (a request, the keychain).
            let pacing = CraftFramePacing.shared
            let asked = pacing.enabled ? CACurrentMediaTime() : 0
            let route = routeName ?? "screen"
            let what = module == "Network" ? "\(module).\(method) \(((args.first as? [String: Any])?["url"] as? String).flatMap { URL(string: $0)?.path } ?? "")" : "\(module).\(method)"
            let reply: (Result<Any, CraftNativeActionError>) -> Void = { [weak self] answer in
                guard let self = self, self.pendingCapabilityRequests.remove(requestToken) != nil else { return }
                if pacing.enabled { pacing.capability("\(what) \(route)", took: CACurrentMediaTime() - asked) }
                self.pendingCapabilityDeadlines.removeValue(forKey: requestToken)?.cancel()
                self.screenRequestCancellers.removeValue(forKey: requestToken)
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
            if performOnScreen(module: module, method: method, args: args, requestToken: requestToken, reply: reply) { return }
            CraftNativeActions.perform(
                requestToken: requestToken,
                version: payload["version"] as? Int ?? craftNativeCapabilityProtocolVersion,
                module: module,
                method: method,
                args: args,
                config: config,
                completion: reply
            )
        case "API_CANCEL":
            guard let id = payload["requestId"] as? String else { return }
            let requestToken = "\(capabilityScope)/\(id)"
            guard pendingCapabilityRequests.remove(requestToken) != nil else { return }
            pendingCapabilityDeadlines.removeValue(forKey: requestToken)?.cancel()
            screenRequestCancellers.removeValue(forKey: requestToken)?()
            CraftNativeActions.cancel(requestToken: requestToken)
        default:
            break
        }
    }

    /// The modules whose work belongs to this screen and ends with it:
    /// `craft.audio`'s sounds and streaming `fetch`. False for any other
    /// module, which CraftNativeActions serves.
    private func performOnScreen(
        module: String,
        method: String,
        args: [Any],
        requestToken: String,
        reply: @escaping (Result<Any, CraftNativeActionError>) -> Void
    ) -> Bool {
        func number(_ index: Int, _ key: String? = nil) -> Double {
            guard args.count > index else { return 0 }
            if let key { return ((args[index] as? [String: Any])?[key] as? NSNumber)?.doubleValue ?? 0 }
            return (args[index] as? NSNumber)?.doubleValue ?? 0
        }
        let id = args.first as? String ?? ""
        switch (module, method) {
        case ("AudioRecording", _):
            guard config.enableAudioRecording else {
                reply(.failure(CraftNativeActionError(code: "CAPABILITY_DISABLED", message: "Audio recording is disabled")))
                return true
            }
            if method == "start" {
                guard voiceRecordingOwner == nil else {
                    reply(.failure(CraftNativeActionError(code: "RECORDING_BUSY", message: "This screen already owns a recording")))
                    return true
                }
                voiceRecordingOwner = id
            }
            if method == "cancel", voiceRecordingOwner == id { voiceRecordingOwner = nil }
            CraftVoiceRecording.shared.perform(method: method, args: args, isActive: { [weak self] in self?.runtimeDisposed == false }) { [weak self] result in
                if case .failure = result, self?.voiceRecordingOwner == id { self?.voiceRecordingOwner = nil }
                reply(result)
            }
            return true
        case ("View", "focus"):
            let options = args.first as? [String: Any]
            let nodeId = options?["nodeId"] as? String ?? (args.first as? String) ?? ""
            let mode = options?["mode"] as? String ?? (args.count > 1 ? args[1] as? String : nil) ?? "keyboard"
            guard !nodeId.isEmpty else {
                reply(.failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "View.focus needs a nodeId")))
                return true
            }
            guard let node = renderedNode(nodeId) else {
                reply(.failure(CraftNativeActionError(code: "VIEW_NOT_FOUND", message: "View.focus could not find mounted node \(nodeId)")))
                return true
            }
            guard node.view.window != nil else {
                reply(.failure(CraftNativeActionError(code: "VIEW_NOT_MOUNTED", message: "View.focus requires a mounted node")))
                return true
            }
            switch mode {
            case "keyboard":
                guard node.view is UITextField || node.view is UITextView else {
                    reply(.failure(CraftNativeActionError(code: "UNSUPPORTED_TARGET", message: "Keyboard focus is supported only for text inputs")))
                    return true
                }
                guard node.view.becomeFirstResponder() else {
                    reply(.failure(CraftNativeActionError(code: "FOCUS_FAILED", message: "The mounted view refused keyboard focus")))
                    return true
                }
                lastFocusedInput = node.view
                reply(.success(true))
            case "accessibility":
                UIAccessibility.post(notification: .layoutChanged, argument: node.view)
                reply(.success(true))
            default:
                reply(.failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "View.focus mode must be keyboard or accessibility")))
            }
            return true
        case ("View", "measure"):
            let options = args.first as? [String: Any]
            let nodeId = options?["nodeId"] as? String ?? (args.first as? String) ?? ""
            guard !nodeId.isEmpty else {
                reply(.failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "View.measure needs a nodeId")))
                return true
            }
            guard let node = renderedNode(nodeId) else {
                reply(.failure(CraftNativeActionError(code: "VIEW_NOT_FOUND", message: "View.measure could not find mounted node \(nodeId)")))
                return true
            }
            guard node.view.window != nil else {
                reply(.failure(CraftNativeActionError(code: "VIEW_NOT_MOUNTED", message: "View.measure requires a mounted node")))
                return true
            }
            view.layoutIfNeeded()
            let bounds = node.view.convert(node.view.bounds, to: view)
            guard bounds.origin.x.isFinite, bounds.origin.y.isFinite, bounds.width.isFinite, bounds.height.isFinite else {
                reply(.failure(CraftNativeActionError(code: "MEASURE_FAILED", message: "The mounted view has no finite layout")))
                return true
            }
            reply(.success([
                "x": bounds.origin.x,
                "y": bounds.origin.y,
                "width": bounds.width,
                "height": bounds.height,
                "viewportWidth": view.bounds.width,
                "viewportHeight": view.bounds.height,
                "unit": "points",
                "coordinateSpace": "screenViewport",
            ]))
            return true
        case ("View", "scrollTo"):
            let options = args.first as? [String: Any]
            let nodeId = options?["nodeId"] as? String ?? (args.first as? String) ?? ""
            guard !nodeId.isEmpty else {
                reply(.failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "View.scrollTo needs a nodeId")))
                return true
            }
            guard let node = renderedNode(nodeId) else {
                reply(.failure(CraftNativeActionError(code: "VIEW_NOT_FOUND", message: "View.scrollTo could not find mounted node \(nodeId)")))
                return true
            }
            guard node.view.window != nil else {
                reply(.failure(CraftNativeActionError(code: "VIEW_NOT_MOUNTED", message: "View.scrollTo requires a mounted node")))
                return true
            }
            guard let scrollView = node.view as? UIScrollView else {
                reply(.failure(CraftNativeActionError(code: "UNSUPPORTED_TARGET", message: "View.scrollTo is supported only for scroll views")))
                return true
            }
            let x: Double
            if let raw = options?["x"] {
                guard let number = craftNativeNumber(raw), number.doubleValue.isFinite else {
                    reply(.failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "View.scrollTo coordinates must be finite numbers")))
                    return true
                }
                x = number.doubleValue
            } else {
                x = scrollView.contentOffset.x
            }
            let y: Double
            if let raw = options?["y"] {
                guard let number = craftNativeNumber(raw), number.doubleValue.isFinite else {
                    reply(.failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "View.scrollTo coordinates must be finite numbers")))
                    return true
                }
                y = number.doubleValue
            } else {
                y = scrollView.contentOffset.y
            }
            guard x.isFinite, y.isFinite else {
                reply(.failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "View.scrollTo coordinates must be finite numbers")))
                return true
            }
            let minX = -scrollView.adjustedContentInset.left
            let minY = -scrollView.adjustedContentInset.top
            let maxX = max(minX, scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right)
            let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            let target = CGPoint(x: min(max(x, minX), maxX), y: min(max(y, minY), maxY))
            scrollView.setContentOffset(target, animated: options?["animated"] as? Bool ?? false)
            reply(.success(["x": target.x, "y": target.y, "unit": "points"]))
            return true
        case ("Network", "stream"):
            let options = args.first as? [String: Any] ?? [:]
            let streamId = options["id"] as? String ?? ""
            screenRequestCancellers[requestToken] = { [weak self] in self?.streams.cancel(id: streamId) }
            streams.open(id: streamId, options: options, answer: reply)
        case ("Network", "cancelStream"):
            streams.cancel(id: id)
            reply(.success(true))
        case ("Audio", "play"):
            guard args.count > 1, let address = args[1] as? String, let url = URL(string: address), url.scheme != nil, !id.isEmpty else {
                reply(.failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "audio.play needs a URL")))
                return true
            }
            screenRequestCancellers[requestToken] = { [weak self] in self?.sounds.stop(id: id, fadeOut: 0) }
            sounds.play(id: id, url: url, options: args.count > 2 ? args[2] as? [String: Any] ?? [:] : [:], answer: reply)
        case ("Audio", "pause"):
            reply(.success(sounds.pause(id: id)))
        case ("Audio", "resume"):
            reply(.success(sounds.resume(id: id)))
        case ("Audio", "setVolume"):
            reply(.success(sounds.setVolume(id: id, volume: number(1), fade: number(2, "fade") / 1000)))
        case ("Audio", "stop"):
            reply(.success(sounds.stop(id: id, fadeOut: number(1, "fadeOut") / 1000)))
        case ("Audio", "stopAll"):
            reply(.success(sounds.stopAll(fadeOut: number(0, "fadeOut") / 1000)))
        default:
            return false
        }
        return true
    }

    /// Runs script in the screen's JavaScript context. Internal for
    /// simulator-hosted XCTest of the host APIs.
    @discardableResult
    func evaluateScript(_ script: String) -> JSValue? {
        // From the main thread (tests); waits for the script thread's turn.
        guard CraftNativeScriptThread.isBackground else { return jsContext.evaluateScript(script) }
        return CraftNativeScriptThread.queue.sync { jsContext.evaluateScript(script) }
    }

    // Internal so simulator-hosted XCTest can assert actual UIView identity.
    func render(_ document: [String: Any]) {
        mutationDocument.replace(with: document)
        renderCommitted(document)
        if !hybridRendered {
            hybridRendered = true
            // The app script's drawing is never on screen: not a first frame.
            if !isAppScript { hybridEvents?.nativeScreenDidRender(self) }
            // Drawn without a word about the accessory: it wants none.
            if !isAppScript, !tabAccessoryDeclared, isShownOnScreen { CraftChrome.shared.clearUnclaimedTabAccessory() }
            let waiting = renderWaiters
            renderWaiters.removeAll()
            waiting.forEach { $0() }
        }
    }

    private var renderWaiters: [() -> Void] = []

    /// `work` once the screen has its first content, or after `seconds`,
    /// whichever comes first. A screen whose script runs on its own thread
    /// (CraftNativeScriptThread) draws a moment after it is made: a push
    /// waits for that, so the screen never slides in empty. Now, with the
    /// script on the main thread, which drew it as it was made.
    func whenFirstRendered(within seconds: TimeInterval, _ work: @escaping () -> Void) {
        guard CraftNativeScriptThread.isBackground, !isAppScript else { work(); return }
        loadViewIfNeeded()
        guard !hybridRendered else { work(); return }
        var done = false
        let once = {
            guard !done else { return }
            done = true
            work()
        }
        renderWaiters.append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: once)
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
            guard let target = drawnTarget(id) else { return false }
            guard applied.insert(target).inserted else { continue }
            guard let document = mutationDocument.node(target), let previous = renderedNode(target) else { return false }
            // A node that needs a new view (a TextInput turned multiline) is
            // its parent's to swap in: a targeted update only redraws in
            // place, and the new view was made and never attached.
            guard canReuseView(document, previous: previous) else { return false }
            let next = reconcile(document, identity: previous.identity, path: target, previous: previous)
            // A style patch is applied in place, layout included: the parent
            // reads the node's new layout style on its next pass.
            CraftNativeFlexLayout.invalidateAncestors(of: next.view)
        }
        if !applied.isEmpty {
            // A targeted mutation can change geometry without causing UIKit
            // to call viewDidLayoutSubviews again. Keep onLayout delivery
            // aligned with Android's post-mutation layout pass.
            scheduleLayoutEvents()
        }
        restoreFocus(focused)
        return true
    }

    /// The drawn node a change to `id` redraws: the list or drawing a row or
    /// shape belongs to, else the node itself. A node this batch created is
    /// not drawn yet (a drawing an `:if` just revealed, its shapes inserted
    /// into it), so its nearest drawn ancestor draws it, rather than the whole
    /// screen being reconciled again for want of it.
    private func drawnTarget(_ id: String) -> String? {
        var current: String? = id
        while let candidate = current {
            let target = flatListOwners[candidate] ?? svgOwners[candidate] ?? candidate
            if renderedNode(target) != nil { return target }
            current = mutationDocument.parentId(of: candidate)
        }
        return nil
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
        statusBarStyleOverride = nil
        statusBarHiddenOverride = nil
        let previous = renderedRoot
        previousNodesByProtocolID.removeAll(keepingCapacity: true)
        adoptedPreviousProtocolIDs.removeAll(keepingCapacity: true)
        indexPreviousNodes(previous)
        let next = reconcile(document, identity: "root", path: "root", previous: previous)
        previousNodesByProtocolID.removeAll(keepingCapacity: true)
        adoptedPreviousProtocolIDs.removeAll(keepingCapacity: true)
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
        // A native screen root fills the safe-area viewport unless the bundle
        // explicitly sizes it. Without this default, an unstyled SafeAreaView
        // measures to its scroll content and leaves no viewport to scroll.
        var rootStyle = next.style
        if rootStyle["flex"] == nil, rootStyle["height"] == nil { rootStyle["flex"] = 1 }
        rootStack.setLayoutStyle(rootStyle, for: next.view)
        rootStack.setViewportChild(next.view, fillsHeight: rootStyle["height"] == nil)
        rootStack.invalidateMeasurements()
        renderedRoot = next
        rootIsSafeAreaView = next.type == "SafeAreaView"
        updateKeyboardAvoidingViews()
        syncGlobalKeyboardSafeArea()
        trackContentScrollView()
        setNeedsStatusBarAppearanceUpdate()
        restoreFocus(focused)
    }

    private func clearRenderedTree() {
        if let root = renderedRoot { detach(root, from: rootStack) }
        renderedRoot = nil
        trackedScrollView = nil
        setContentScrollView(nil, for: [.top, .bottom])
        rootIsSafeAreaView = false
        rootStack.setViewportChild(nil, fillsHeight: false)
        rootTopToSafeArea?.isActive = true
        rootTopToView?.isActive = false
        rootBottomToSafeArea?.isActive = true
        rootBottomToView?.isActive = false
        rootLeadingToSafeArea?.isActive = true
        rootLeadingToView?.isActive = false
        rootTrailingToSafeArea?.isActive = true
        rootTrailingToView?.isActive = false
        statusBarStyleOverride = nil
        statusBarHiddenOverride = nil
        setNeedsStatusBarAppearanceUpdate()
        syncGlobalKeyboardSafeArea()
    }

    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let responder = firstResponder(in: child) { return responder }
        }
        return nil
    }

    /// Whether `previous`'s view can draw `node`: the same type, and for a
    /// TextInput the same kind of field (multiline is a UITextView).
    private func canReuseView(_ node: [String: Any], previous: RenderedNode) -> Bool {
        let type = canonicalType(node["type"] as? String ?? "View")
        guard previous.type == type else { return false }
        if type == "Switch" {
            let props = node["props"] as? [String: Any] ?? [:]
            return (previous.view is CraftNativeSolidSwitch) == (props["ios_solid"] as? Bool == true)
        }
        if type == "Text" {
            let props = node["props"] as? [String: Any] ?? [:]
            return (previous.view is CraftNativeSelectableTextView) == (props["selectable"] as? Bool == true)
        }
        guard type == "TextInput" else { return true }
        let props = node["props"] as? [String: Any] ?? [:]
        return (previous.view is UITextView) == (props["multiline"] as? Bool == true)
    }

    private func restoreFocus(_ focused: UIView?) {
        guard let focused, focused.window != nil, !focused.isFirstResponder,
              lastFocusedInput === focused, firstResponder(in: rootStack) == nil else { return }
        var ancestor: UIView? = focused
        while let view = ancestor {
            if view.isHidden { return }
            ancestor = view.superview
        }
        // A delayed acknowledgement belongs to the input that scheduled it.
        // A newer field or an explicit dismissal owns focus now.
        _ = focused.becomeFirstResponder()
    }

    /// `adopting`: `previous` is a recycled list row's root, whose views may
    /// show this row instead (`identity` is the new row's).
    private func reconcile(_ node: [String: Any], identity: String, path: String, previous: RenderedNode?, adopting: Bool = false) -> RenderedNode {
        let type = canonicalType(node["type"] as? String ?? "View")
        let props = node["props"] as? [String: Any] ?? [:]
        let style = node["style"] as? [String: Any] ?? [:]
        let events = node["events"] as? [String: String] ?? [:]
        let children = node["children"] as? [Any] ?? []
        let protocolId = node["id"] as? String
        let retained = previous ?? protocolId.flatMap { id in
            guard !adoptedPreviousProtocolIDs.contains(id) else { return nil }
            return previousNodesByProtocolID[id]
        }
        let adopted = previous == nil && retained != nil
        let current: RenderedNode
        if let retained, (retained.identity == identity || adopting || adopted), canReuseView(node, previous: retained) {
            current = retained
            if let protocolId { adoptedPreviousProtocolIDs.insert(protocolId) }
            current.identity = identity
        } else {
            current = RenderedNode(identity: identity, type: type, view: makeView(type, props: props))
        }

        let result = current.view
        current.protocolId = protocolId
        current.style = style
        let linkTarget = ["href", "to"].lazy.compactMap { props[$0] as? String }
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if ["Link", "TouchableOpacity", "TouchableHighlight", "Pressable"].contains(type),
           props["disabled"] as? Bool != true, let linkTarget {
            linkTargets[ObjectIdentifier(result)] = linkTarget
        } else {
            linkTargets.removeValue(forKey: ObjectIdentifier(result))
        }
        result.accessibilityIdentifier = accessibilityIdentifier(node, props: props) ?? path
        if let transitionID = props["transitionID"] as? String, !transitionID.isEmpty {
            transitionIDs[ObjectIdentifier(result)] = transitionID
        } else {
            transitionIDs.removeValue(forKey: ObjectIdentifier(result))
        }
        if type != "View" && type != "SafeAreaView" && type != "KeyboardAvoidingView" && type != "ScrollView" && type != "SectionList" && type != "FlatList" && type != "Modal" {
            result.setContentHuggingPriority(.required, for: .vertical)
        }
        applyViewStyle(style, to: result, node: current)
        if type == "SafeAreaView", let safeArea = result as? CraftNativeSafeAreaView {
            safeArea.setSafeAreaEdges(props["edges"])
        }
        updateLayoutHandler(events["onLayout"], for: result)
        if type == "StatusBar" { applyStatusBar(props) }

        switch type {
        case "StatusBar", "RefreshControl":
            // StatusBar is a screen trait, and RefreshControl is consumed by
            // its nearest ScrollView. Neither contributes a visible child.
            result.isHidden = true
            result.isUserInteractionEnabled = false
        case "Text":
            let text = children.compactMap { $0 as? String }.joined()
            if let selectable = result as? CraftNativeSelectableTextView {
                selectable.textContainer.maximumNumberOfLines = max(0, Int(number(props["numberOfLines"]) ?? 0))
                selectable.textContainer.lineBreakMode = textLineBreakMode(props["ellipsizeMode"])
                configureSelectableText(selectable, text: text, style: style)
            } else {
                let label = result as! UILabel
                label.numberOfLines = max(0, Int(number(props["numberOfLines"]) ?? 0))
                label.lineBreakMode = textLineBreakMode(props["ellipsizeMode"])
                (label as? CraftNativeLabel)?.insets = paddingInsets(style)
                configureText(label, text: text, style: style)
            }
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
            (button as? CraftNativeButton)?.padding = paddingInsets(style)
            button.isEnabled = props["disabled"] as? Bool != true
            updateHandler(nonEmptyHandler(events["onPress"]) ?? nonEmptyHandler(events["onClick"]), for: button)
        case "Checkbox":
            let checkbox = result as! CraftNativeCheckboxButton
            let label = props["label"] as? String ?? children.compactMap { $0 as? String }.joined()
            let transformedLabel = transformedText(label, style: style)
            let checked = (props["checked"] as? Bool) ?? (props["value"] as? Bool) ?? false
            let indeterminate = props["indeterminate"] as? Bool == true
            checkbox.isSelected = checked
            checkbox.indeterminate = indeterminate
            checkboxIndeterminate[ObjectIdentifier(checkbox)] = indeterminate
            checkbox.setTitle(transformedLabel, for: .normal)
            checkbox.setAttributedTitle(NSAttributedString(
                string: transformedLabel,
                attributes: buttonTitleAttributes(style, color: color(props["color"]) ?? color(style["color"]) ?? .label, font: textFont(style, default: .systemFont(ofSize: 16)), forceUnderline: false)
            ), for: .normal)
            let uncheckedImage = UIImage(systemName: indeterminate ? "minus.square" : "square")
            checkbox.setImage(uncheckedImage, for: .normal)
            checkbox.setImage(
                UIImage(systemName: indeterminate ? "minus.square" : "checkmark.square.fill"),
                for: .selected
            )
            checkbox.tintColor = color(props["color"]) ?? color(style["color"]) ?? .systemBlue
            checkbox.isEnabled = props["disabled"] as? Bool != true
            updateHandler(nonEmptyHandler(events["onValueChange"]) ?? nonEmptyHandler(events["onChange"]), for: checkbox)
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
            if let placeholder = props["placeholder"] as? String,
               let placeholderColor = color(props["placeholderTextColor"]) {
                field.attributedPlaceholder = NSAttributedString(
                    string: placeholder,
                    attributes: [.foregroundColor: placeholderColor]
                )
            } else {
                // UIKit shares these properties: resetting the attributed
                // value after the plain one also erases the visible hint.
                field.attributedPlaceholder = nil
                field.placeholder = props["placeholder"] as? String
            }
            field.tintColor = color(props["selectionColor"])
            let fieldId = ObjectIdentifier(field)
            inputIdentities[fieldId] = current.identity
            let maxLength = Int(number(props["maxLength"]) ?? 0)
            if maxLength > 0 {
                textMaxLengths[fieldId] = maxLength
            } else {
                textMaxLengths.removeValue(forKey: fieldId)
            }
            field.delegate = self
            switch props["clearButtonMode"] as? String {
            case "while-editing": field.clearButtonMode = .whileEditing
            case "unless-editing": field.clearButtonMode = .unlessEditing
            case "always": field.clearButtonMode = .always
            default: field.clearButtonMode = .never
            }
            (field as? CraftNativeTextField)?.padding = paddingInsets(style)
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
            applyAutofill(to: field, props: props)
            if let value = props["value"] as? String {
                updateField(field, value: value, acknowledged: (props["mostRecentEventCount"] as? NSNumber)?.intValue)
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
        case "SegmentedControl":
            let control = result as! CraftNativeSegmentedControl
            let items = props["items"] as? [[String: Any]] ?? []
            let labels = items.map { $0["label"] as? String ?? craftNativePickerValue($0["value"]) ?? "" }
            // UIKit owns the segments; only rebuild when the choices change.
            // Setting a controlled value never dispatches valueChanged.
            if control.numberOfSegments != labels.count || labels.enumerated().contains(where: { control.titleForSegment(at: $0.offset) != $0.element }) {
                control.removeAllSegments()
                for (index, label) in labels.enumerated() { control.insertSegment(withTitle: label, at: index, animated: false) }
            }
            control.values = items.map { $0["value"] as? String ?? craftNativePickerValue($0["value"]) ?? "" }
            for (index, item) in items.enumerated() { control.setEnabled(item["disabled"] as? Bool != true, forSegmentAt: index) }
            let selected = props["value"] as? String ?? craftNativePickerValue(props["value"]) ?? props["selectedValue"] as? String ?? craftNativePickerValue(props["selectedValue"])
            control.selectedSegmentIndex = control.values.firstIndex(where: { $0 == selected }) ?? UISegmentedControl.noSegment
            control.isEnabled = props["disabled"] as? Bool != true
            control.selectedSegmentTintColor = color(props["tintColor"])
            let titleAttributes: [NSAttributedString.Key: Any]? = color(style["color"]).map { [.foregroundColor: $0] }
            control.setTitleTextAttributes(titleAttributes, for: .normal)
            control.setTitleTextAttributes(titleAttributes, for: .selected)
            control.configureAccessibility(items: items)
            updateHandler(nonEmptyHandler(events["onValueChange"]) ?? nonEmptyHandler(events["onChange"]), for: control)
        case "Picker":
            let picker = result as! UIPickerView
            let itemOptions = (props["items"] as? [[String: Any]])?.compactMap { item -> (value: String, label: String)? in
                guard let label = item["label"] as? String, !label.isEmpty else { return nil }
                return (value: craftNativePickerValue(item["value"]) ?? label, label: label)
            } ?? []
            let options = itemOptions.isEmpty
                ? children.compactMap { child -> (value: String, label: String)? in
                    guard let node = child as? [String: Any], node["type"] as? String == "Text" else { return nil }
                    let optionProps = node["props"] as? [String: Any] ?? [:]
                    let label = (node["children"] as? [Any] ?? []).compactMap { $0 as? String }.joined()
                    guard !label.isEmpty else { return nil }
                    return (value: craftNativePickerValue(optionProps["value"]) ?? label, label: label)
                }
                : itemOptions
            let pickerID = ObjectIdentifier(picker)
            pickerOptions[pickerID] = options
            picker.reloadAllComponents()
            if let selected = craftNativePickerValue(props["selectedValue"]) ?? craftNativePickerValue(props["value"]),
               let row = options.firstIndex(where: { $0.value == selected }) {
                picker.selectRow(row, inComponent: 0, animated: false)
            } else if !options.isEmpty {
                picker.selectRow(0, inComponent: 0, animated: false)
            }
            picker.isUserInteractionEnabled = props["disabled"] as? Bool != true
            updateHandler(nonEmptyHandler(events["onValueChange"]) ?? nonEmptyHandler(events["onChange"]), for: picker)
        case "DatePicker":
            let picker = result as! UIDatePicker
            let mode = Self.datePickerMode(props["mode"])
            // A countdown is wheels only: UIKit asserts (and the app aborts)
            // on a countdown in the compact or inline style, so the style is
            // settled before the mode becomes a countdown, and after it
            // stops being one.
            let display: UIDatePickerStyle = mode == .countDownTimer ? .wheels
                : props["display"] as? String == "inline" ? .inline
                : props["display"] as? String == "wheels" || props["display"] as? String == "spinner" ? .wheels
                : .compact
            if mode == .countDownTimer {
                if picker.preferredDatePickerStyle != display { picker.preferredDatePickerStyle = display }
                if picker.datePickerMode != mode { picker.datePickerMode = mode }
            } else {
                if picker.datePickerMode != mode { picker.datePickerMode = mode }
                if picker.preferredDatePickerStyle != display { picker.preferredDatePickerStyle = display }
            }
            // UIKit takes an interval that divides an hour, and ignores others.
            let interval = Int(number(props["minuteInterval"]) ?? 1)
            picker.minuteInterval = (1...30).contains(interval) && 60 % interval == 0 ? interval : 1
            picker.minimumDate = Self.pickerDate(props["minimumDate"])
            picker.maximumDate = Self.pickerDate(props["maximumDate"])
            if mode == .countDownTimer {
                if let duration = Self.countdownDuration(props["value"]), abs(picker.countDownDuration - duration) >= 1 {
                    picker.countDownDuration = duration
                }
            } else if let date = Self.pickerDate(props["value"]), abs(picker.date.timeIntervalSince(date)) >= 1 {
                picker.setDate(date, animated: false)
            }
            picker.tintColor = color(props["color"]) ?? color(style["color"])
            picker.isEnabled = props["disabled"] as? Bool != true
            updateHandler(nonEmptyHandler(events["onValueChange"]) ?? nonEmptyHandler(events["onChange"]), for: picker)
        case "Modal":
            let modal = result as! CraftNativeModalView
            let focusBeforeContent = firstResponder(in: rootStack) ?? lastFocusedInput
            modal.sheetPresenter = self
            modal.presentationStyle = props["presentationStyle"] as? String ?? "overFullScreen"
            modal.sheetDetents = props["sheetDetents"] as? [String] ?? ["medium", "large"]
            modal.selectedDetent = props["selectedDetent"] as? String
            modal.grabberVisible = props["grabberVisible"] as? Bool != false
            modal.onRequestClose = nonEmptyHandler(events["onRequestClose"]).map { handler in
                { [weak self] reason in self?.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["reason": reason]]) }
            }
            modal.transparent = props["transparent"] as? Bool == true
            modal.blocksBackground = props["nonModal"] as? Bool != true
            modal.dismissOnOutsideTap = props["dismissOnOutsideTap"] as? Bool == true
            let visible: Bool
            if let propVisible = props["visible"] as? Bool {
                // An explicit visible prop owns modal visibility. The
                // binding runtime may leave a stale display:none style
                // from the previous hidden state when it patches props.
                visible = propVisible
            } else {
                let display = style["display"] as? String
                visible = display != nil && display != "none"
            }
            let modalID = ObjectIdentifier(modal)
            let wasVisible = modalVisibility[modalID]
            modalVisibility[modalID] = visible
            if visible, wasVisible != true, let focusBeforeContent,
               !focusBeforeContent.isDescendant(of: modal) {
                modalFocusRestore[modalID] = focusBeforeContent
            }
            if visible, wasVisible != true { positionModals() }
            modal.setVisible(visible, opacity: number(style["opacity"]) ?? 1, animationType: props["animationType"] as? String)
            if !visible, wasVisible == true {
                let restore = modalFocusRestore.removeValue(forKey: modalID)
                DispatchQueue.main.async { [weak self, weak restore] in
                    guard let self, let restore, restore.window != nil, restore.isDescendant(of: self.view) else { return }
                    self.lastFocusedInput = restore
                    _ = restore.becomeFirstResponder()
                }
            }
            modal.onRequestClose = nonEmptyHandler(events["onRequestClose"]).map { handler in
                { [weak self] reason in self?.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["reason": reason]]) }
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
            let disabled = props["disabled"] as? Bool == true
            pressable.pressActiveOpacity = disabled
                ? nil : number(props["activeOpacity"]) ?? 0.5
            pressable.pressBaseOpacity = number(style["opacity"]) ?? 1
            pressable.pressUnderlayColor = type == "TouchableHighlight" && !disabled ? color(props["underlayColor"]) : nil
        case "Switch":
            if let toggle = result as? CraftNativeSolidSwitch {
                if let value = props["value"] as? Bool ?? props["checked"] as? Bool { toggle.setOn(value) }
                toggle.isEnabled = props["disabled"] as? Bool != true
                let track = props["trackColor"] as? [String: Any]
                toggle.onColor = track == nil ? color(style["color"]) : color(track?["true"])
                toggle.offColor = color(props["ios_backgroundColor"]) ?? color(track?["false"])
                toggle.thumbColor = color(props["thumbColor"])
                updateHandler(nonEmptyHandler(events["onValueChange"]) ?? nonEmptyHandler(events["onChange"]), for: toggle)
                break
            }
            let toggle = result as! UISwitch
            // A supplied value controls the switch; without one, UIKit owns
            // the state and a reconciliation must not erase a user's tap.
            // `value: null` deliberately falls through to `checked`, matching
            // the host-neutral precedence used by the other renderer.
            if let value = props["value"] as? Bool ?? props["checked"] as? Bool {
                // UIKit has already changed the value before emitting the
                // event. Echoing it through the script must not restart its
                // native animation.
                let id = ObjectIdentifier(toggle)
                if switchUserValues[id] != value, toggle.isOn != value {
                    // Programmatic changes should settle immediately. A
                    // native tap is handled above without touching UIKit
                    // while its own thumb animation is in flight.
                    toggle.setOn(value, animated: false)
                }
            }
            toggle.isEnabled = props["disabled"] as? Bool != true
            if let track = props["trackColor"] as? [String: Any] {
                toggle.onTintColor = color(track["true"])
                toggle.tintColor = color(track["false"])
            } else {
                toggle.onTintColor = color(style["color"])
                toggle.tintColor = nil
            }
            toggle.thumbTintColor = color(props["thumbColor"])
            if let background = color(props["ios_backgroundColor"]) { toggle.tintColor = background }
            updateHandler(nonEmptyHandler(events["onValueChange"]) ?? nonEmptyHandler(events["onChange"]), for: toggle)
        case "Slider":
            let slider = result as! UISlider
            let minimum = Float(number(props["minimumValue"]) ?? 0)
            slider.minimumValue = minimum.isFinite ? minimum : 0
            let maximum = Float(number(props["maximumValue"]) ?? 1)
            slider.maximumValue = max(slider.minimumValue + .leastNonzeroMagnitude, maximum.isFinite ? maximum : 1)
            let authoredValue = Float(number(props["value"]) ?? CGFloat(slider.minimumValue))
            let value = authoredValue.isFinite ? authoredValue : slider.minimumValue
            if let step = number(props["step"]).map(Float.init), step.isFinite, step > 0 { sliderSteps[ObjectIdentifier(slider)] = step }
            else { sliderSteps.removeValue(forKey: ObjectIdentifier(slider)) }
            slider.value = snappedSliderValue(value, for: slider)
            slider.minimumTrackTintColor = color(props["minimumTrackTintColor"])
            slider.maximumTrackTintColor = color(props["maximumTrackTintColor"])
            slider.thumbTintColor = color(props["thumbTintColor"])
            slider.isEnabled = props["disabled"] as? Bool != true
            updateHandler(nonEmptyHandler(events["onValueChange"]) ?? nonEmptyHandler(events["onChange"]), for: slider)
            updateAuxiliaryHandler(events["onSlidingComplete"], in: &sliderCompleteHandlers, for: slider)
        case "ActivityIndicator":
            let indicator = result as! CraftNativeActivityIndicatorView
            let requestedSize = props["size"]
            indicator.style = (requestedSize as? String) == "large" ? .large : .medium
            let scale: CGFloat
            if let numericSize = number(requestedSize) {
                let value = numericSize / 20.0
                scale = value.isFinite ? max(0.5, value) : 1
            } else if (requestedSize as? String) == "small" {
                scale = 0.75
            } else {
                scale = 1
            }
            indicator.indicatorScale = scale
            applyTransform(style["transform"], to: indicator)
            indicator.color = color(props["color"]) ?? color(style["color"]) ?? .tintColor
            indicator.hidesWhenStopped = props["hidesWhenStopped"] as? Bool ?? true
            if props["animating"] as? Bool == false {
                indicator.stopAnimating()
                // UIKit does not retroactively reveal an indicator when an
                // already-stopped view changes hidesWhenStopped to false.
                // Android applies the requested visibility on every render;
                // keep the two hosts in lockstep for dynamic prop changes.
                indicator.isHidden = style["display"] as? String == "none" || indicator.hidesWhenStopped
            } else {
                indicator.startAnimating()
                indicator.isHidden = style["display"] as? String == "none"
            }
        case "Svg":
            let drawing = result as! CraftNativeSvgView
            let owner = current.protocolId ?? path
            svgOwners = svgOwners.filter { $0.value != owner }
            for child in children { registerSvgOwnership(child, owner: owner) }
            let previousBox = drawing.viewBox
            drawing.drawing = node
            if drawing.viewBox != previousBox { CraftNativeFlexLayout.invalidateAncestors(of: drawing) }
            current.children = []
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
            applyImageClipping(image, contentMode: image.contentMode, style: style)
            updateAuxiliaryHandler(events["onLoadStart"], in: &imageLoadStartHandlers, for: image)
            updateAuxiliaryHandler(events["onLoad"], in: &imageLoadHandlers, for: image)
            updateAuxiliaryHandler(events["onLoadEnd"], in: &imageLoadEndHandlers, for: image)
            updateAuxiliaryHandler(events["onError"], in: &imageErrorHandlers, for: image)
            updateImage(image, source: props["source"], defaultSource: props["defaultSource"])
        case "ImageBackground":
            let background = result as! CraftNativeImageBackgroundView
            let backgroundID = ObjectIdentifier(background)
            if let tint = color(style["tintColor"]) {
                tintedImages.insert(backgroundID)
                background.tintColor = tint
            } else {
                tintedImages.remove(backgroundID)
                background.tintColor = nil
            }
            if let current = background.image { background.image = imageForDisplay(current, view: background) }
            let requestedResizeMode = style["resizeMode"] as? String ?? props["resizeMode"] as? String
            background.contentMode = imageContentMode(requestedResizeMode)
            applyImageClipping(background, contentMode: background.contentMode, style: style)
            updateAuxiliaryHandler(events["onLoadStart"], in: &imageLoadStartHandlers, for: background)
            updateAuxiliaryHandler(events["onLoad"], in: &imageLoadHandlers, for: background)
            updateAuxiliaryHandler(events["onLoadEnd"], in: &imageLoadEndHandlers, for: background)
            updateAuxiliaryHandler(events["onError"], in: &imageErrorHandlers, for: background)
            updateImage(background, source: props["source"], defaultSource: props["defaultSource"])
            configureStack(background.contentStack, style: style)
            reconcileChildren(children, in: background.contentStack, parent: current, path: path, style: style)
        case "KeyboardAvoidingView":
            let keyboard = result as! CraftNativeKeyboardAvoidingView
            configureStack(keyboard, style: style)
            keyboard.configureKeyboard(props: props)
            reconcileChildren(children, in: keyboard, parent: current, path: path, style: style)
        case "Video":
            let video = result as! CraftNativeVideoView
            let autoplay = (props["autoplay"] as? Bool) == true || (props["autoPlay"] as? Bool) == true
            video.handlers = events
            video.emit = { [weak self] handler, nativeEvent in
                self?.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": nativeEvent])
            }
            video.configure(
                source: props["source"] ?? props["src"],
                autoplay: autoplay,
                paused: (props["paused"] as? Bool) == true,
                loop: (props["loop"] as? Bool) == true,
                muted: (props["muted"] as? Bool) == true,
                currentTime: props["currentTime"],
                controls: (props["controls"] as? Bool) == true,
                resizeMode: style["resizeMode"] as? String ?? props["resizeMode"] as? String,
                pictureInPicture: (props["pictureInPicture"] as? Bool) == true
            )
        case "Map":
            let map = result as! CraftNativeMapView
            let mapMarkerHandler = nonEmptyHandler(events["onMarkerPress"])
            map.onMapPress = { [weak self] coordinate in
                guard let self, let handler = self.nonEmptyHandler(events["onPress"]) else { return }
                self.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["latitude": coordinate.latitude, "longitude": coordinate.longitude]])
            }
            map.onRegionChangeComplete = { [weak self] region, heading, pitch in
                guard let self, let handler = self.nonEmptyHandler(events["onRegionChangeComplete"]) else { return }
                self.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [
                    "center": ["latitude": region.center.latitude, "longitude": region.center.longitude],
                    "span": ["latitudeDelta": region.span.latitudeDelta, "longitudeDelta": region.span.longitudeDelta],
                    "heading": heading, "pitch": pitch,
                ]])
            }
            map.configure(props: props, children: children) { [weak self, weak map] markerID in
                guard let self, let map,
                      let handler = map.markerHandlers[markerID] ?? mapMarkerHandler else { return }
                self.send(type: "EVENT", payload: [
                    "handlerName": handler,
                    "nativeEvent": ["id": markerID],
                ])
            }
        case "ScrollView", "SectionList":
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
            let pageHandler = nonEmptyHandler(events["onPageSelected"])
            scroll.configurePager(props["pageIndex"], onSelect: pageHandler.map { handler in
                { [weak self] index, count in self?.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["index": index, "count": count]]) }
            })
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
            let refreshNode = children.compactMap { $0 as? [String: Any] }.first {
                canonicalType($0["type"] as? String ?? "") == "RefreshControl"
            }
            let propRefresh = props["refreshControl"] as? [String: Any] ?? [:]
            let refreshProps = refreshNode?["props"] as? [String: Any] ?? propRefresh
            let refreshEvents = refreshNode?["events"] as? [String: String] ?? [:]
            let refreshHandlerName = nonEmptyHandler(refreshEvents["onRefresh"])
                ?? nonEmptyHandler(events["onRefresh"])
            let refreshing = (refreshProps["refreshing"] ?? props["refreshing"]) as? Bool == true
            scroll.setRefreshHandler(refreshHandlerName.map { [weak self] handler in
                { self?.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]]) }
            }, refreshing: refreshing)
            scroll.setRefreshAppearance(refreshProps)
            var contentStyle = style
            if let override = props["contentContainerStyle"] as? [String: Any] {
                contentStyle.merge(override) { _, next in next }
            }
            configureStack(scroll.contentStack, style: contentStyle)
            // Content-style defaults are vertical; the scroll host's explicit
            // axis must survive that shared container configuration without
            // resetting the authored bounce options applied above.
            scroll.setAxis(direction, resetBounce: false)
            reconcileChildren(children.filter {
                guard let child = $0 as? [String: Any] else { return true }
                return canonicalType(child["type"] as? String ?? "") != "RefreshControl"
            }, in: scroll.contentStack, parent: current, path: path, style: contentStyle)
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
        if type != "Button" && type != "Link" && type != "Checkbox" && type != "TextInput" && type != "Picker" && type != "SegmentedControl" && type != "DatePicker" && type != "Modal" && type != "Switch" && type != "Slider" && type != "ActivityIndicator" && type != "StatusBar" && type != "RefreshControl" && type != "Map" {
            let disabled = props["disabled"] as? Bool == true
            updatePressHandler(disabled ? nil : nonEmptyHandler(events["onPress"]) ?? nonEmptyHandler(events["onClick"]), for: result)
            updatePressFeedback(
                disabled ? nil : nonEmptyHandler(events["onPressIn"]),
                disabled ? nil : nonEmptyHandler(events["onPressOut"]),
                for: result
            )
            updateUnderlayHandlers(
                type == "TouchableHighlight" && !disabled ? nonEmptyHandler(events["onShowUnderlay"]) : nil,
                type == "TouchableHighlight" && !disabled ? nonEmptyHandler(events["onHideUnderlay"]) : nil,
                for: result
            )
            if disabled { result.isUserInteractionEnabled = false }
        }
        applyAccessibility(props, type: type, to: result)
        (result as? CraftNativeFlowView)?.configureCelebration(props["celebration"])
        return current
    }

    private func stopCelebrations(in root: UIView) {
        (root as? CraftNativeFlowView)?.celebration?.stop()
        root.subviews.forEach { stopCelebrations(in: $0) }
    }

    private func makeView(_ type: String, props: [String: Any]) -> UIView {
        switch type {
        case "Text":
            if props["selectable"] as? Bool == true {
                return CraftNativeSelectableTextView()
            }
            let label = CraftNativeLabel()
            label.numberOfLines = 0
            return label
        case "Button", "Link":
            let button = CraftNativeButton(type: .system)
            button.addTarget(self, action: #selector(buttonPressed(_:)), for: .touchUpInside)
            return button
        case "Checkbox":
            let checkbox = CraftNativeCheckboxButton(type: .system)
            checkbox.semanticContentAttribute = .forceLeftToRight
            checkbox.contentHorizontalAlignment = .leading
            checkbox.addTarget(self, action: #selector(checkboxPressed(_:)), for: .touchUpInside)
            return checkbox
        case "TextInput":
            if props["multiline"] as? Bool == true {
                let textView = CraftNativeTextView()
                textView.delegate = self
                return textView
            }
            let field = CraftNativeTextField()
            field.addTarget(self, action: #selector(textChanged(_:)), for: .editingChanged)
            field.addTarget(self, action: #selector(textFocused(_:)), for: .editingDidBegin)
            field.addTarget(self, action: #selector(textBlurred(_:)), for: .editingDidEnd)
            field.addTarget(self, action: #selector(textSubmitted(_:)), for: .editingDidEndOnExit)
            return field
        case "SegmentedControl":
            let control = CraftNativeSegmentedControl()
            control.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
            return control
        case "Picker":
            let picker = UIPickerView()
            picker.dataSource = self
            picker.delegate = self
            return picker
        case "DatePicker":
            let picker = UIDatePicker()
            picker.preferredDatePickerStyle = .compact
            picker.addTarget(self, action: #selector(datePicked(_:)), for: .valueChanged)
            return picker
        case "Modal":
            return CraftNativeModalView()
        case "Switch":
            if props["ios_solid"] as? Bool == true {
                let toggle = CraftNativeSolidSwitch()
                toggle.addTarget(self, action: #selector(solidSwitchChanged(_:)), for: .valueChanged)
                return toggle
            }
            let toggle = UISwitch()
            toggle.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
            return toggle
        case "Slider":
            let slider = UISlider()
            slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
            slider.addTarget(self, action: #selector(sliderFinished(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
            return slider
        case "ActivityIndicator":
            return CraftNativeActivityIndicatorView(style: .medium)
        case "StatusBar", "RefreshControl":
            return CraftNativeFlowView()
        case "Image":
            return UIImageView()
        case "ImageBackground":
            return CraftNativeImageBackgroundView(frame: .zero)
        case "KeyboardAvoidingView":
            return CraftNativeKeyboardAvoidingView()
        case "Video":
            return CraftNativeVideoView(host: self)
        case "Map":
            return CraftNativeMapView()
        case "Icon":
            let icon = CraftNativeIconView()
            icon.contentMode = .scaleAspectFit
            return icon
        case "ScrollView", "SectionList":
            return CraftNativeScrollView()
        case "FlatList":
            return CraftNativeFlatList()
        case "Svg":
            return CraftNativeSvgView()
        case "View":
            return CraftNativeFlowView()
        case "SafeAreaView":
            return CraftNativeSafeAreaView()
        case "TouchableOpacity", "TouchableHighlight", "Pressable":
            return CraftNativeFlowView()
        default:
            return CraftNativeFlowView()
        }
    }

    private func canonicalType(_ raw: String) -> String {
        switch raw.lowercased() {
        case "view": return "View"
        case "safeareaview": return "SafeAreaView"
        case "keyboardavoidingview": return "KeyboardAvoidingView"
        case "text": return "Text"
        case "button": return "Button"
        case "link": return "Link"
        case "checkbox": return "Checkbox"
        case "textinput", "input": return "TextInput"
        case "segmentedcontrol", "segmented-control": return "SegmentedControl"
        case "picker", "select": return "Picker"
        case "datepicker", "date-picker", "date": return "DatePicker"
        case "modal": return "Modal"
        case "switch": return "Switch"
        case "slider": return "Slider"
        case "activityindicator": return "ActivityIndicator"
        case "statusbar": return "StatusBar"
        case "refreshcontrol": return "RefreshControl"
        case "image": return "Image"
        case "imagebackground": return "ImageBackground"
        case "video": return "Video"
        case "map": return "Map"
        case "icon": return "Icon"
        case "scrollview": return "ScrollView"
        case "sectionlist": return "SectionList"
        case "flatlist": return "FlatList"
        case "svg": return "Svg"
        case "g": return "G"
        case "svgtext", "svg-text": return "SvgText"
        case "touchableopacity": return "TouchableOpacity"
        case "touchablehighlight": return "TouchableHighlight"
        case "pressable": return "Pressable"
        default: return raw
        }
    }

    private func explicitKey(_ node: [String: Any], props: [String: Any]) -> String? {
        if let authored = authoredKey(node, props: props) { return authored }
        // Repeated test selectors are valid for list rows. Retain each row by
        // its unique protocol ID before considering legacy selector identity.
        return [node["id"], props["testID"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty }
    }

    /// The key a node's author gave it. A wrapper of one child (a
    /// component's) is keyed by what it wraps, so a keyed row drawn through
    /// a component keeps its key. Never a key further down beside siblings:
    /// one an `:if` shows and hides (a Back button) changed the identity of
    /// everything above it, and the whole subtree was built again, a pager's
    /// scroll position with it.
    private func authoredKey(_ node: [String: Any], props: [String: Any]) -> String? {
        // The current @stacksjs/stx native compiler emits key in props; accept the IR
        // field too so keyed children keep working when the compiler adopts it.
        let direct = [node["key"], props["key"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty }
        if let direct { return direct }
        let children = node["children"] as? [Any] ?? []
        guard children.count == 1, let only = children.first as? [String: Any] else { return nil }
        return authoredKey(only, props: only["props"] as? [String: Any] ?? [:])
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
        // STX permits text directly inside containers (including HTML links).
        // Give it a native label, inheriting typography without duplicating
        // the parent's padding, dimensions or flex layout.
        let typography = style.filter { key, _ in
            key == "color" || key == "letterSpacing" || key == "lineHeight"
                || key.hasPrefix("font") || key.hasPrefix("text")
        }
        let nodes = children.compactMap { child -> [String: Any]? in
            if let node = child as? [String: Any] { return node }
            if let text = child as? String {
                return ["type": "Text", "style": typography, "children": [text]]
            }
            return nil
        }
        let keys = nodes.compactMap { explicitKey($0, props: $0["props"] as? [String: Any] ?? [:]) }
        let counts = Dictionary(keys.map { ($0, 1) }, uniquingKeysWith: +)
        let old = Dictionary(uniqueKeysWithValues: parent.children.map { ($0.identity, $0) })
        var next: [RenderedNode] = []

        for (index, node) in nodes.enumerated() {
            let key = explicitKey(node, props: node["props"] as? [String: Any] ?? [:])
            // Keys are local to a parent. Ambiguous sibling keys fall back to
            // position so a move never attaches the wrong live control.
            let localIdentity = key.flatMap { counts[$0] == 1 ? "key:\($0)" : nil } ?? "index:\(index)"
            // A keyed row can live in either FlatList or an ordinary
            // ScrollView. Scope its descendants to the row so two rows cannot
            // share an uncontrolled input draft or retained native handler.
            let identity = parent.identity.hasPrefix("list:") || parent.identity.hasPrefix("key:")
                ? "\(parent.identity)/\(localIdentity)"
                : localIdentity
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
            // A modal covers the screen, wherever it is declared. Laid over
            // its parent instead, one declared in a scroll view covered the
            // whole content: its controls sat wherever the content had
            // scrolled to, under the bar or off screen, out of reach.
            if modal.superview !== view {
                modal.removeFromSuperview()
                view.addSubview(modal)
            }
            modal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.bringSubviewToFront(modal)
        }
        positionModals()
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
        let propRefresh = props["refreshControl"] as? [String: Any] ?? [:]
        let propRefreshEvents = propRefresh["events"] as? [String: String] ?? [:]
        let refreshHandler = nonEmptyHandler(propRefreshEvents["onRefresh"])
            ?? nonEmptyHandler(events["onRefresh"])
        let refreshing = (propRefresh["refreshing"] ?? props["refreshing"]) as? Bool == true
        list.bounces = props["bounces"] as? Bool ?? true
        list.isScrollEnabled = props["scrollEnabled"] as? Bool != false
        list.onFittingHeightChanged = { [weak list] in
            guard let list else { return }
            CraftNativeFlexLayout.invalidateAncestors(of: list)
        }
        list.setKeyboardShouldPersistTaps(props["keyboardShouldPersistTaps"])
        list.setContentContainerStyle(props["contentContainerStyle"] as? [String: Any])
        list.setRefreshHandler(refreshHandler.map { [weak self] handler in
            { self?.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]]) }
        }, refreshing: refreshing)
        list.setRefreshAppearance(propRefresh)
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

        let threshold = max(
            0,
            Double(number(props["onEndReachedThreshold"]) ?? number(props["threshold"]) ?? 0.1)
        )
        list.apply(
            nodes: children,
            horizontal: props["horizontal"] as? Bool == true,
            columns: Int(number(props["numColumns"]) ?? 1),
            inverted: props["inverted"] as? Bool == true,
            endReachedThreshold: threshold,
            renderItem: { [weak self] node, identity, reusable in
                guard let self = self else { return UIView() }
                var previous = self.flatListRows[listKey]?[identity]
                // A cell scrolled back into use brings the views of the row it
                // showed: the new row reuses them when it has the same shape,
                // rather than building every view of it again in the frame it
                // scrolls in (Apple's view-churn hitch).
                var adopting = false
                if previous == nil, let reusable,
                   let recycled = self.flatListRecycled[listKey]?.removeValue(forKey: ObjectIdentifier(reusable)) {
                    previous = recycled
                    adopting = true
                }
                let next = self.reconcile(
                    node,
                    identity: "list:\(identity)",
                    path: "\(path).\(identity)",
                    previous: previous,
                    adopting: adopting
                )
                // A recycled row's handlers went when it was recycled.
                if let previous, previous.view !== next.view, !adopting {
                    self.forgetHandlers(previous)
                }
                self.flatListRows[listKey, default: [:]][identity] = next
                return next.view
            },
            recycleItem: { [weak self] identity in
                guard let self = self,
                      let row = self.flatListRows[listKey]?.removeValue(forKey: identity) else { return }
                self.forgetHandlers(row, preservingInputDrafts: true)
                // Kept, without its handlers, for the next row its cell shows.
                var recycled = self.flatListRecycled[listKey, default: [:]]
                if recycled.count >= 64, let oldest = recycled.keys.first { recycled.removeValue(forKey: oldest) }
                recycled[ObjectIdentifier(row.view)] = row
                self.flatListRecycled[listKey] = recycled
            },
            removeItem: { [weak self] identity in
                guard let self else { return }
                let scopedIdentity = "list:\(identity)"
                if let row = self.flatListRows[listKey]?.removeValue(forKey: identity) {
                    self.forgetHandlers(row)
                }
                guard var recycled = self.flatListRecycled[listKey] else { return }
                let staleViewIDs = recycled.compactMap { viewID, row in
                    row.identity == scopedIdentity ? viewID : nil
                }
                for viewID in staleViewIDs {
                    if let row = recycled.removeValue(forKey: viewID) { self.forgetHandlers(row) }
                }
                self.flatListRecycled[listKey] = recycled
            },
            endReached: nonEmptyHandler(events["onEndReached"]).map { [weak self] handler in
                { self?.send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]]) }
            }
        )
        let horizontal = props["horizontal"] as? Bool == true
        list.showsVerticalScrollIndicator = props["showsVerticalScrollIndicator"] as? Bool ?? true
        list.showsHorizontalScrollIndicator = props["showsHorizontalScrollIndicator"] as? Bool ?? true
        list.isPagingEnabled = props["pagingEnabled"] as? Bool ?? false
        list.setScrollTarget(props["scrollTarget"])
        list.alwaysBounceVertical = props["alwaysBounceVertical"] as? Bool ?? !horizontal
        list.alwaysBounceHorizontal = props["alwaysBounceHorizontal"] as? Bool ?? horizontal
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

    private func registerSvgOwnership(_ node: Any, owner: String) {
        guard let node = node as? [String: Any] else { return }
        if let id = node["id"] as? String, !id.isEmpty { svgOwners[id] = owner }
        for child in node["children"] as? [Any] ?? [] { registerSvgOwnership(child, owner: owner) }
    }

    private func detach(_ node: RenderedNode, from stack: CraftNativeFlowView) {
        let retainedByReparent = node.protocolId.map { adoptedPreviousProtocolIDs.contains($0) } == true
        if !retainedByReparent { forgetHandlers(node) }
        if node.type == "Modal" {
            if node.view.superview === stack { node.view.removeFromSuperview() }
            return
        }
        if node.view.superview === stack {
            stack.removeLayoutStyle(for: node.view)
            stack.removeArrangedSubview(node.view)
            node.view.removeFromSuperview()
        }
    }

    private func indexPreviousNodes(_ node: RenderedNode?) {
        guard let node else { return }
        if let id = node.protocolId, !id.isEmpty { previousNodesByProtocolID[id] = node }
        node.children.forEach { indexPreviousNodes($0) }
    }

    private func forgetHandlers(_ node: RenderedNode, preservingInputDrafts: Bool = false) {
        (node.view as? CraftNativeScrollView)?.setRefreshHandler(nil, refreshing: false)
        // Recycled list rows keep their native delegates and targets until
        // they are rebound. A permanently detached node must release those
        // UIKit hooks as well as the handler maps below, otherwise a picker,
        // text view, or control can still call back into this screen after
        // its subtree is gone.
        if !preservingInputDrafts {
            if let textView = node.view as? UITextView { textView.delegate = nil }
            if let picker = node.view as? UIPickerView {
                picker.delegate = nil
                picker.dataSource = nil
            }
            if let scroll = node.view as? UIScrollView { scroll.delegate = nil }
            (node.view as? UIControl)?.removeTarget(self, action: nil, for: .allEvents)
        }
        if let list = node.view as? CraftNativeFlatList {
            let listKey = ObjectIdentifier(list)
            list.setRefreshHandler(nil, refreshing: false)
            list.discardAll()
            if !preservingInputDrafts { list.resetForTeardown() }
            flatListRows.removeValue(forKey: listKey)
            if !preservingInputDrafts {
                flatListRecycled.removeValue(forKey: listKey)?.values.forEach { forgetHandlers($0) }
            } else {
                flatListRecycled.removeValue(forKey: listKey)
            }
            if let owner = node.protocolId { flatListOwners = flatListOwners.filter { $0.value != owner } }
        }
        if node.view is CraftNativeSvgView, let owner = node.protocolId { svgOwners = svgOwners.filter { $0.value != owner } }
        let id = ObjectIdentifier(node.view)
        if let modal = node.view as? CraftNativeModalView {
            modal.resetForTeardown()
            // It sits on the screen, not in its parent: leaving with the
            // parent's subtree does not take it away.
            modal.removeFromSuperview()
        }
        handlers.removeValue(forKey: id)
        linkTargets.removeValue(forKey: id)
        transitionIDs.removeValue(forKey: id)
        pressInHandlers.removeValue(forKey: id)
        pressOutHandlers.removeValue(forKey: id)
        underlayShowHandlers.removeValue(forKey: id)
        underlayHideHandlers.removeValue(forKey: id)
        layoutHandlers.removeValue(forKey: id)
        lastLayoutFrames.removeValue(forKey: id)
        focusHandlers.removeValue(forKey: id)
        blurHandlers.removeValue(forKey: id)
        endEditingHandlers.removeValue(forKey: id)
        submitHandlers.removeValue(forKey: id)
        inputIdentities.removeValue(forKey: id)
        unechoedText.removeValue(forKey: id)
        inputEventCounts.removeValue(forKey: id)
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
        authoredAccessibilityValues.remove(id)
        tintedImages.remove(id)
        imageLoadStartHandlers.removeValue(forKey: id)
        imageLoadHandlers.removeValue(forKey: id)
        imageLoadEndHandlers.removeValue(forKey: id)
        imageErrorHandlers.removeValue(forKey: id)
        checkboxIndeterminate.removeValue(forKey: id)
        switchUserValues.removeValue(forKey: id)
        if let video = node.view as? CraftNativeVideoView { video.stop() }
        if let map = node.view as? CraftNativeMapView { map.destroy() }
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

    private var layoutEventsScheduled = false

    /// UIView.frame is undefined while a transform is applied. onLayout is
    /// the authored layout in the parent coordinate space, matching Android's
    /// left/top/right/bottom values rather than the transformed visual bounds.
    private func layoutFrame(of view: UIView) -> CGRect {
        guard !view.transform.isIdentity else { return view.frame }
        return CGRect(
            x: view.center.x - view.bounds.width / 2,
            y: view.center.y - view.bounds.height / 2,
            width: view.bounds.width,
            height: view.bounds.height
        )
    }

    /// A view inside the screen moved: report onLayout once the pass that
    /// moved it is over, however deep it was.
    fileprivate func scheduleLayoutEvents() {
        guard !layoutEventsScheduled, !layoutHandlers.isEmpty else { return }
        layoutEventsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutEventsScheduled = false
            self.emitLayoutEvents()
        }
    }

    private func emitLayoutEvents(for node: RenderedNode) {
        let id = ObjectIdentifier(node.view)
        if let handler = layoutHandlers[id], isEffectivelyVisible(node.view) {
            let frame = layoutFrame(of: node.view)
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

    private func isEffectivelyVisible(_ view: UIView) -> Bool {
        guard view.window != nil, !view.isHidden else { return false }
        var ancestor = view.superview
        while let current = ancestor {
            if current.isHidden { return false }
            ancestor = current.superview
        }
        return true
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

    /// Views that take their own touches whatever handlers the screen gives
    /// them: native controls, a scroll view, a modal, and a video's controls (with
    /// interaction off, its play, scrubber and full screen never answered).
    /// A map and a wheel picker too: neither is a UIControl, so a map with no
    /// long-press handler - every map - was made non-interactive, and could
    /// not be panned, zoomed, or have a pin tapped; a picker could not be spun.
    private func ownsTouches(_ view: UIView) -> Bool {
        view is UIControl || view is UIScrollView || view is CraftNativeModalView || view is CraftNativeVideoView
            || view is MKMapView || view is UIPickerView
    }

    private func updatePressHandler(_ handler: String?, for view: UIView) {
        let id = ObjectIdentifier(view)
        let handler = handler?.isEmpty == false ? handler : nil
        updateHandler(handler, for: view)
        let actionable = handler != nil || linkTargets[id] != nil
        if actionable, tapRecognizers[id] == nil {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(viewPressed(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = CraftPressGestureDelegate.shared
            tapRecognizers[id] = recognizer
            view.addGestureRecognizer(recognizer)
        } else if !actionable, let recognizer = tapRecognizers.removeValue(forKey: id) {
            view.removeGestureRecognizer(recognizer)
        }
        // A container keeps receiving touches without a handler of its own,
        // or every control inside it (and the screen root) would be dead.
        if !ownsTouches(view) { view.isUserInteractionEnabled = actionable || longPressHandlers[id] != nil || view is CraftNativeFlowView }
    }

    private func updatePressFeedback(_ pressIn: String?, _ pressOut: String?, for view: UIView) {
        let id = ObjectIdentifier(view)
        if let pressIn, !pressIn.isEmpty { pressInHandlers[id] = pressIn } else { pressInHandlers.removeValue(forKey: id) }
        if let pressOut, !pressOut.isEmpty { pressOutHandlers[id] = pressOut } else { pressOutHandlers.removeValue(forKey: id) }
        let hasUnderlay = (view as? CraftNativeFlowView)?.pressUnderlayColor != nil
        guard pressInHandlers[id] != nil || pressOutHandlers[id] != nil || hasUnderlay else {
            if let recognizer = pressFeedbackRecognizers.removeValue(forKey: id) { view.removeGestureRecognizer(recognizer) }
            if let pressable = view as? CraftNativeFlowView { pressable.backgroundColor = pressable.pressBaseBackgroundColor }
            if !ownsTouches(view) { view.isUserInteractionEnabled = handlers[id] != nil || linkTargets[id] != nil || longPressHandlers[id] != nil || view is CraftNativeFlowView }
            return
        }
        if pressFeedbackRecognizers[id] == nil {
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(viewPressFeedback(_:)))
            recognizer.minimumPressDuration = 0
            recognizer.allowableMovement = 10
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = CraftPressFeedbackDelegate.shared
            pressFeedbackRecognizers[id] = recognizer
            view.addGestureRecognizer(recognizer)
        }
        if !ownsTouches(view) { view.isUserInteractionEnabled = true }
    }

    private func updateUnderlayHandlers(_ show: String?, _ hide: String?, for view: UIView) {
        let id = ObjectIdentifier(view)
        if let show, !show.isEmpty { underlayShowHandlers[id] = show } else { underlayShowHandlers.removeValue(forKey: id) }
        if let hide, !hide.isEmpty { underlayHideHandlers[id] = hide } else { underlayHideHandlers.removeValue(forKey: id) }
    }

    private func updateLongPressHandler(_ handler: String?, for view: UIView) {
        let id = ObjectIdentifier(view)
        if let handler, !handler.isEmpty {
            longPressHandlers[id] = handler
            if !ownsTouches(view) { view.isUserInteractionEnabled = true }
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
            if !ownsTouches(view) { view.isUserInteractionEnabled = handlers[id] != nil || linkTargets[id] != nil || view is CraftNativeFlowView }
        }
    }

    /// Legacy runtimes echo values without a revision. Keep their bounded
    /// history on either script thread; bridge delivery may still be delayed.
    private var unechoedText: [ObjectIdentifier: [String]] = [:]
    private var inputEventCounts: [ObjectIdentifier: Int] = [:]

    @discardableResult
    private func noteSentText(_ text: String, for view: UIView) -> Int {
        let id = ObjectIdentifier(view)
        let count = (inputEventCounts[id] ?? 0) + 1
        inputEventCounts[id] = count
        var sent = unechoedText[id] ?? []
        sent.append(text)
        if sent.count > 32 { sent.removeFirst(sent.count - 32) }
        unechoedText[id] = sent
        return count
    }

    /// Whether `value` is a stale echo of text the view has moved past: it
    /// matches text sent before the latest. Text the field never sent is the
    /// script's own value (a field cleared after sending) and applies.
    private func isStaleEcho(_ value: String, for view: UIView) -> Bool {
        let id = ObjectIdentifier(view)
        guard var sent = unechoedText[id], let index = sent.lastIndex(of: value) else {
            unechoedText[id] = nil
            return false
        }
        let later = sent.count - index - 1
        sent.removeFirst(index + 1)
        unechoedText[id] = sent.isEmpty ? nil : sent
        return later > 0
    }

    private func acceptsText(_ value: String, for view: UIView, acknowledged: Int?) -> Bool {
        if let acknowledged, acknowledged >= 0 {
            guard acknowledged >= (inputEventCounts[ObjectIdentifier(view)] ?? 0) else { return false }
            unechoedText.removeValue(forKey: ObjectIdentifier(view))
            return true // A current explicit reset may equal an older edit.
        }
        return !isStaleEcho(value, for: view)
    }

    private func updateField(_ field: UITextField, value: String?, acknowledged: Int? = nil) {
        guard let value = value, field.markedTextRange == nil else { return }
        if !acceptsText(value, for: field, acknowledged: acknowledged) || field.text == value { return }
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

    private func updateTextView(_ textView: UITextView, value: String?, acknowledged: Int? = nil) {
        guard let value = value, textView.markedTextRange == nil else { return }
        if !acceptsText(value, for: textView, acknowledged: acknowledged) || textView.text == value { return }
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
        // UIKit owns marked text until the keyboard commits it. Reapplying
        // typography or input traits during composition can commit that draft.
        if textView.markedTextRange == nil {
            textView.textColor = color(style["color"]) ?? .label
            textView.font = textFont(style, default: .systemFont(ofSize: 16))
            textView.textAlignment = textAlignment(style["textAlign"])
            textView.tintColor = color(props["selectionColor"])
            textView.keyboardType = keyboardType(props["keyboardType"])
            textView.returnKeyType = returnKeyType(props["returnKeyType"])
            textView.autocorrectionType = props["autoCorrect"] as? Bool == false ? .no : .default
            textView.autocapitalizationType = capitalizationType(props["autoCapitalize"])
            textView.isSecureTextEntry = props["secureTextEntry"] as? Bool == true
            applyAutofill(to: textView, props: props)
        }
        textView.isEditable = props["editable"] as? Bool != false
        // The style's padding is where the text starts, as in a web textarea.
        let padding = paddingInsets(style)
        if let craftTextView = textView as? CraftNativeTextView {
            craftTextView.applyAuthoredPadding(padding)
        } else if padding != .zero {
            if textView.textContainerInset != padding { textView.textContainerInset = padding }
            textView.textContainer.lineFragmentPadding = 0
        }
        // An input's own scrolling follows its height (CraftNativeTextView).
        if !(textView is CraftNativeTextView) { textView.isScrollEnabled = false }
        let numberOfLines = Int(number(props["numberOfLines"]) ?? 0)
        if numberOfLines > 0 {
            textView.textContainer.maximumNumberOfLines = numberOfLines
        } else {
            textView.textContainer.maximumNumberOfLines = 0
        }
        let maxLength = Int(number(props["maxLength"]) ?? 0)
        if maxLength > 0 {
            textMaxLengths[id] = maxLength
        } else {
            textMaxLengths.removeValue(forKey: id)
        }
        if let craftTextView = textView as? CraftNativeTextView {
            craftTextView.placeholder = props["placeholder"] as? String
            craftTextView.placeholderColor = color(props["placeholderTextColor"])
            craftTextView.placeholderFont = textView.font
        }
        updateTextView(textView, value: (props["value"] as? String) ?? defaultValue, acknowledged: (props["mostRecentEventCount"] as? NSNumber)?.intValue)
        if textView.markedTextRange == nil {
            let attributes = inputTextAttributes(style, font: textView.font ?? .systemFont(ofSize: 16), alignment: textView.textAlignment)
            let styled = NSAttributedString(string: textView.text ?? "", attributes: attributes)
            if !textView.text.isEmpty, textView.attributedText?.isEqual(to: styled) != true {
                let selectedRange = textView.selectedRange
                textView.attributedText = styled
                textView.selectedRange = selectedRange
            }
            if !(textView.typingAttributes as NSDictionary).isEqual(attributes as NSDictionary) {
                textView.typingAttributes = attributes
            }
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
        switch craftNativeFontWeight(style["fontWeight"]) {
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
        stack.reverse = direction?.hasSuffix("-reverse") == true
        let flexWrap = style["flexWrap"] as? String
        stack.wrap = flexWrap == "wrap" || flexWrap == "wrap-reverse" || style["flexWrap"] as? Bool == true
        stack.wrapReverse = flexWrap == "wrap-reverse"
        stack.alignItems = style["alignItems"] as? String ?? "stretch"
        stack.alignContent = style["alignContent"] as? String ?? "flex-start"
        stack.justifyContent = style["justifyContent"] as? String ?? "flex-start"
        let gap = max(0, number(style["gap"]) ?? 0)
        stack.gap = gap
        stack.rowGap = max(0, number(style["rowGap"]) ?? gap)
        stack.columnGap = max(0, number(style["columnGap"]) ?? gap)
        stack.grid = style["display"] as? String == "grid"
        stack.gridColumns = craftNativeGridColumnCount(style["gridTemplateColumns"] ?? style["gridColumns"])
        stack.gridRows = craftNativeGridRowCount(style["gridTemplateRows"])
        stack.gridAutoRows = CraftNativeLength(style["gridAutoRows"])
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
        // Every flow container can receive press feedback, including ordinary
        // Views. Capture its current authored fill before feedback cleanup or
        // release restores it; otherwise avatars and button wrappers go clear.
        (view as? CraftNativeFlowView)?.pressBaseBackgroundColor = view.backgroundColor
        // A field the style dresses itself (`border-0`, a border or a
        // background, as a search field inside its own pill is) draws no
        // system box of its own; a bare one keeps the rounded rectangle.
        if let field = view as? UITextField {
            field.borderStyle = style["borderWidth"] != nil || style["backgroundColor"] != nil ? .none : .roundedRect
        }
        CraftNativeGradientLayer.apply(
            to: view,
            direction: style["gradientDirection"] as? String,
            colors: [color(style["gradientFrom"]), color(style["gradientVia"]), color(style["gradientTo"])]
        )
        view.alpha = number(style["opacity"]) ?? 1
        view.isHidden = style["display"] as? String == "none"
        let borderRadius = number(style["borderRadius"]) ?? 0
        let cornerRadiusKeys = ["borderTopLeftRadius", "borderTopRightRadius", "borderBottomRightRadius", "borderBottomLeftRadius"]
        let hasCornerRadii = cornerRadiusKeys.contains { style[$0] != nil }
        view.craftRequestedCornerRadius = borderRadius
        view.craftRequestedCornerRadii = hasCornerRadii
            ? cornerRadiusKeys.map { number(style[$0]) ?? borderRadius }
            : nil
        let borderWidth = number(style["borderWidth"]) ?? 0
        let borderColor = color(style["borderColor"]) ?? .clear
        let sideWidthKeys = ["borderTopWidth", "borderRightWidth", "borderBottomWidth", "borderLeftWidth"]
        let sideColorKeys = ["borderTopColor", "borderRightColor", "borderBottomColor", "borderLeftColor"]
        view.craftApplySideBorders(
            (sideWidthKeys + sideColorKeys).contains { style[$0] != nil },
            style: style["borderStyle"] as? String,
            widths: sideWidthKeys.map { number(style[$0]) ?? borderWidth },
            colors: sideColorKeys.map { color(style[$0]) ?? borderColor }
        )
        view.layer.zPosition = number(style["zIndex"]) ?? 0
        applyTransform(style["transform"], to: view)
        let elevation = max(0, number(style["elevation"]) ?? 0)
        let shadowColor = color(style["shadowColor"]) ?? .black
        let shadowOpacity = min(1, max(0, number(style["shadowOpacity"]) ?? (elevation > 0 ? min(0.28, 0.12 + elevation * 0.02) : 0)))
        let shadowRadius = max(0, number(style["shadowRadius"]) ?? elevation * 0.5)
        let shadowOffset = style["shadowOffset"] as? [String: Any]
        view.layer.shadowColor = shadowColor.cgColor
        view.layer.shadowOpacity = Float(shadowOpacity)
        view.layer.shadowRadius = shadowRadius
        view.layer.shadowOffset = CGSize(
            width: number(shadowOffset?["width"]) ?? 0,
            height: number(shadowOffset?["height"]) ?? (elevation * 0.25)
        )
        // A label paints its background inside its own bounds, so a rounded
        // chip of text clips to its corners.
        // Native scrollers clip their viewport unless explicitly made
        // visible. trackContentScrollView opens only the leading scroller
        // beneath the screen's floating chrome.
        let overflow = style["overflow"] as? String
        view.clipsToBounds = overflow == "hidden"
            || (view is UIScrollView && overflow != "visible")
            || (view is UILabel && (view.craftRequestedCornerRadius ?? 0) > 0)
            || (view is UIImageView && (borderRadius > 0 || hasCornerRadii))
            // Per-corner rounding clips its content, as its mask did.
            || hasCornerRadii
        view.layer.masksToBounds = view.clipsToBounds
        view.craftLayoutStyle = CraftNativeLayoutStyle(style)
        (view as? CraftNativeFlowView)?.invalidateMeasurements()
        (view as? CraftNativeScrollView)?.setContentNeedsLayout()
    }

    private func paddingInsets(_ style: [String: Any]) -> UIEdgeInsets {
        func nonNegative(_ value: Any?) -> CGFloat? {
            guard let value = number(value), value >= 0 else { return nil }
            return value
        }
        let padding = nonNegative(style["padding"]) ?? 0
        let horizontal = nonNegative(style["paddingHorizontal"]) ?? padding
        let vertical = nonNegative(style["paddingVertical"]) ?? padding
        return UIEdgeInsets(
            top: nonNegative(style["paddingTop"]) ?? vertical,
            left: nonNegative(style["paddingLeft"]) ?? horizontal,
            bottom: nonNegative(style["paddingBottom"]) ?? vertical,
            right: nonNegative(style["paddingRight"]) ?? horizontal
        )
    }

    private func applyTransform(_ raw: Any?, to view: UIView) {
        let intrinsicScale = (view as? CraftNativeActivityIndicatorView)?.indicatorScale ?? 1
        view.layer.transform = CATransform3DIdentity
        view.transform = CGAffineTransform(scaleX: intrinsicScale, y: intrinsicScale)
        guard let transforms = raw as? [[String: Any]] else { return }
        var affine = CGAffineTransform.identity
        var threeDimensional = CATransform3DIdentity
        var hasThreeDimensionalRotation = false
        for transform in transforms {
            if let value = number(transform["translateX"]) { affine = affine.translatedBy(x: value, y: 0) }
            if let value = number(transform["translateY"]) { affine = affine.translatedBy(x: 0, y: value) }
            if let value = number(transform["scale"]) { affine = affine.scaledBy(x: value, y: value) }
            if let value = number(transform["scaleX"]) { affine = affine.scaledBy(x: value, y: 1) }
            if let value = number(transform["scaleY"]) { affine = affine.scaledBy(x: 1, y: value) }
            if let value = transformAngle(transform["rotate"] ?? transform["rotateZ"]) { affine = affine.rotated(by: value) }
            if let value = transformAngle(transform["skewX"]) { affine = affine.concatenating(CGAffineTransform(a: 1, b: 0, c: tan(value), d: 1, tx: 0, ty: 0)) }
            if let value = transformAngle(transform["skewY"]) { affine = affine.concatenating(CGAffineTransform(a: 1, b: tan(value), c: 0, d: 1, tx: 0, ty: 0)) }
            if let value = transformAngle(transform["rotateX"]) {
                threeDimensional = CATransform3DRotate(threeDimensional, value, 1, 0, 0)
                hasThreeDimensionalRotation = true
            }
            if let value = transformAngle(transform["rotateY"]) {
                threeDimensional = CATransform3DRotate(threeDimensional, value, 0, 1, 0)
                hasThreeDimensionalRotation = true
            }
        }
        affine = affine.scaledBy(x: intrinsicScale, y: intrinsicScale)
        if hasThreeDimensionalRotation {
            view.layer.transform = CATransform3DConcat(CATransform3DMakeAffineTransform(affine), threeDimensional)
        } else {
            view.transform = affine
        }
    }

    private func transformAngle(_ raw: Any?) -> CGFloat? {
        if let value = number(raw) { return value }
        guard let text = raw as? String else { return nil }
        if text.hasSuffix("rad") { return CGFloat(Double(text.dropLast(3)) ?? 0) }
        if text.hasSuffix("deg") { return CGFloat((Double(text.dropLast(3)) ?? 0) * .pi / 180) }
        // Keep the conversion explicit: newer Swift toolchains see both the
        // CGFloat(Double) and CGFloat(Float) initializers through map and
        // reject the overloaded constructor reference.
        return Double(text).map { CGFloat($0) }
    }

    private func configureText(_ label: UILabel, text: String, style: [String: Any]) {
        let transformed = transformedText(text, style: style)
        label.textColor = color(style["color"]) ?? .label
        label.font = textFont(style, default: .systemFont(ofSize: 16))
        label.textAlignment = textAlignment(style["textAlign"])
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let spacing = number(style["letterSpacing"]) { attributes[.kern] = spacing }
        addTextDecorationAttributes(style, to: &attributes)
        if let shadow = textShadow(style) { attributes[.shadow] = shadow }
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

    private func configureSelectableText(_ textView: UITextView, text: String, style: [String: Any]) {
        let label = CraftNativeLabel()
        label.numberOfLines = 0
        configureText(label, text: text, style: style)
        textView.attributedText = label.attributedText
        if label.attributedText == nil { textView.text = label.text }
        textView.font = label.font
        textView.textColor = label.textColor
        textView.textAlignment = label.textAlignment
        textView.textContainerInset = paddingInsets(style)
        textView.textContainer.lineFragmentPadding = 0
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
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
        addTextDecorationAttributes(style, to: &attributes)
        if let shadow = textShadow(style) { attributes[.shadow] = shadow }
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
        // UIKit otherwise resets the field's alignment to natural when these attributes are applied.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        if let lineHeight = number(style["lineHeight"]) {
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
        }
        attributes[.paragraphStyle] = paragraph
        addTextDecorationAttributes(style, to: &attributes)
        if let shadow = textShadow(style) { attributes[.shadow] = shadow }
        return attributes
    }

    private func textShadow(_ style: [String: Any]) -> NSShadow? {
        guard let shadowColor = color(style["textShadowColor"]) else { return nil }
        let offset = style["textShadowOffset"] as? [String: Any]
        let shadow = NSShadow()
        shadow.shadowColor = shadowColor
        shadow.shadowOffset = CGSize(
            width: number(offset?["width"]) ?? 0,
            height: number(offset?["height"]) ?? 0
        )
        shadow.shadowBlurRadius = max(0, number(style["textShadowRadius"]) ?? 0)
        return shadow
    }

    private func addTextDecorationAttributes(_ style: [String: Any], to attributes: inout [NSAttributedString.Key: Any]) {
        let line = style["textDecorationLine"] as? String
        let decorationStyle: NSUnderlineStyle = {
            switch style["textDecorationStyle"] as? String {
            case "double": return .double
            case "dotted": return [.single, .patternDot]
            case "dashed": return [.single, .patternDash]
            default: return .single
            }
        }()
        let rawStyle = decorationStyle.rawValue
        let decorationColor = color(style["textDecorationColor"])
        if line == "underline" || line == "underline line-through" {
            attributes[.underlineStyle] = rawStyle
            if let decorationColor { attributes[.underlineColor] = decorationColor }
        }
        if line == "line-through" || line == "underline line-through" {
            attributes[.strikethroughStyle] = rawStyle
            if let decorationColor { attributes[.strikethroughColor] = decorationColor }
        }
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
        switch craftNativeFontWeight(style["fontWeight"]) {
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
        // Android's TextView uses SP, so its native text scales with the
        // user's content-size setting. Apply the same Dynamic Type multiplier
        // here before assigning the font to labels, buttons, and inputs.
        let scaledSize = UIFontMetrics(forTextStyle: .body).scaledValue(
            for: size,
            compatibleWith: traitCollection
        )
        let families = (style["fontFamily"] as? String ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        let selectedFont = families.lazy.compactMap { family -> UIFont? in
            switch family.lowercased() {
            case "monospace", "ui-monospace": return .monospacedSystemFont(ofSize: scaledSize, weight: weight)
            case "serif", "ui-serif":
                let system = UIFont.systemFont(ofSize: scaledSize, weight: weight)
                return system.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: scaledSize) }
            case "sans-serif", "ui-sans-serif", "system-ui", "-apple-system": return .systemFont(ofSize: scaledSize, weight: weight)
            default:
                guard let custom = UIFont(name: family, size: scaledSize) else { return nil }
                let weighted = custom.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]])
                var traits = custom.fontDescriptor.symbolicTraits
                if weight >= .semibold { traits.insert(.traitBold) } else { traits.remove(.traitBold) }
                let descriptor = weighted.withSymbolicTraits(traits) ?? weighted
                return UIFont(descriptor: descriptor, size: scaledSize)
            }
        }.first
        var font = selectedFont ?? .systemFont(ofSize: scaledSize, weight: weight)
        if style["fontStyle"] as? String == "italic",
           let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            font = UIFont(descriptor: descriptor, size: scaledSize)
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

    /// Downloaded images, decoded, for every screen: a screen opened again or
    /// a row scrolled back draws its picture in its first frame rather than
    /// fetching and decoding it again. Bounded by decoded bytes.
    private static let decodedImages: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 << 20
        return cache
    }()

    /// The pixels a picture is drawn at, when its style fixes its size (a
    /// 40-point avatar, a card's photo): nil otherwise, for a picture whose
    /// own size lays it out, which must keep its full size.
    static func displayPixels(of view: UIImageView) -> (size: CGSize, scale: CGFloat)? {
        let style = view.craftLayoutStyle
        let points: CGSize
        switch (style.width, style.height, style.aspectRatio) {
        case (.points(let width)?, .points(let height)?, _):
            points = CGSize(width: width, height: height)
        case (.points(let width)?, nil, let ratio?):
            points = CGSize(width: width, height: width / ratio)
        case (nil, .points(let height)?, let ratio?):
            points = CGSize(width: height * ratio, height: height)
        default:
            // Sized by its parent (a percentage, a stretch): its laid-out size.
            guard style.width != nil || style.height != nil || style.aspectRatio != nil,
                  view.bounds.width >= 1, view.bounds.height >= 1 else { return nil }
            points = view.bounds.size
        }
        guard points.width >= 1, points.height >= 1 else { return nil }
        let scale = max(1, view.window?.screen.scale ?? view.traitCollection.displayScale)
        return (CGSize(width: ceil(points.width * scale), height: ceil(points.height * scale)), scale)
    }

    /// Off the main thread: an image decoded at no more pixels than it is
    /// drawn at, by ImageIO's thumbnailer (Apple's downsampling recipe), so a
    /// 4000-pixel photo in a 40-point circle is never decoded whole; else
    /// decoded whole, ahead of its first draw.
    static func decodeImage(_ data: Data, fitting target: (size: CGSize, scale: CGFloat)?, fill: Bool) -> UIImage? {
        if let target,
           let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber).map({ CGFloat(truncating: $0) }),
           let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber).map({ CGFloat(truncating: $0) }),
           rawWidth > 0, rawHeight > 0 {
            // EXIF orientations 5–8 turn the picture a quarter.
            let turned = ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5
            let width = turned ? rawHeight : rawWidth
            let height = turned ? rawWidth : rawHeight
            let pixels = target.size
            let factor = fill ? max(pixels.width / width, pixels.height / height) : min(pixels.width / width, pixels.height / height)
            if factor < 1 {
                let options = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: ceil(max(width, height) * factor),
                ] as CFDictionary
                if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) {
                    // At the screen's scale, so its size in points is the
                    // size it is drawn at.
                    return UIImage(cgImage: image, scale: target.scale, orientation: .up)
                }
            }
        }
        return UIImage(data: data).map { $0.preparingForDisplay() ?? $0 }
    }

    /// An image the screen downloads: https anywhere, and http only from this
    /// machine (localhost, 127.0.0.1, ::1, *.localhost), the development
    /// server the app's ATS exception already allows. Internal for XCTest.
    static func loadsImage(from url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        if scheme == "https" { return true }
        guard scheme == "http", let host = url.host?.lowercased() else { return false }
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        return ["localhost", "127.0.0.1", "::1"].contains(bare) || bare.hasSuffix(".localhost")
    }

    /// Native screens have no document URL to resolve a path against. A
    /// leading slash is an app URL (for example `/api/avatar`), while a bare
    /// name remains a bundled asset for backwards compatibility.
    private func imageURL(for uri: String) -> URL? {
        let candidate: URL?
        if uri.hasPrefix("/") {
            guard let base = config.devServerURL.flatMap(URL.init(string:)) else { return nil }
            candidate = URL(string: uri, relativeTo: base)?.absoluteURL
        } else {
            candidate = URL(string: uri)
        }
        guard let candidate, Self.loadsImage(from: candidate) else { return nil }
        return candidate
    }

    private func applyImageClipping(_ view: UIImageView, contentMode: UIView.ContentMode, style: [String: Any]) {
        let authored = (style["overflow"] as? String) == "hidden"
            || (view.craftRequestedCornerRadius ?? 0) > 0
            || view.craftRequestedCornerRadii != nil
        let clips = authored || contentMode == .scaleAspectFill
        view.clipsToBounds = clips
        view.layer.masksToBounds = clips
    }

    private func updateImage(_ view: UIImageView, source: Any?, defaultSource: Any? = nil) {
        let sourceObject = source as? [String: Any]
        let uri = (source as? String) ?? sourceObject?["uri"] as? String
        let headers = (sourceObject?["headers"] as? [String: Any])?.reduce(into: [String: String]()) { result, entry in
            if let value = entry.value as? String { result[entry.key] = value }
        } ?? [:]
        let requestKey = uri.map { value in
            value + "\u{0}" + headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{0}")
        }
        let id = ObjectIdentifier(view)
        guard let uri, !uri.isEmpty else {
            if imageSources[id] == "" { return }
            imageTasks.removeValue(forKey: id)?.cancel()
            imageSources[id] = ""
            imageFailure(view, uri: nil, message: "Image source is missing")
            return
        }
        guard let requestKey, imageSources[id] != requestKey else { return }
        imageTasks.removeValue(forKey: id)?.cancel()
        imageSources[id] = requestKey
        imageErrors.removeValue(forKey: id)
        view.image = immediateImage(defaultSource).map { imageForDisplay($0, view: view) }
        imageDidChange(view)
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
            imageDidChange(view)
            emitImageEvent(view, handler: imageLoadHandlers[id])
            emitImageEvent(view, handler: imageLoadEndHandlers[id])
            return
        }
        if let url = imageURL(for: uri) {
            // Decoded at the size it is drawn, when the style fixes that size.
            let pixels = Self.displayPixels(of: view)
            let fill = view.contentMode == .scaleAspectFill
            // media.keep owns private/offline copies keyed by the authored URL.
            // Read before the decoded/network cache, without retaining private
            // pixels there after the app clears its media on sign-out.
            if let local = CraftNativeMedia.local(uri) {
                DispatchQueue.global(qos: .userInitiated).async { [weak self, weak view] in
                    let decoded = (try? Data(contentsOf: local)).flatMap { Self.decodeImage($0, fitting: pixels, fill: fill) }
                    DispatchQueue.main.async { [weak self, weak view] in
                        guard let self, let view, self.imageSources[ObjectIdentifier(view)] == requestKey else { return }
                        guard let image = decoded, CraftNativeMedia.local(uri) == local else {
                            self.imageFailure(view, uri: uri, message: "Kept image is unavailable or invalid")
                            return
                        }
                        view.image = self.imageForDisplay(image, view: view)
                        self.imageDidChange(view)
                        self.emitImageEvent(view, handler: self.imageLoadHandlers[ObjectIdentifier(view)])
                        self.emitImageEvent(view, handler: self.imageLoadEndHandlers[ObjectIdentifier(view)])
                    }
                }
                return
            }
            let cacheKey = pixels.map { "\(requestKey)@\(Int($0.size.width))x\(Int($0.size.height))\(fill ? "f" : "")" } ?? requestKey
            // Shown before: on screen in this same frame, already decoded.
            if let decoded = Self.decodedImages.object(forKey: cacheKey as NSString) {
                view.image = imageForDisplay(decoded, view: view)
                imageDidChange(view)
                emitImageEvent(view, handler: imageLoadHandlers[id])
                emitImageEvent(view, handler: imageLoadEndHandlers[id])
                return
            }
            var request = URLRequest(url: url)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let task = URLSession.shared.dataTask(with: request) { [weak self, weak view] data, _, _ in
                // Decoded here, off the main thread. A UIImage made from data
                // is only decoded when it first draws, on the main thread, in
                // the frame it scrolls into view: Apple's "prepare" hitch.
                let decoded = data.flatMap { Self.decodeImage($0, fitting: pixels, fill: fill) }
                if let decoded {
                    let bytes = decoded.size.width * decoded.scale * decoded.size.height * decoded.scale * 4
                    Self.decodedImages.setObject(decoded, forKey: cacheKey as NSString, cost: Int(bytes))
                }
                guard let self, let view else { return }
                DispatchQueue.main.async {
                    guard self.imageSources[ObjectIdentifier(view)] == requestKey else { return }
                    self.imageTasks.removeValue(forKey: ObjectIdentifier(view))
                    guard let image = decoded else {
                        self.imageFailure(view, uri: uri, message: "Image download failed")
                        return
                    }
                    view.image = self.imageForDisplay(image, view: view)
                    self.imageDidChange(view)
                    self.emitImageEvent(view, handler: self.imageLoadHandlers[ObjectIdentifier(view)])
                    self.emitImageEvent(view, handler: self.imageLoadEndHandlers[ObjectIdentifier(view)])
                }
            }
            imageTasks[id] = task
            task.resume()
            return
        }
        if uri.hasPrefix("/") {
            imageFailure(view, uri: uri, message: "Relative image source requires devServerURL")
            return
        }
        if !uri.contains(":") {
            guard let image = UIImage(named: uri) else {
                imageFailure(view, uri: uri, message: "Bundled image was not found")
                return
            }
            view.image = imageForDisplay(image, view: view)
            imageDidChange(view)
            emitImageEvent(view, handler: imageLoadHandlers[id])
            emitImageEvent(view, handler: imageLoadEndHandlers[id])
            return
        }
        imageFailure(view, uri: uri, message: "Unsupported image source")
    }

    /// `defaultSource` is intentionally local-only: data and bundled assets
    /// can be shown before a network image arrives without starting another
    /// request or bypassing the source's URL policy.
    private func immediateImage(_ source: Any?) -> UIImage? {
        let uri = (source as? String) ?? (source as? [String: Any])?["uri"] as? String
        guard let uri, !uri.isEmpty else { return nil }
        if uri.hasPrefix("data:image/"),
           let comma = uri.firstIndex(of: ","),
           let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) {
            return UIImage(data: data)
        }
        return !uri.contains(":") ? UIImage(named: uri) : nil
    }

    private func imageFailure(_ view: UIImageView, uri: String?, message: String) {
        imageErrors[ObjectIdentifier(view)] = message
        view.image = nil
        imageDidChange(view)
        view.accessibilityValue = message
        let id = ObjectIdentifier(view)
        emitImageEvent(view, handler: imageErrorHandlers[id], nativeEvent: ["error": ["message": message]])
        emitImageEvent(view, handler: imageLoadEndHandlers[id])
        NSLog("[craft native] %@: %@", message, uri ?? "<missing>")
    }

    private func imageDidChange(_ view: UIImageView) {
        view.invalidateIntrinsicContentSize()
        CraftNativeFlexLayout.invalidateAncestors(of: view)
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
        let id = ObjectIdentifier(view)
        view.accessibilityLabel = (props["accessibilityLabel"] as? String)
            ?? ((type == "Image" || type == "ImageBackground") ? props["alt"] as? String : nil)
        view.accessibilityHint = props["accessibilityHint"] as? String
        if let value = props["accessibilityValue"] {
            view.accessibilityValue = (value as? String) ?? (value as? NSNumber)?.stringValue
            authoredAccessibilityValues.insert(id)
        } else if authoredAccessibilityValues.remove(id) != nil {
            // Clearing an authored value lets UIKit expose the field's live
            // value again (particularly important for TextInput).
            view.accessibilityValue = nil
        } else if type != "TextInput" {
            view.accessibilityValue = nil
        }
        let hasLinkTarget = ["href", "to"].contains { !(props[$0] as? String ?? "").isEmpty }
        let linkedControl = ["Link", "TouchableOpacity", "TouchableHighlight", "Pressable"].contains(type) && hasLinkTarget
        let touchable = ["TouchableOpacity", "TouchableHighlight", "Pressable"].contains(type)
        let role = (props["accessibilityRole"] as? String)
            ?? (linkedControl ? "link" : touchable ? "button" : ["FlatList", "SectionList"].contains(type) ? "list" : nil)
        // A scroll view, a list or a group of controls holds what VoiceOver
        // reads: its label names the group, as a tab strip or a pager's
        // name, and never stands in for its content. As an element of its
        // own, a labelled pager hid every page from VoiceOver.
        // A video with its system controls is a group too: VoiceOver reaches
        // play, the scrubber, skipping and full screen inside it.
        let controlledVideo = type == "Video" && (props["controls"] as? Bool) == true
        // UIPickerView exposes adjustable component wheels. Making the
        // picker itself a leaf hides those wheels and their selected values.
        let container = ["ScrollView", "FlatList", "SectionList", "Picker", "SegmentedControl", "Modal", "Drawer"].contains(type)
            || ["tablist", "radiogroup", "list", "menu", "menubar", "toolbar"].contains(role ?? "")
            || controlledVideo
        view.isAccessibilityElement = !container && role != "none" && (view.accessibilityLabel != nil || role != nil || ["Text", "Button", "Link", "Checkbox", "Image", "ImageBackground", "Video", "TextInput", "Picker", "DatePicker", "Switch", "Slider"].contains(type))
        view.accessibilityContainerType = container && (view.accessibilityLabel != nil || controlledVideo) ? .semanticGroup : .none
        // Keep the interaction trait native controls expose. Rebuilding this
        // set from the STX role alone otherwise turns a Slider, Picker,
        // DatePicker, or Switch into a static VoiceOver item whenever the
        // screen omits redundant accessibility metadata.
        var traits: UIAccessibilityTraits = []
        switch type {
        case "Slider", "DatePicker": traits.insert(.adjustable)
        default: break
        }
        switch role ?? type.lowercased() {
        case "tablist": traits.insert(.tabBar)
        case "button", "checkbox": traits.insert(.button)
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
        // A disabled Pressable or touchable takes no touches; it says so too.
        if props["disabled"] as? Bool == true { traits.insert(.notEnabled) }
        if type == "Checkbox", let checkbox = view as? CraftNativeCheckboxButton {
            if checkbox.isSelected { traits.insert(.selected) }
            view.accessibilityValue = checkbox.indeterminate ? "mixed" : checkbox.isSelected ? "checked" : "unchecked"
        }
        if (type == "Image" || type == "ImageBackground"), let message = imageErrors[ObjectIdentifier(view)] {
            let current = view.accessibilityValue
            if current?.contains(message) != true {
                view.accessibilityValue = [current, message].compactMap { $0 }.joined(separator: ", ")
            }
        }
        // A multiline TextInput is a UITextView, which works out its traits
        // as it goes: while it has the keyboard they say it is editing, and
        // that is what UI tests and VoiceOver read focus from. Setting them
        // froze them, so it read as static text that never had focus ("neither
        // element nor any descendant has keyboard focus"); it keeps its own.
        // UISwitch also owns its native identity and enabled/on state.
        // Assigning .button changes its legacy AX type into a button while
        // modern XCTest still identifies its UIKit class as a switch.
        if view is UITextView || view is UISwitch { return }
        if let toggle = view as? CraftNativeSolidSwitch { toggle.refreshAccessibility(); return }
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
        if let target = linkTargets[ObjectIdentifier(sender)] {
        hybridEvents?.nativeScreen(self, open: target, props: [:])
            return
        }
        guard let handler = handlers[ObjectIdentifier(sender)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]])
        restoreFocus(focused)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak focused] in
            self?.restoreFocus(focused)
        }
    }

    @objc private func checkboxPressed(_ sender: CraftNativeCheckboxButton) {
        sender.indeterminate = false
        checkboxIndeterminate[ObjectIdentifier(sender)] = false
        sender.isSelected.toggle()
        if let handler = handlers[ObjectIdentifier(sender)] {
            send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["value": sender.isSelected]])
        }
        applyAccessibility([:], type: "Checkbox", to: sender)
    }

    /// Return on a `returnKeyType="next"` field the screen does not handle
    /// itself (no `@submit`) goes to the next field down the screen, keeping
    /// the keyboard up. Every other Return ends editing and fires `@submit`.
    func textFieldShouldClear(_ textField: UITextField) -> Bool {
        guard textField.isEnabled else { return false }
        textField.text = ""
        let id = ObjectIdentifier(textField)
        inputIdentities[id].map { inputDrafts[$0] = "" }
        let eventCount = noteSentText("", for: textField)
        if let handler = handlers[id] {
            send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["text": "", "clear": true, "eventCount": eventCount]])
        }
        return false // The model receives exactly one edit, including lazy models.
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard textField.returnKeyType == .next, submitHandlers[ObjectIdentifier(textField)] == nil,
              let next = inputAfter(textField) else { return true }
        next.becomeFirstResponder()
        return false
    }

    /// The editable field after `input` in the screen's document order.
    /// Internal for XCTest.
    func inputAfter(_ input: UIView) -> UIView? {
        var inputs: [UIView] = []
        func collect(_ node: RenderedNode?) {
            guard let node else { return }
            if let field = node.view as? UITextField, field.isEnabled, !field.isHidden { inputs.append(field) }
            if let textView = node.view as? UITextView, textView.isEditable, !textView.isHidden { inputs.append(textView) }
            node.children.forEach(collect)
        }
        collect(renderedRoot)
        guard let index = inputs.firstIndex(where: { $0 === input }), index + 1 < inputs.count else { return nil }
        return inputs[index + 1]
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
        keepCaretVisible(in: textView)
        guard let handler = handlers[id] else { return }
        let eventCount = noteSentText(textView.text ?? "", for: textView)
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["text": textView.text ?? "", "eventCount": eventCount]])
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard textView.isFirstResponder else { return }
        keepCaretVisible(in: textView)
    }

    /// The caret, kept where it can be seen as a multiline input grows or the
    /// caret moves: in the part of the screen's scroll view the keyboard
    /// leaves. Only the field was scrolled into view, when editing began, so
    /// a long comment typed at the bottom of a screen went under the keyboard.
    private func keepCaretVisible(in textView: UITextView) {
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView, textView.isFirstResponder else { return }
            // The input grows with its text first: a text view's new lines
            // are news to the flex layout around it, which sized the scroll
            // view's content to the old height.
            textView.invalidateIntrinsicContentSize()
            CraftNativeFlexLayout.invalidateAncestors(of: textView)
            self.view.layoutIfNeeded()
            // That layout can move the scroll view: its keyboard inset is
            // measured where it now ends before the caret is.
            if self.keyboardScreenFrame != nil { self.insetScrollViewsForKeyboard() }
            guard let scroll = self.enclosingVerticalScroll(of: textView),
                  let rect = self.caretRect(of: textView, in: scroll) else { return }
            let visible = scroll.bounds.inset(by: scroll.adjustedContentInset)
            guard !visible.contains(rect) else { return }
            scroll.scrollRectToVisible(rect, animated: false)
        }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        lastFocusedInput = textView
        if keyboardScreenFrame != nil { DispatchQueue.main.async { self.scrollFocusedInputIntoView(animated: true) } }
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
        let eventCount = noteSentText(sender.text ?? "", for: sender)
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["text": sender.text ?? "", "eventCount": eventCount]])
        restoreFocus(focused)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak focused] in
            self?.restoreFocus(focused)
        }
    }

    @objc private func segmentChanged(_ sender: CraftNativeSegmentedControl) {
        let index = sender.selectedSegmentIndex
        guard sender.isEnabled, sender.values.indices.contains(index), sender.isEnabledForSegment(at: index),
              let handler = handlers[ObjectIdentifier(sender)] else { return }
        sender.refreshAccessibilityState()
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["value": sender.values[index], "index": index]])
    }

    @objc private func solidSwitchChanged(_ sender: CraftNativeSolidSwitch) {
        guard sender.isEnabled, let handler = handlers[ObjectIdentifier(sender)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["value": sender.isOn]])
    }

    @objc private func switchChanged(_ sender: UISwitch) {
        let id = ObjectIdentifier(sender)
        switchUserValues[id] = sender.isOn
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak sender] in
            guard let self, let sender, self.switchUserValues[id] == sender.isOn else { return }
            self.switchUserValues.removeValue(forKey: id)
        }
        guard let handler = handlers[id] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["value": sender.isOn]])
    }

    @objc private func sliderChanged(_ sender: UISlider) {
        let value = snappedSliderValue(sender.value, for: sender)
        if sender.value != value { sender.value = value }
        guard let handler = handlers[ObjectIdentifier(sender)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["value": Self.sliderEventValue(value, step: sliderSteps[ObjectIdentifier(sender)])]])
    }

    /// A slider's value as the script reads it. UISlider keeps a Float, and a
    /// step of 0.1 counted up in Floats lands beside the decimal (0.8 read as
    /// 0.800000011920929, nine steps as 0.90000004), so the value is the
    /// shortest decimal for that Float, rounded to as many places as the step
    /// has.
    static func sliderEventValue(_ value: Float, step: Float? = nil) -> Double {
        let decimal = Double(value.description) ?? Double(value)
        guard let step, step > 0, step.isFinite else { return decimal }
        // "0.1" is one place, "0.25" two, "1.0" none; a step as small as
        // "1e-07" is held to six.
        let fraction = step.description.split(separator: ".").dropFirst().first
        let places = step.description.contains("e") ? 6 : min(6, fraction.map { $0 == "0" ? 0 : $0.count } ?? 0)
        let scale = pow(10, Double(places))
        return (decimal * scale).rounded() / scale
    }

    /// `@change` on a DatePicker: the value as `<input type="date|time|
    /// datetime-local">` writes it, in local time, with the moment as ISO and
    /// milliseconds for code that wants those.
    @objc private func datePicked(_ sender: UIDatePicker) {
        guard let handler = handlers[ObjectIdentifier(sender)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": Self.datePickerEvent(sender)])
    }

    static func datePickerEvent(_ picker: UIDatePicker) -> [String: Any] {
        if picker.datePickerMode == .countDownTimer { return countdownEvent(picker.countDownDuration) }
        return datePickerEvent(picker.date, mode: picker.datePickerMode)
    }

    static func countdownEvent(_ duration: TimeInterval) -> [String: Any] {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return [
            "value": String(format: "%02d:%02d:%02d", hours, minutes, seconds),
            "iso": "PT\(totalSeconds)S",
            "timestamp": Double(totalSeconds * 1000),
        ]
    }

    static func datePickerEvent(_ date: Date, mode: UIDatePicker.Mode) -> [String: Any] {
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.calendar = Calendar(identifier: .gregorian)
        local.timeZone = .current
        local.dateFormat = mode == .date ? "yyyy-MM-dd" : mode == .time ? "HH:mm" : "yyyy-MM-dd'T'HH:mm"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "value": local.string(from: date),
            "iso": iso.string(from: date),
            "timestamp": (date.timeIntervalSince1970 * 1000).rounded(),
        ]
    }

    static func datePickerMode(_ value: Any?) -> UIDatePicker.Mode {
        switch value as? String {
        case "time": return .time
        case "datetime", "dateAndTime", "datetime-local": return .dateAndTime
        case "countdown": return .countDownTimer
        default: return .date
        }
    }

    /// Countdown values use seconds when numeric, or `HH:mm[:ss]` text.
    static func countdownDuration(_ value: Any?) -> TimeInterval? {
        let maximum: TimeInterval = 23 * 3600 + 59 * 60 + 59
        if let number = craftNativeNumber(value) {
            let seconds = number.doubleValue
            guard seconds.isFinite else { return nil }
            return min(maximum, max(0, seconds))
        }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = Double(text), seconds.isFinite { return min(maximum, max(0, seconds)) }
        let parts = text.split(separator: ":")
        guard parts.count == 2 || parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]) else { return nil }
        let seconds = parts.count == 3 ? (Double(parts[2]) ?? -1) : 0
        guard hours.isFinite, minutes.isFinite, seconds.isFinite,
              hours >= 0, minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 else { return nil }
        return min(maximum, hours * 3600 + minutes * 60 + seconds)
    }

    /// A DatePicker's value: `2026-10-12` (that day), `07:30` (today at that
    /// time), `2026-10-12T07:30` (local), a full ISO 8601 string, or
    /// milliseconds since 1970. Nil for anything else.
    static func pickerDate(_ value: Any?) -> Date? {
        if let number = craftNativeNumber(value) {
            let milliseconds = number.doubleValue
            guard milliseconds.isFinite else { return nil }
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.calendar = Calendar(identifier: .gregorian)
        local.timeZone = .current
        for format in ["HH:mm", "HH:mm:ss"] {
            local.dateFormat = format
            if let time = local.date(from: text) {
                let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: time)
                return Calendar.current.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: parts.second ?? 0, of: Date())
            }
        }
        for format in ["yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: text)
    }

    @objc private func sliderFinished(_ sender: UISlider) {
        guard let handler = sliderCompleteHandlers[ObjectIdentifier(sender)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["value": Self.sliderEventValue(snappedSliderValue(sender.value, for: sender), step: sliderSteps[ObjectIdentifier(sender)])]])
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
        // Moving between fields does not move the keyboard, so nothing else
        // brings the next one up from under it.
        if keyboardScreenFrame != nil { DispatchQueue.main.async { self.scrollFocusedInputIntoView(animated: true) } }
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
        // Return put the keyboard away.
        forgetFocusedInput(sender)
        guard let handler = submitHandlers[ObjectIdentifier(sender)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": ["text": sender.text ?? ""]])
    }

    @objc private func viewPressed(_ sender: UITapGestureRecognizer) {
        guard let view = sender.view else { return }
        let id = ObjectIdentifier(view)
        if let target = linkTargets[id] {
        hybridEvents?.nativeScreen(self, open: target, props: [:])
            return
        }
        guard let handler = handlers[id] else { return }
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
            if let pressable = view as? CraftNativeFlowView {
                if let underlayColor = pressable.pressUnderlayColor { pressable.backgroundColor = underlayColor }
                if let activeOpacity = pressable.pressActiveOpacity {
                    UIView.animate(withDuration: 0.1) { pressable.alpha = pressable.pressBaseOpacity * activeOpacity }
                }
            }
            if let handler = pressInHandlers[id] { send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]]) }
            if let handler = underlayShowHandlers[id] { send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]]) }
        case .ended, .cancelled, .failed:
            if let pressable = view as? CraftNativeFlowView {
                pressable.backgroundColor = pressable.pressBaseBackgroundColor
                UIView.animate(withDuration: 0.1) { pressable.alpha = pressable.pressBaseOpacity }
            }
            if let handler = pressOutHandlers[id] { send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]]) }
            if let handler = underlayHideHandlers[id] { send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": [:]]) }
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
        // Sticky positioning is a native scroll behavior and must also run
        // without a JavaScript onScroll subscription, including animations.
        (scrollView as? CraftNativeScrollView)?.updateStickyHeaders()
        guard let handler = scrollHandlers[ObjectIdentifier(scrollView)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": scrollEvent(scrollView)])
    }

    private var pacingName: String { "scroll \(routeName ?? "screen")" }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        CraftFramePacing.shared.begin(pacingName)
        (scrollView as? CraftNativeScrollView)?.beginPageDrag()
        guard let handler = scrollBeginHandlers[ObjectIdentifier(scrollView)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": scrollEvent(scrollView)])
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { CraftFramePacing.shared.end(pacingName); (scrollView as? CraftNativeScrollView)?.finishPageMotion() }
        guard let handler = scrollEndHandlers[ObjectIdentifier(scrollView)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": scrollEvent(scrollView)])
    }

    func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
        guard let handler = scrollMomentumBeginHandlers[ObjectIdentifier(scrollView)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": scrollEvent(scrollView)])
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        CraftFramePacing.shared.end(pacingName)
        (scrollView as? CraftNativeScrollView)?.finishPageMotion()
        guard let handler = scrollMomentumEndHandlers[ObjectIdentifier(scrollView)] else { return }
        send(type: "EVENT", payload: ["handlerName": handler, "nativeEvent": scrollEvent(scrollView)])
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        (scrollView as? CraftNativeScrollView)?.finishPageMotion()
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
        let context = jsContext
        let route = routeName ?? "screen"
        CraftNativeScriptThread.run(label: "\(type) \(route)") { context.objectForKeyedSubscript("__stxNativeCallback")?.call(withArguments: [json]) }
    }

    private func number(_ value: Any?) -> CGFloat? {
        guard let number = craftNativeNumber(value) else { return nil }
        let value = CGFloat(truncating: number)
        return value.isFinite ? value : nil
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
        case "ascii-capable": return .asciiCapable
        case "numbers-and-punctuation": return .numbersAndPunctuation
        case "name-phone-pad": return .namePhonePad
        case "twitter": return .twitter
        default: return .default
        }
    }

    /// What the field holds, for the system's autofill: `textContentType` in
    /// UITextContentType's names (`username`, `password`, `newPassword`,
    /// `oneTimeCode`...), or `autoComplete` in HTML's (`current-password`,
    /// `one-time-code`, `email`). A password field without it gets no
    /// Passwords suggestion above the keyboard.
    static func textContentType(_ props: [String: Any]) -> UITextContentType? {
        let raw = (props["textContentType"] as? String) ?? (props["autoComplete"] as? String) ?? (props["autocomplete"] as? String)
        guard let raw, !raw.isEmpty else { return nil }
        let key = raw.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "").lowercased()
        switch key {
        case "username": return .username
        case "nickname": return .nickname
        case "password", "currentpassword": return .password
        case "newpassword": return .newPassword
        case "onetimecode": return .oneTimeCode
        case "emailaddress", "email": return .emailAddress
        case "telephonenumber", "tel", "phone": return .telephoneNumber
        case "name": return .name
        case "givenname", "firstname": return .givenName
        case "middlename", "additionalname": return .middleName
        case "familyname", "lastname": return .familyName
        case "nameprefix", "honorificprefix": return .namePrefix
        case "namesuffix", "honorificsuffix": return .nameSuffix
        case "organizationname", "organization": return .organizationName
        case "jobtitle", "organizationtitle": return .jobTitle
        case "url": return .URL
        case "fullstreetaddress", "streetaddress": return .fullStreetAddress
        case "streetaddressline1", "addressline1": return .streetAddressLine1
        case "streetaddressline2", "addressline2": return .streetAddressLine2
        case "addresscity", "addresslevel2": return .addressCity
        case "addressstate", "addresslevel1": return .addressState
        case "addresscityandstate": return .addressCityAndState
        case "postalcode": return .postalCode
        case "countryname", "country": return .countryName
        case "location": return .location
        case "creditcardnumber", "ccnumber": return .creditCardNumber
        default: return nil
        }
    }

    private func applyAutofill(to input: UITextInputTraits & UIView, props: [String: Any]) {
        let type = Self.textContentType(props)
        let rules = (props["passwordRules"] as? String).flatMap { $0.isEmpty ? nil : UITextInputPasswordRules(descriptor: $0) }
        if let field = input as? UITextField {
            if field.textContentType != type { field.textContentType = type }
            if field.passwordRules?.passwordRulesDescriptor != rules?.passwordRulesDescriptor { field.passwordRules = rules }
        } else if let textView = input as? UITextView {
            if textView.textContentType != type { textView.textContentType = type }
            if textView.passwordRules?.passwordRulesDescriptor != rules?.passwordRulesDescriptor { textView.passwordRules = rules }
        }
    }

    private func returnKeyType(_ value: Any?) -> UIReturnKeyType {
        switch value as? String {
        case "done": return .done
        case "go": return .go
        case "next": return .next
        case "search": return .search
        case "send": return .send
        case "join": return .join
        case "route": return .route
        case "continue": return .continue
        case "emergency-call": return .emergencyCall
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

// MARK: - Animated changes

/// What `craft.animation.next(options)` asked for. `duration` in seconds
/// (0.1 to 1, 0.35 when left out); `curve` "spring" (the default, iOS's own
/// smooth spring with no bounce unless `bounce` says), "easeInOut" or
/// "linear".
struct CraftNativeAnimationSpec {
    let duration: TimeInterval
    let curve: String
    let bounce: CGFloat

    init(_ payload: [String: Any]) {
        let asked = (payload["duration"] as? NSNumber)?.doubleValue ?? 0.35
        duration = min(max(asked.isFinite ? asked : 0.35, 0.1), 1)
        let name = payload["curve"] as? String ?? "spring"
        curve = ["spring", "easeInOut", "linear"].contains(name) ? name : "spring"
        let springiness = (payload["bounce"] as? NSNumber)?.doubleValue ?? 0
        bounce = CGFloat(min(max(springiness.isFinite ? springiness : 0, 0), 0.5))
    }

    var timing: UITimingCurveProvider {
        switch curve {
        case "linear": return UICubicTimingParameters(animationCurve: .linear)
        case "easeInOut": return UICubicTimingParameters(animationCurve: .easeInOut)
        default: return UISpringTimingParameters(dampingRatio: 1 - bounce)
        }
    }
}

/// How long a change animates while one runs on any screen, so what the
/// app changes beside it (the status bar's style) moves in step.
enum CraftNativeAnimationClock {
    static var duration: TimeInterval?
}

/// A view as it was when the change was asked for.
final class CraftNativeAnimationRecord {
    let view: UIView
    weak var superview: UIView?
    /// In its parent's coordinates, and in the screen's.
    let frame: CGRect
    let frameOnScreen: CGRect
    let alpha: CGFloat
    let backgroundColor: UIColor?
    let fontSize: CGFloat?
    let textColor: UIColor?
    let transitionID: String?
    /// Where it sat in its parent, to be put back after it faded elsewhere.
    let index: Int?
    let arrangedIndex: Int?

    init(view: UIView, screen: UIView, transitionID: String?) {
        self.view = view
        superview = view.superview
        index = view.superview?.subviews.firstIndex(of: view)
        arrangedIndex = (view.superview as? UIStackView)?.arrangedSubviews.firstIndex(of: view)
        frame = view.frame
        frameOnScreen = view.superview?.convert(view.frame, to: screen) ?? view.frame
        alpha = view.alpha
        backgroundColor = view.backgroundColor
        fontSize = (view as? UILabel)?.font.pointSize
        textColor = (view as? UILabel)?.textColor
        self.transitionID = transitionID
    }
}

/// The screen between `craft.animation.next` and the change it animates.
final class CraftNativeAnimationTransaction {
    let spec: CraftNativeAnimationSpec
    let reduceMotion: Bool
    var records: [ObjectIdentifier: CraftNativeAnimationRecord] = [:]
    var screenBackground: UIColor?
    /// Reduce Motion: the screen as it was, crossfaded into the new one.
    var picture: UIView?
    /// Commits the change as the run loop finishes the pass it came in.
    var observer: CFRunLoopObserver?
    /// The screen as it was, drawn over it until the animation is set up.
    var cover: UIView?

    init(spec: CraftNativeAnimationSpec, reduceMotion: Bool) {
        self.spec = spec
        self.reduceMotion = reduceMotion
    }
}

/// An animation under way: finished at once if another change comes first.
final class CraftNativeRunningAnimation {
    /// The Core Animation key every animation of a change goes under.
    static let key = "craft.change"
    var animators: [UIViewPropertyAnimator] = []
    /// Live layers carrying an animation of the change, under `key` + a suffix.
    var layers: [(CALayer, String)] = []
    var cleanup: [() -> Void] = []
    private var done = false

    func finish() {
        guard !done else { return }
        done = true
        for animator in animators where animator.state == .active {
            animator.stopAnimation(false)
            animator.finishAnimation(at: .end)
        }
        // A live view's own values were never touched: taking the animation
        // off leaves it exactly as the screen last drew it.
        for (layer, key) in layers { layer.removeAnimation(forKey: key) }
        layers.removeAll()
        cleanup.forEach { $0() }
        cleanup.removeAll()
    }
}

extension CraftNativeScreenController {
    /// `craft.animation.next(options)`: what the screen changes next (a
    /// render, a patch, its own background and bar) animates instead of
    /// cutting, as SwiftUI's `withAnimation` or React Native's
    /// `LayoutAnimation`. Views that stay move and resize to their new
    /// places; new views fade in and removed ones fade out where they were; a
    /// view whose font size changed scales into it. Two views with the same
    /// `transitionID`, one going and one coming, are one element: it moves and
    /// scales from the old one's place to the new one's, crossfading the two.
    /// With Reduce Motion on, the whole screen crossfades instead.
    func beginAnimatedChange(_ payload: [String: Any]) {
        guard !isAppScript, isViewLoaded else { return }
        // The last change's animation lands where it was going first.
        runningAnimation?.finish()
        runningAnimation = nil
        if animationTransaction != nil { return }
        let transaction = CraftNativeAnimationTransaction(spec: CraftNativeAnimationSpec(payload), reduceMotion: UIAccessibility.isReduceMotionEnabled)
        transaction.screenBackground = view.backgroundColor
        if transaction.reduceMotion {
            // Held over the screen until the change is in, then faded away.
            if view.window != nil, let picture = view.snapshotView(afterScreenUpdates: false) {
                picture.frame = view.bounds
                picture.isUserInteractionEnabled = false
                view.addSubview(picture)
                transaction.picture = picture
            }
        } else {
            view.layoutIfNeeded()
            recordAnimationState(renderedRoot, into: transaction)
            // The screen as it is, held over it until the change's animation
            // is set up: UIKit can draw the new screen before the run loop's
            // pass ends, which showed it for a frame before it animated.
            if view.window != nil, let cover = view.snapshotView(afterScreenUpdates: false) {
                cover.frame = view.bounds
                cover.isUserInteractionEnabled = false
                view.addSubview(cover)
                transaction.cover = cover
            }
        }
        animationTransaction = transaction
        CraftNativeAnimationClock.duration = transaction.spec.duration
        // The change comes from the same turn of the script (the state it
        // changed renders in a microtask), so it is set up as the run loop
        // finishes this pass, before Core Animation draws it: drawn first, the
        // new screen showed for a frame and then jumped back to animate. A
        // change that comes later still animates.
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, 0) { [weak self] _, _ in
            self?.commitAnimatedChange()
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            transaction.observer = observer
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.commitAnimatedChange() }
    }

    private func recordAnimationState(_ node: RenderedNode?, into transaction: CraftNativeAnimationTransaction) {
        guard let node else { return }
        let id = ObjectIdentifier(node.view)
        transaction.records[id] = CraftNativeAnimationRecord(view: node.view, screen: view, transitionID: transitionIDs[id])
        node.children.forEach { recordAnimationState($0, into: transaction) }
    }

    private func renderedViews(_ node: RenderedNode?, into views: inout [UIView]) {
        guard let node else { return }
        views.append(node.view)
        node.children.forEach { renderedViews($0, into: &views) }
    }

    private func commitAnimatedChange() {
        guard let transaction = animationTransaction else { return }
        animationTransaction = nil
        if let observer = transaction.observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            transaction.observer = nil
        }
        // Taken off in the same transaction the animations start in.
        transaction.cover?.removeFromSuperview()
        transaction.cover = nil
        let spec = transaction.spec
        let running = CraftNativeRunningAnimation()
        runningAnimation = running
        running.cleanup.append { CraftNativeAnimationClock.duration = nil }

        if transaction.reduceMotion {
            guard let picture = transaction.picture else { running.finish(); return }
            let fade = UIViewPropertyAnimator(duration: 0.3, curve: .easeInOut) { picture.alpha = 0 }
            fade.addCompletion { _ in running.finish() }
            running.animators.append(fade)
            running.cleanup.append { picture.removeFromSuperview() }
            fade.startAnimation()
            return
        }

        UIView.performWithoutAnimation { view.layoutIfNeeded() }
        var after: [UIView] = []
        renderedViews(renderedRoot, into: &after)
        let present = Set(after.map(ObjectIdentifier.init))
        let records = transaction.records

        // Going: no longer drawn. Only the topmost of a removed subtree moves
        // to the overlay; what is under it goes with it.
        let removed = records.values.filter { !present.contains(ObjectIdentifier($0.view)) }
        let removedIds = Set(removed.map { ObjectIdentifier($0.view) })
        let removedRoots = removed.filter { record in
            guard let parent = record.superview else { return true }
            return !removedIds.contains(ObjectIdentifier(parent))
        }
        // Coming: not there before.
        let inserted = after.filter { records[ObjectIdentifier($0)] == nil }
        let insertedIds = Set(inserted.map(ObjectIdentifier.init))

        // One element across the change: the old view going, the new one coming.
        var oldShared: [String: CraftNativeAnimationRecord] = [:]
        for record in removed { if let tag = record.transitionID { oldShared[tag] = record } }
        var pairs: [(old: CraftNativeAnimationRecord, new: UIView)] = []
        for candidate in inserted {
            if let tag = transitionIDs[ObjectIdentifier(candidate)], let old = oldShared.removeValue(forKey: tag) {
                pairs.append((old, candidate))
            }
        }
        let pairedNew = Set(pairs.map { ObjectIdentifier($0.new) })

        let overlay = UIView(frame: view.bounds)
        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = .clear
        view.addSubview(overlay)
        running.cleanup.append { overlay.removeFromSuperview() }

        // Views that are going are the change's own now: they move into the
        // overlay where they were and fade there. Put back as they were
        // afterwards, in case the screen shows them again.
        let fadeOut = UIViewPropertyAnimator(duration: spec.duration * 0.5, curve: .easeOut)
        let quickFade = UIViewPropertyAnimator(duration: spec.duration * 0.35, curve: .easeOut)
        let travel = UIViewPropertyAnimator(duration: spec.duration, timingParameters: spec.timing)
        running.animators = [fadeOut, quickFade, travel]
        func adopt(_ record: CraftNativeAnimationRecord, fading fade: UIViewPropertyAnimator) {
            let going = record.view
            let resizes = going.translatesAutoresizingMaskIntoConstraints
            let base = going.transform
            going.translatesAutoresizingMaskIntoConstraints = true
            going.transform = .identity
            going.frame = record.frameOnScreen
            going.alpha = record.alpha
            overlay.addSubview(going)
            fade.addAnimations { going.alpha = 0 }
            running.cleanup.append {
                going.removeFromSuperview()
                going.transform = base
                going.alpha = record.alpha
                going.translatesAutoresizingMaskIntoConstraints = resizes
                going.frame = record.frame
                // Back in a parent that went with it, as it was: a screen
                // that shows that subtree again finds it whole.
                if let parent = record.superview, parent.window == nil {
                    if let stack = parent as? UIStackView, let at = record.arrangedIndex {
                        stack.insertArrangedSubview(going, at: min(at, stack.arrangedSubviews.count))
                    } else if let at = record.index {
                        parent.insertSubview(going, at: min(at, parent.subviews.count))
                    }
                }
            }
        }
        for record in removedRoots { adopt(record, fading: fadeOut) }

        // Live views are animated on their layers only, from how they were to
        // how the screen draws them now: nothing the screen sets on them
        // meanwhile (the next second on a timer, a style patch) is undone.
        let fades = spec.duration * 0.6
        func animate(_ layer: CALayer, _ keyPath: String, from: Any, duration: TimeInterval? = nil, spring: Bool = true) {
            let animation: CABasicAnimation
            if spring, duration == nil, spec.curve == "spring" {
                let bouncy = CASpringAnimation(keyPath: keyPath)
                bouncy.mass = 1
                bouncy.stiffness = pow(2 * .pi / spec.duration, 2)
                bouncy.damping = 2 * sqrt(bouncy.stiffness) * (1 - spec.bounce)
                bouncy.duration = bouncy.settlingDuration
                animation = bouncy
            } else {
                animation = CABasicAnimation(keyPath: keyPath)
                animation.duration = duration ?? spec.duration
                animation.timingFunction = CAMediaTimingFunction(name: spec.curve == "linear" ? .linear : .easeInEaseOut)
            }
            animation.fromValue = from
            let key = "\(CraftNativeRunningAnimation.key).\(keyPath)"
            animation.atDisplayRate()
            layer.add(animation, forKey: key)
            running.layers.append((layer, key))
        }

        // The background, the screen's own included, comes from the old colour.
        if let before = transaction.screenBackground, let now = view.backgroundColor, !before.isEqual(now) {
            animate(view.layer, "backgroundColor", from: before.cgColor, spring: false)
        }

        // Shared elements: the new view starts where the old one was, at its
        // size, and the old one travels with it as it fades.
        for (old, new) in pairs {
            let target = new.superview?.convert(new.frame, to: view) ?? new.frame
            let move = morph(from: old.frameOnScreen, to: target, uniform: true)
            animate(new.layer, "transform", from: CATransform3DMakeAffineTransform(new.transform.concatenating(move)))
            // Crossed quickly, so the two are never both half there for long.
            animate(new.layer, "opacity", from: 0, duration: spec.duration * 0.35)
            adopt(old, fading: quickFade)
            let going = old.view
            travel.addAnimations { going.transform = move.inverted() }
        }

        // New views fade in. A new container holding a shared element keeps it
        // in sight: only the rest of it fades, and its colour comes up.
        func fadeIn(_ added: UIView) {
            if pairedNew.contains(ObjectIdentifier(added)) { return }
            guard containsShared(added, pairedNew: pairedNew) else {
                animate(added.layer, "opacity", from: 0, duration: fades)
                return
            }
            if let colour = added.backgroundColor, colour != .clear {
                animate(added.layer, "backgroundColor", from: colour.withAlphaComponent(0).cgColor, duration: fades)
            }
            added.subviews.forEach(fadeIn)
        }
        for added in inserted where !(added.superview.map { insertedIds.contains(ObjectIdentifier($0)) } ?? false) {
            fadeIn(added)
        }

        // Views that stay go to their new places and sizes.
        for record in records.values where present.contains(ObjectIdentifier(record.view)) {
            let stays = record.view
            if let label = stays as? UILabel, let before = record.fontSize, abs(before - label.font.pointSize) > 0.5 {
                let target = label.superview?.convert(label.frame, to: view) ?? label.frame
                let move = morph(from: record.frameOnScreen, to: target, uniform: true)
                animate(label.layer, "transform", from: CATransform3DMakeAffineTransform(label.transform.concatenating(move)))
            } else if record.superview === stays.superview, record.frame != stays.frame, stays.transform.isIdentity {
                animate(stays.layer, "position", from: CGPoint(x: record.frame.midX, y: record.frame.midY))
                if record.frame.size != stays.frame.size {
                    animate(stays.layer, "bounds.size", from: record.frame.size)
                }
            }
            if let before = record.backgroundColor, let now = stays.backgroundColor, !before.isEqual(now) {
                animate(stays.layer, "backgroundColor", from: before.cgColor, spring: false)
            }
        }

        travel.addCompletion { _ in running.finish() }
        fadeOut.startAnimation()
        quickFade.startAnimation()
        travel.startAnimation()
        // The springs settle a little after `duration`; the views are already
        // where the screen draws them, so finishing then changes nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + spec.duration * 2) { running.finish() }
    }

    /// The transform that puts a view at `final` where `start` was: moved
    /// centre to centre and scaled, by height alone when `uniform`, so text
    /// keeps its shape.
    private func morph(from start: CGRect, to final: CGRect, uniform: Bool) -> CGAffineTransform {
        guard final.width > 0, final.height > 0, start.width > 0, start.height > 0 else { return .identity }
        let sy = start.height / final.height
        let sx = uniform ? sy : start.width / final.width
        let dx = start.midX - final.midX
        let dy = start.midY - final.midY
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: sx, y: sy)
    }

    private func containsShared(_ view: UIView, pairedNew: Set<ObjectIdentifier>) -> Bool {
        if pairedNew.contains(ObjectIdentifier(view)) { return true }
        return view.subviews.contains { containsShared($0, pairedNew: pairedNew) }
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
