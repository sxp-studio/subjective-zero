// SPDX-License-Identifier: AGPL-3.0-only
// The agent-graph model: a declared topology wiring authored steps. A node takes exactly one
// of three forms — `step` (compiled code, outcomes exported by the step itself), `turn` (a
// full agent turn whose body is a mustache brief; outcomes fixed ok/error), `dispatch` (fan
// work out as messages; send-and-conclude, so no out-edges). Lives in SZCore because SZUI
// draws graphs and may not import SZAI; everything here is pure data + shape validation.
//
// Validation is split by what it can see: `defects()` here checks graph SHAPE alone. Checks
// needing pack context — a step's declared outcomes, template existence, dispatch-target
// resolution, seat rules — belong to the pack loader (SZAI), which attaches declarations
// and validates the whole library together.
import Foundation

public struct SZAgentGraph: Sendable, Equatable {
    public var name: String
    /// The kind this graph HANDLES: a delivered message of this kind may open it.
    public var kind: SZMessageKind
    /// Optional display name / picker hint (drawn by the panel; never routing input).
    public var label: String?
    public var hint: String?
    public var caps: Caps?
    /// Entry node per message kind. A graph always owns its own kind's entry; `settled`
    /// re-enters here after a dispatch set concludes. Wire sugar: a bare string is the
    /// graph's own kind.
    public var entry: [SZMessageKind: String]
    public var nodes: [Node]
    public var edges: [Edge]

    public struct Caps: Codable, Sendable, Equatable {
        /// How many settled re-entries this graph buys. The host ceiling still applies.
        public var rounds: Int?
        public init(rounds: Int? = nil) { self.rounds = rounds }
    }

    public struct Node: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String?
        public var form: Form
        public init(id: String, title: String? = nil, form: Form) {
            self.id = id
            self.title = title
            self.form = form
        }
    }

    /// Exactly one per node — enforced at decode, so a malformed node is unrepresentable.
    public enum Form: Sendable, Equatable {
        /// A compiled `Step.swift` in the agent's pack; `name` is its folder. Outcomes come
        /// from the step's own exported declaration, attached at pack load.
        case step(name: String)
        case turn(Turn)
        case dispatch(Dispatch)
    }

    public struct Turn: Codable, Sendable, Equatable {
        /// The brief template, a pack-relative `.md.mustache` path. The template IS the
        /// body — a turn has no code.
        public var brief: String
        public var session: Session
        /// Tool narrowing for this turn. nil = the agent's default surface.
        public var tools: [String]?
        public init(brief: String, session: Session = .spawn, tools: [String]? = nil) {
            self.brief = brief
            self.session = session
            self.tools = tools
        }
        public enum Session: String, Codable, Sendable {
            /// Fresh conversation — the brief re-renders the world every time.
            case spawn
            /// Continue the scope's existing session.
            case message
        }
        /// A turn reports process truth and nothing else; content routing belongs to steps.
        public static let outcomes: Set<String> = ["ok", "error"]
    }

    public struct Dispatch: Codable, Sendable, Equatable {
        /// The seat (role) receiving the items — resolved to an agent at pack load.
        public var to: String
        /// The `[SZNodeID]`-typed fact naming what to send — validated against the fact
        /// catalog at pack load.
        public var items: String
        public init(to: String, items: String) {
            self.to = to
            self.items = items
        }
        /// Send-and-conclude: the `settled` reply re-enters the graph via the machine, so a
        /// dispatch node has exactly one outcome and may have no out-edges.
        public static let outcomes: Set<String> = ["sent"]
    }

    public struct Edge: Codable, Sendable, Equatable {
        public var from: String
        public var outcome: String
        public var to: String
        /// A cycle is legal only across a bounded edge; the bound is per-traversal.
        public var maxTraversals: Int?
        public init(from: String, outcome: String, to: String, maxTraversals: Int? = nil) {
            self.from = from
            self.outcome = outcome
            self.to = to
            self.maxTraversals = maxTraversals
        }
    }

    public init(name: String, kind: SZMessageKind, label: String? = nil, hint: String? = nil,
                caps: Caps? = nil, entry: [SZMessageKind: String], nodes: [Node], edges: [Edge]) {
        self.name = name
        self.kind = kind
        self.label = label
        self.hint = hint
        self.caps = caps
        self.entry = entry
        self.nodes = nodes
        self.edges = edges
    }

    public func node(_ id: String) -> Node? {
        nodes.first { $0.id == id }
    }

    /// The edge leaving `from` on `outcome`, nil if the traversal ends there.
    public func edge(from: String, outcome: String) -> Edge? {
        edges.first { $0.from == from && $0.outcome == outcome }
    }
}

// MARK: - Wire format

extension SZAgentGraph: Codable {
    enum CodingKeys: String, CodingKey {
        case name, kind, label, hint, caps, entry, nodes, edges
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(SZMessageKind.self, forKey: .kind)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        hint = try container.decodeIfPresent(String.self, forKey: .hint)
        caps = try container.decodeIfPresent(Caps.self, forKey: .caps)
        nodes = try container.decode([Node].self, forKey: .nodes)
        edges = try container.decodeIfPresent([Edge].self, forKey: .edges) ?? []
        // Entry: `{"build": "plan", "settled": "assess"}`, or the bare-string sugar
        // `"entry": "plan"` meaning the graph's own kind.
        if let bare = try? container.decode(String.self, forKey: .entry) {
            entry = [kind: bare]
        } else {
            let keyed = try container.decode([String: String].self, forKey: .entry)
            var map: [SZMessageKind: String] = [:]
            for (rawKind, nodeID) in keyed {
                guard let entryKind = SZMessageKind(rawValue: rawKind) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .entry, in: container,
                        debugDescription: "unknown entry kind '\(rawKind)'")
                }
                map[entryKind] = nodeID
            }
            entry = map
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(hint, forKey: .hint)
        try container.encodeIfPresent(caps, forKey: .caps)
        try container.encode(Dictionary(uniqueKeysWithValues: entry.map { ($0.key.rawValue, $0.value) }),
                             forKey: .entry)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(edges, forKey: .edges)
    }
}

extension SZAgentGraph.Node: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, step, turn, dispatch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        let step = try container.decodeIfPresent(String.self, forKey: .step)
        let turn = try container.decodeIfPresent(SZAgentGraph.Turn.self, forKey: .turn)
        let dispatch = try container.decodeIfPresent(SZAgentGraph.Dispatch.self, forKey: .dispatch)
        switch (step, turn, dispatch) {
        case (let name?, nil, nil): form = .step(name: name)
        case (nil, let turn?, nil): form = .turn(turn)
        case (nil, nil, let dispatch?): form = .dispatch(dispatch)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container,
                debugDescription: "node '\(id)' must declare exactly one of step/turn/dispatch")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        switch form {
        case .step(let name): try container.encode(name, forKey: .step)
        case .turn(let turn): try container.encode(turn, forKey: .turn)
        case .dispatch(let dispatch): try container.encode(dispatch, forKey: .dispatch)
        }
    }
}

// MARK: - Shape validation

/// Everything `defects()` can refuse from the graph file alone. All refusals are collected,
/// not first-error — an author fixes a pack in one round, not twenty.
public enum SZAgentGraphDefect: Sendable, Equatable, CustomStringConvertible {
    case duplicateNode(id: String)
    case unknownEntry(kind: SZMessageKind, node: String)
    case entryKindNotEnterable(SZMessageKind)
    case missingOwnEntry(SZMessageKind)
    case danglingEdge(from: String, to: String)
    case edgeFromDispatch(node: String)
    case undeclaredOutcome(node: String, outcome: String)
    case nonPositiveBound(from: String, outcome: String)
    case unboundedCycle(nodes: [String])

    public var description: String {
        switch self {
        case .duplicateNode(let id):
            "two nodes share the id '\(id)'"
        case .unknownEntry(let kind, let node):
            "entry for '\(kind.rawValue)' names unknown node '\(node)'"
        case .entryKindNotEnterable(let kind):
            "'\(kind.rawValue)' is not a kind a graph can declare an entry for"
        case .missingOwnEntry(let kind):
            "the graph handles '\(kind.rawValue)' but declares no entry for it"
        case .danglingEdge(let from, let to):
            "edge \(from) → \(to) names an unknown node"
        case .edgeFromDispatch(let node):
            "dispatch '\(node)' sends and concludes — it cannot have an out-edge"
        case .undeclaredOutcome(let node, let outcome):
            "'\(node)' never produces outcome '\(outcome)'"
        case .nonPositiveBound(let from, let outcome):
            "edge \(from) on '\(outcome)' declares a bound below 1"
        case .unboundedCycle(let nodes):
            "cycle \(nodes.joined(separator: " → ")) never crosses a bounded edge"
        }
    }
}

extension SZAgentGraph {
    /// Shape defects, all of them. Outcomes of `step` nodes are NOT checked here — a step's
    /// outcome set is its compiled declaration's, attached at pack load; the loader repeats
    /// the outcome check with declarations in hand.
    public func defects() -> [SZAgentGraphDefect] {
        var defects: [SZAgentGraphDefect] = []
        var seen: Set<String> = []
        for node in nodes {
            if !seen.insert(node.id).inserted {
                defects.append(.duplicateNode(id: node.id))
            }
        }
        let ids = Set(nodes.map(\.id))

        for (entryKind, nodeID) in entry.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if !SZMessageKind.graphEntryKinds.contains(entryKind) {
                defects.append(.entryKindNotEnterable(entryKind))
            }
            if !ids.contains(nodeID) {
                defects.append(.unknownEntry(kind: entryKind, node: nodeID))
            }
        }
        if entry[kind] == nil {
            defects.append(.missingOwnEntry(kind))
        }

        for edge in edges {
            if !ids.contains(edge.from) || !ids.contains(edge.to) {
                defects.append(.danglingEdge(from: edge.from, to: edge.to))
                continue
            }
            if let bound = edge.maxTraversals, bound < 1 {
                defects.append(.nonPositiveBound(from: edge.from, outcome: edge.outcome))
            }
            switch node(edge.from)?.form {
            case .dispatch:
                defects.append(.edgeFromDispatch(node: edge.from))
            case .turn where !Turn.outcomes.contains(edge.outcome):
                defects.append(.undeclaredOutcome(node: edge.from, outcome: edge.outcome))
            default:
                break
            }
        }

        defects.append(contentsOf: unboundedCycles().map { .unboundedCycle(nodes: $0) })
        return defects
    }

    /// Cycles in the subgraph of UNBOUNDED edges — a loop that nothing ever leashes. Each
    /// cycle is reported once, from its smallest node id.
    private func unboundedCycles() -> [[String]] {
        var adjacency: [String: [String]] = [:]
        for edge in edges where edge.maxTraversals == nil {
            adjacency[edge.from, default: []].append(edge.to)
        }
        var cycles: [[String]] = []
        var visited: Set<String> = []

        for start in nodes.map(\.id).sorted() where !visited.contains(start) {
            var stack: [String] = []
            var onStack: Set<String> = []
            func explore(_ id: String) {
                visited.insert(id)
                stack.append(id)
                onStack.insert(id)
                for next in adjacency[id] ?? [] {
                    if !visited.contains(next) {
                        explore(next)
                    } else if onStack.contains(next), let firstIndex = stack.firstIndex(of: next) {
                        cycles.append(Array(stack[firstIndex...]))
                    }
                }
                stack.removeLast()
                onStack.remove(id)
            }
            explore(start)
        }
        return cycles
    }
}
