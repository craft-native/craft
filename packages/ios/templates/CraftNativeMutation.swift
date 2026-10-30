import CoreFoundation
import Foundation

let craftNativeMutationProtocolVersion = 1

struct CraftNativeMutationFailure: Error, Equatable {
    let code: String
    let message: String
    let operationIndex: Int?

    init(_ code: String, _ message: String, operationIndex: Int? = nil) {
        self.code = code
        self.message = message
        self.operationIndex = operationIndex
    }
}

struct CraftNativeMutationResult {
    let batchId: String
    let revision: Int
    let document: [String: Any]?
    let updatedNodeIds: [String]
    let affectedNodeIds: [String]
    let requiresFullRender: Bool
}

/// Validates and applies versioned native-tree mutations without touching UIKit.
/// A batch is committed only after every operation succeeds against a copy.
final class CraftNativeMutationDocument {
    private struct Node {
        let id: String
        let key: String?
        var type: String
        var props: [String: Any]
        var style: [String: Any]
        var events: [String: Any]
        var text: [String]
        // Legacy snapshots may interleave bare text and native children.
        // Keep each text fragment's slot among the child nodes on import.
        var textPositions: [Int]? = nil
        var children: [String]
        var parent: String?
    }

    private var nodes: [String: Node] = [:]
    private var rootId: String?
    private(set) var revision = 0

    /// The normalized committed tree, whose root need not be named "root".
    var document: [String: Any]? {
        rootId.flatMap { materialize($0, nodes: nodes) }
    }

    func replace(with document: [String: Any]) {
        var replacement: [String: Node] = [:]
        let root = importNode(document, preferredId: "root", parent: nil, nodes: &replacement)
        nodes = replacement
        rootId = root
        revision = 0
    }

    func apply(_ payload: [String: Any]) throws -> CraftNativeMutationResult {
        let batchId = payload["batchId"] as? String ?? ""
        guard !batchId.isEmpty else {
            throw CraftNativeMutationFailure("INVALID_BATCH", "batchId must be a non-empty string")
        }
        guard integer(payload["version"]) == craftNativeMutationProtocolVersion else {
            throw CraftNativeMutationFailure(
                "UNSUPPORTED_VERSION",
                "mutation protocol version must be \(craftNativeMutationProtocolVersion)"
            )
        }
        guard let baseRevision = integer(payload["baseRevision"]), baseRevision == revision else {
            throw CraftNativeMutationFailure(
                "REVISION_MISMATCH",
                "baseRevision must equal the current revision \(revision)"
            )
        }
        guard let nextRevision = integer(payload["revision"]), nextRevision == revision + 1 else {
            throw CraftNativeMutationFailure(
                "INVALID_REVISION",
                "revision must advance exactly once from \(revision)"
            )
        }
        guard let operations = payload["operations"] as? [Any], !operations.isEmpty else {
            throw CraftNativeMutationFailure("INVALID_BATCH", "operations must be a non-empty array")
        }

        var candidateNodes = nodes
        var candidateRoot = rootId
        var updatedNodeIds: [String] = []
        var affectedNodeIds: [String] = []
        var requiresFullRender = false
        for (index, value) in operations.enumerated() {
            guard let operation = value as? [String: Any], let name = operation["op"] as? String else {
                throw CraftNativeMutationFailure(
                    "INVALID_OPERATION",
                    "operation must be an object with an op string",
                    operationIndex: index
                )
            }
            do {
                switch name {
                case "createNode":
                    if operation["root"] as? Bool == true { requiresFullRender = true }
                    try createNode(operation, nodes: &candidateNodes, rootId: &candidateRoot)
                case "updateNode":
                    try updateNode(operation, nodes: &candidateNodes)
                    if let id = operation["id"] as? String {
                        appendUnique(id, to: &updatedNodeIds)
                        appendUnique(id, to: &affectedNodeIds)
                    }
                case "insertChild":
                    try insertChild(operation, nodes: &candidateNodes)
                    if let id = operation["parentId"] as? String { appendUnique(id, to: &affectedNodeIds) }
                case "moveChild":
                    try moveChild(operation, nodes: &candidateNodes)
                    if let id = operation["parentId"] as? String { appendUnique(id, to: &affectedNodeIds) }
                case "reparentChild":
                    let previousParent = try reparentChild(operation, nodes: &candidateNodes)
                    if let id = operation["parentId"] as? String { appendUnique(id, to: &affectedNodeIds) }
                    appendUnique(previousParent, to: &affectedNodeIds)
                    // A child crossing parents needs the committed tree to be
                    // reconciled so the host can move its existing native view.
                    requiresFullRender = true
                case "replaceChildren":
                    let parentId = try replaceChildren(operation, nodes: &candidateNodes)
                    appendUnique(parentId, to: &affectedNodeIds)
                case "removeNode":
                    if let id = operation["id"] as? String, let parent = candidateNodes[id]?.parent {
                        appendUnique(parent, to: &affectedNodeIds)
                    } else {
                        requiresFullRender = true
                    }
                    try removeNode(operation, nodes: &candidateNodes, rootId: &candidateRoot)
                default:
                    throw CraftNativeMutationFailure("UNKNOWN_OPERATION", "unsupported operation \(name)")
                }
            } catch let failure as CraftNativeMutationFailure {
                throw CraftNativeMutationFailure(failure.code, failure.message, operationIndex: index)
            }
        }
        if candidateRoot == nil, !candidateNodes.isEmpty {
            throw CraftNativeMutationFailure("MISSING_ROOT", "a non-empty document must have one root node")
        }
        if let candidateRoot {
            guard let root = candidateNodes[candidateRoot], root.parent == nil else {
                throw CraftNativeMutationFailure("INVALID_TREE", "root node must not have a parent")
            }
            guard descendants(of: candidateRoot, nodes: candidateNodes).count + 1 == candidateNodes.count else {
                throw CraftNativeMutationFailure("INVALID_TREE", "all nodes must be reachable from the root")
            }
        }

        nodes = candidateNodes
        rootId = candidateRoot
        revision = nextRevision
        return CraftNativeMutationResult(
            batchId: batchId,
            revision: nextRevision,
            document: candidateRoot.flatMap { materialize($0, nodes: candidateNodes) },
            updatedNodeIds: updatedNodeIds,
            affectedNodeIds: affectedNodeIds,
            requiresFullRender: requiresFullRender
        )
    }

    func node(_ id: String) -> [String: Any]? {
        materialize(id, nodes: nodes)
    }

    /// The committed parent of a node: nil for the root or a node it does not hold.
    func parentId(of id: String) -> String? {
        nodes[id]?.parent
    }

    private func createNode(
        _ operation: [String: Any],
        nodes: inout [String: Node],
        rootId: inout String?
    ) throws {
        guard let id = operation["id"] as? String, !id.isEmpty else {
            throw CraftNativeMutationFailure("INVALID_NODE", "createNode.id must be a non-empty string")
        }
        guard nodes[id] == nil else {
            throw CraftNativeMutationFailure("DUPLICATE_NODE", "node \(id) already exists")
        }
        guard let value = operation["node"] as? [String: Any],
              let type = value["type"] as? String, !type.isEmpty else {
            throw CraftNativeMutationFailure("INVALID_NODE", "createNode.node.type must be a non-empty string")
        }
        let text = try textChildren(value["children"] ?? value["text"])
        let makeRoot = operation["root"] as? Bool == true
        if makeRoot, rootId != nil {
            throw CraftNativeMutationFailure("ROOT_EXISTS", "the document already has a root node")
        }
        nodes[id] = Node(
            id: id,
            key: value["key"] as? String,
            type: type,
            props: dictionary(value["props"]),
            style: dictionary(value["style"]),
            events: dictionary(value["events"]),
            text: text,
            children: [],
            parent: nil
        )
        if makeRoot { rootId = id }
    }

    private func updateNode(_ operation: [String: Any], nodes: inout [String: Node]) throws {
        let id = try requiredId(operation, name: "updateNode")
        guard var node = nodes[id] else {
            throw CraftNativeMutationFailure("UNKNOWN_NODE", "node \(id) does not exist")
        }
        guard let patch = operation["patch"] as? [String: Any] else {
            throw CraftNativeMutationFailure("INVALID_PATCH", "updateNode.patch must be an object")
        }
        let allowed = Set(["props", "style", "events", "children", "text"])
        if let unknown = patch.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw CraftNativeMutationFailure("INVALID_PATCH", "unsupported patch field \(unknown)")
        }
        if patch.keys.contains("props") { mergePatch(patch["props"], into: &node.props) }
        if patch.keys.contains("style") { mergePatch(patch["style"], into: &node.style) }
        if patch.keys.contains("events") { mergePatch(patch["events"], into: &node.events) }
        if patch.keys.contains("children") || patch.keys.contains("text") {
            node.text = try textChildren(patch["children"] ?? patch["text"])
            node.textPositions = nil
        }
        nodes[id] = node
    }

    private func insertChild(_ operation: [String: Any], nodes: inout [String: Node]) throws {
        let parentId = try requiredId(operation, field: "parentId", name: "insertChild")
        let childId = try requiredId(operation, field: "childId", name: "insertChild")
        guard var parent = nodes[parentId] else {
            throw CraftNativeMutationFailure("UNKNOWN_PARENT", "parent node \(parentId) does not exist")
        }
        guard var child = nodes[childId] else {
            throw CraftNativeMutationFailure("UNKNOWN_NODE", "node \(childId) does not exist")
        }
        guard acceptsChildren(parent.type) else {
            throw CraftNativeMutationFailure("INVALID_PARENT", "node \(parentId) cannot contain child nodes")
        }
        guard child.parent == nil else {
            throw CraftNativeMutationFailure("NODE_ATTACHED", "node \(childId) already has a parent")
        }
        guard parentId != childId, !descendants(of: childId, nodes: nodes).contains(parentId) else {
            throw CraftNativeMutationFailure("CYCLE", "inserting node \(childId) would create a cycle")
        }
        let index = try insertionIndex(operation, count: parent.children.count)
        parent.children.insert(childId, at: index)
        child.parent = parentId
        nodes[parentId] = parent
        nodes[childId] = child
    }

    private func moveChild(_ operation: [String: Any], nodes: inout [String: Node]) throws {
        let parentId = try requiredId(operation, field: "parentId", name: "moveChild")
        let childId = try requiredId(operation, field: "childId", name: "moveChild")
        guard var parent = nodes[parentId] else {
            throw CraftNativeMutationFailure("UNKNOWN_PARENT", "parent node \(parentId) does not exist")
        }
        guard nodes[childId]?.parent == parentId, let oldIndex = parent.children.firstIndex(of: childId) else {
            throw CraftNativeMutationFailure("NOT_A_CHILD", "node \(childId) is not a child of \(parentId)")
        }
        parent.children.remove(at: oldIndex)
        let index = try insertionIndex(operation, count: parent.children.count)
        parent.children.insert(childId, at: index)
        nodes[parentId] = parent
    }

    private func reparentChild(_ operation: [String: Any], nodes: inout [String: Node]) throws -> String {
        let parentId = try requiredId(operation, field: "parentId", name: "reparentChild")
        let childId = try requiredId(operation, field: "childId", name: "reparentChild")
        guard var parent = nodes[parentId] else {
            throw CraftNativeMutationFailure("UNKNOWN_PARENT", "node \(parentId) does not exist")
        }
        guard var child = nodes[childId], let previousParentId = child.parent,
              var previousParent = nodes[previousParentId] else {
            throw CraftNativeMutationFailure("NOT_ATTACHED", "node \(childId) is not attached to a parent")
        }
        guard acceptsChildren(parent.type) else {
            throw CraftNativeMutationFailure("INVALID_PARENT", "node \(parentId) cannot contain child nodes")
        }
        guard parentId != childId, !descendants(of: childId, nodes: nodes).contains(parentId) else {
            throw CraftNativeMutationFailure("CYCLE", "reparenting node \(childId) would create a cycle")
        }
        guard parentId != previousParentId else {
            throw CraftNativeMutationFailure("SAME_PARENT", "node \(childId) is already a child of \(parentId)")
        }
        let index = try insertionIndex(operation, count: parent.children.count)
        previousParent.children.removeAll { $0 == childId }
        parent.children.insert(childId, at: index)
        child.parent = parentId
        nodes[previousParentId] = previousParent
        nodes[parentId] = parent
        nodes[childId] = child
        return previousParentId
    }

    /// Replaces a container's ordered child snapshot in one atomic mutation.
    ///
    /// The list protocol uses this operation when a keyed `:for` expansion
    /// produces a new row set. Existing nodes may stay attached to the same
    /// parent; removed children become detached and can be reused or removed
    /// by later operations in the same batch.
    private func replaceChildren(_ operation: [String: Any], nodes: inout [String: Node]) throws -> String {
        let parentId = try requiredId(operation, field: "parentId", name: "replaceChildren")
        guard var parent = nodes[parentId] else {
            throw CraftNativeMutationFailure("UNKNOWN_PARENT", "node \(parentId) does not exist")
        }
        guard acceptsChildren(parent.type) else {
            throw CraftNativeMutationFailure("INVALID_PARENT", "node \(parentId) cannot contain child nodes")
        }
        guard let values = operation["children"] as? [Any] else {
            throw CraftNativeMutationFailure("INVALID_CHILDREN", "replaceChildren.children must be an array")
        }
        var childIds: [String] = []
        for value in values {
            guard let childId = value as? String, !childId.isEmpty else {
                throw CraftNativeMutationFailure("INVALID_CHILDREN", "replaceChildren.children must contain non-empty ids")
            }
            guard !childIds.contains(childId) else {
                throw CraftNativeMutationFailure("DUPLICATE_CHILD", "child \(childId) appears more than once")
            }
            guard let child = nodes[childId] else {
                throw CraftNativeMutationFailure("UNKNOWN_NODE", "node \(childId) does not exist")
            }
            guard childId != parentId, !descendants(of: childId, nodes: nodes).contains(parentId) else {
                throw CraftNativeMutationFailure("CYCLE", "attaching node \(childId) would create a cycle")
            }
            guard child.parent == nil || child.parent == parentId else {
                throw CraftNativeMutationFailure("NODE_ATTACHED", "node \(childId) already has a parent")
            }
            childIds.append(childId)
        }
        let removedChildIds = parent.children.filter { !childIds.contains($0) }
        for oldChildId in removedChildIds {
            for descendant in descendants(of: oldChildId, nodes: nodes).union([oldChildId]) {
                nodes.removeValue(forKey: descendant)
            }
        }
        parent.children = childIds
        nodes[parentId] = parent
        for childId in childIds { nodes[childId]?.parent = parentId }
        return parentId
    }

    private func removeNode(
        _ operation: [String: Any],
        nodes: inout [String: Node],
        rootId: inout String?
    ) throws {
        let id = try requiredId(operation, name: "removeNode")
        guard let node = nodes[id] else {
            throw CraftNativeMutationFailure("UNKNOWN_NODE", "node \(id) does not exist")
        }
        if let parentId = node.parent, var parent = nodes[parentId] {
            parent.children.removeAll { $0 == id }
            nodes[parentId] = parent
        }
        for descendant in descendants(of: id, nodes: nodes).union([id]) { nodes.removeValue(forKey: descendant) }
        if rootId == id { rootId = nil }
    }

    private func requiredId(
        _ operation: [String: Any],
        field: String = "id",
        name: String
    ) throws -> String {
        guard let id = operation[field] as? String, !id.isEmpty else {
            throw CraftNativeMutationFailure("INVALID_NODE", "\(name).\(field) must be a non-empty string")
        }
        return id
    }

    private func insertionIndex(_ operation: [String: Any], count: Int) throws -> Int {
        guard let index = integer(operation["index"]), index >= 0, index <= count else {
            throw CraftNativeMutationFailure("INVALID_INDEX", "index must be between 0 and \(count)")
        }
        return index
    }

    private func textChildren(_ value: Any?) throws -> [String] {
        if value == nil || value is NSNull { return [] }
        if let text = value as? String { return [text] }
        guard let values = value as? [Any], values.allSatisfy({ $0 is String }) else {
            throw CraftNativeMutationFailure(
                "INVALID_NODE",
                "node children may contain text only; use insertChild for node relationships"
            )
        }
        return values.compactMap { $0 as? String }
    }

    /// Every type the renderer draws children of (CraftNativeScreen's
    /// reconcile), by the names it accepts (`canonicalType`, so `svg` is
    /// `Svg`). Only View, SafeAreaView and ScrollView used to be here, so a
    /// drawing revealed after the first paint (an `:if` around an `<svg>`)
    /// had its shapes refused as INVALID_PARENT, and the whole screen was
    /// drawn again; Android's host already took the same list. A shape holds
    /// its `Animate` (SMIL keyframes: HQ's moving exercise figures).
    static let containerTypes: Set<String> = [
        "View", "SafeAreaView", "ScrollView", "KeyboardAvoidingView", "Modal", "Pressable",
        "TouchableOpacity", "TouchableHighlight", "ImageBackground", "FlatList", "SectionList",
        "Fragment", "Svg", "G", "Map",
        "Path", "Line", "Rect", "Circle", "Ellipse", "Polyline", "Polygon",
    ]
    private static let containerTypeKeys = Set(containerTypes.map { $0.lowercased() })

    private func acceptsChildren(_ type: String) -> Bool {
        Self.containerTypeKeys.contains(type.lowercased())
    }

    private func descendants(of id: String, nodes: [String: Node]) -> Set<String> {
        guard let node = nodes[id] else { return [] }
        return node.children.reduce(into: Set<String>()) { result, child in
            result.insert(child)
            result.formUnion(descendants(of: child, nodes: nodes))
        }
    }

    private func materialize(_ id: String, nodes: [String: Node]) -> [String: Any]? {
        guard let node = nodes[id] else { return nil }
        var value: [String: Any] = [
            "id": node.id,
            "type": node.type,
            "props": node.props,
            "style": node.style,
            "events": node.events,
        ]
        if let key = node.key { value["key"] = key }
        let children: [Any] = node.children.compactMap { materialize($0, nodes: nodes) }
        var content: [Any] = []
        var textIndex = 0
        for index in 0...children.count {
            while textIndex < node.text.count,
                  min(node.textPositions?[textIndex] ?? 0, children.count) == index {
                content.append(node.text[textIndex])
                textIndex += 1
            }
            if index < children.count { content.append(children[index]) }
        }
        value["children"] = content
        return value
    }

    private func importNode(
        _ value: [String: Any],
        preferredId: String,
        parent: String?,
        nodes: inout [String: Node]
    ) -> String {
        let props = dictionary(value["props"])
        let explicit = (value["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let key = ([value["key"], props["key"], props["testID"]].compactMap { $0 as? String }.first)
        var id = explicit ?? key.map { "\(parent ?? "root")/key:\($0)" } ?? preferredId
        if nodes[id] != nil { id = "\(preferredId)#\(nodes.count)" }
        let children = value["children"] as? [Any] ?? []
        var textPositions: [Int] = []
        var childCount = 0
        for child in children {
            if child is String { textPositions.append(childCount) }
            else if child is [String: Any] { childCount += 1 }
        }
        nodes[id] = Node(
            id: id,
            key: value["key"] as? String,
            type: value["type"] as? String ?? "View",
            props: props,
            style: dictionary(value["style"]),
            events: dictionary(value["events"]),
            text: children.compactMap { $0 as? String },
            textPositions: textPositions,
            children: [],
            parent: parent
        )
        let childIds = children.enumerated().compactMap { index, child -> String? in
            guard let child = child as? [String: Any] else { return nil }
            return importNode(child, preferredId: "\(id)/index:\(index)", parent: id, nodes: &nodes)
        }
        nodes[id]?.children = childIds
        return id
    }

    private func dictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private func mergePatch(_ value: Any?, into target: inout [String: Any]) {
        for (key, next) in dictionary(value) {
            if next is NSNull { target.removeValue(forKey: key) }
            else { target[key] = next }
        }
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let candidate = number.intValue
        return number.doubleValue == Double(candidate) ? candidate : nil
    }

    private func appendUnique(_ id: String, to values: inout [String]) {
        if !values.contains(id) { values.append(id) }
    }
}
