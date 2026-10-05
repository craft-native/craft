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
}

/// Validates and applies versioned native-tree mutations without touching UIKit.
/// A batch is committed only after every operation succeeds against a copy.
final class CraftNativeMutationDocument {
    private struct Node {
        let id: String
        var type: String
        var props: [String: Any]
        var style: [String: Any]
        var events: [String: Any]
        var text: [String]
        var children: [String]
        var parent: String?
    }

    private var nodes: [String: Node] = [:]
    private var rootId: String?
    private(set) var revision = 0

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
                    try createNode(operation, nodes: &candidateNodes, rootId: &candidateRoot)
                case "updateNode":
                    try updateNode(operation, nodes: &candidateNodes)
                case "insertChild":
                    try insertChild(operation, nodes: &candidateNodes)
                case "moveChild":
                    try moveChild(operation, nodes: &candidateNodes)
                case "removeNode":
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

        nodes = candidateNodes
        rootId = candidateRoot
        revision = nextRevision
        return CraftNativeMutationResult(
            batchId: batchId,
            revision: nextRevision,
            document: candidateRoot.flatMap { materialize($0, nodes: candidateNodes) }
        )
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
        if patch.keys.contains("props") { node.props = dictionary(patch["props"]) }
        if patch.keys.contains("style") { node.style = dictionary(patch["style"]) }
        if patch.keys.contains("events") { node.events = dictionary(patch["events"]) }
        if patch.keys.contains("children") || patch.keys.contains("text") {
            node.text = try textChildren(patch["children"] ?? patch["text"])
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

    private func acceptsChildren(_ type: String) -> Bool {
        type == "View" || type == "SafeAreaView" || type == "ScrollView"
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
        let text: [Any] = node.text
        let children: [Any] = node.children.compactMap { materialize($0, nodes: nodes) }
        value["children"] = text + children
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
        nodes[id] = Node(
            id: id,
            type: value["type"] as? String ?? "View",
            props: props,
            style: dictionary(value["style"]),
            events: dictionary(value["events"]),
            text: children.compactMap { $0 as? String },
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

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let candidate = number.intValue
        return number.doubleValue == Double(candidate) ? candidate : nil
    }
}
