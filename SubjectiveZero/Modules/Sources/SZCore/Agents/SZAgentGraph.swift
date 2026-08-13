// SPDX-License-Identifier: AGPL-3.0-only
// The agent-graph model: a declared topology wiring authored steps. A node takes exactly one
// of four forms — `message` (the graph's one entry: a delivered message leaves by the port
// bearing its kind), `step` (compiled code, outcomes exported by the step itself), `turn` (a
// full agent turn whose body is a mustache brief; outcomes fixed ok/error), `dispatch` (fan
// work out as messages; send-and-conclude, so no out-edges). Lives in SZCore because SZUI
// draws graphs and may not import SZAI; everything here is pure data + shape validation.
//
// THE MESSAGE NODE IS WHY THE GRAPH IS ONE PICTURE. An earlier model kept `entry` as a map
// from kind to node, which meant a graph with two doors drew as two disconnected fragments —
// the fleet's `settled` reply in particular had nowhere to enter but a second entry key, so
// the retry lane floated unattached to anything. Making the door a NODE puts every kind the
// agent accepts on one card with one port each, and `unreachable` below refuses a fragment
// at load rather than leaving it to be noticed on a canvas.
//
// Validation is split by what it can see: `defects()` here checks graph SHAPE alone. Checks
// needing pack context — a step's declared outcomes, template existence, dispatch-target
// resolution, seat rules — belong to the pack loader (SZAI), which attaches declarations
// and validates the whole library together.
import Foundation

public struct SZAgentGraph: Sendable, Equatable {
    public var name: String
    /// Optional display name / picker hint (drawn by the panel; never routing input).
    public var label: String?
    public var hint: String?
    public var caps: Caps?
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
        /// The graph's one door. A delivery leaves by the port named for its kind; nothing
        /// runs here, so it spends no time and reaches no host seam.
        case message(Message)
        /// A compiled `Step.swift` in the agent's pack; `name` is its folder. Outcomes come
        /// from the step's own exported declaration, attached at pack load.
        case step(name: String)
        case turn(Turn)
        case dispatch(Dispatch)
    }

    /// The message form carries no configuration — WHICH kinds it accepts is said by the
    /// edges leaving it, so the ports and the routing can never disagree. An empty struct
    /// rather than a bare case so the form can gain config later without a fifth form.
    public struct Message: Codable, Sendable, Equatable {
        public init() {}
        /// Every kind that may be delivered. Reusing the ordinary outcome check means a
        /// port naming a non-kind — or naming `steer`, which never enters a graph — is
        /// refused as `undeclaredOutcome` with no rule of its own.
        public static let outcomes: Set<String> =
            Set(SZMessageKind.deliverable.map(\.rawValue))
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
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            brief = try container.decode(String.self, forKey: .brief)
            // An omitted session means spawn — the wire default matches the init's.
            session = try container.decodeIfPresent(Session.self, forKey: .session) ?? .spawn
            tools = try container.decodeIfPresent([String].self, forKey: .tools)
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

    public init(name: String, label: String? = nil, hint: String? = nil,
                caps: Caps? = nil, nodes: [Node], edges: [Edge]) {
        self.name = name
        self.label = label
        self.hint = hint
        self.caps = caps
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

    // MARK: - The door, and what it opens onto

    /// The graph's one message node. Validation guarantees exactly one; a graph that has
    /// none is refused at load, so every path here that returns nil is a broken file.
    public var messageNode: Node? {
        nodes.first { if case .message = $0.form { true } else { false } }
    }

    /// Kind → the node its delivery enters at, derived from the message node's out-edges.
    /// This is the old `entry` map, no longer stored: the edges ARE the map, which is why
    /// the door draws and the map never could.
    public var routes: [SZMessageKind: String] {
        guard let door = messageNode else { return [:] }
        var out: [SZMessageKind: String] = [:]
        for edge in edges where edge.from == door.id {
            if let kind = SZMessageKind(rawValue: edge.outcome) { out[kind] = edge.to }
        }
        return out
    }

    /// Whether a delivery of `kind` has anywhere to go.
    public func handles(_ kind: SZMessageKind) -> Bool { routes[kind] != nil }

    /// Which delivered kinds can reach `id`, by walking out from each port over EVERY edge
    /// — bounded ones included, since a loop reaches what it loops over. The message node
    /// is excluded from the walk: each port is its own seed, so the lanes never bleed
    /// through the door they share.
    public func kinds(reaching id: String) -> Set<SZMessageKind> {
        var out: Set<SZMessageKind> = []
        let door = messageNode?.id
        for (kind, seed) in routes {
            var seen: Set<String> = [seed]
            var queue = [seed]
            while let current = queue.popLast() {
                if current == id { out.insert(kind); break }
                for edge in edges
                where edge.from == current && edge.to != door && seen.insert(edge.to).inserted {
                    queue.append(edge.to)
                }
            }
        }
        return out
    }

    /// The FACTS lanes reaching `id` — `kinds(reaching:)` folded through `SZMessageKind.lane`,
    /// so a node shared by the build lane and its settled re-entry counts as ONE lane and
    /// stays typeable. This is what the pack gate checks a step's facts kind against.
    public func lanes(reaching id: String) -> Set<SZMessageKind> {
        Set(kinds(reaching: id).map(\.lane))
    }
}

// MARK: - Wire format

extension SZAgentGraph: Codable {
    enum CodingKeys: String, CodingKey {
        case name, label, hint, caps, nodes, edges
        /// Retired keys, decoded ONLY to refuse them by name. A pack written against the
        /// entry-map era is not migrated (this repo does not migrate); it is told what to
        /// do, because the alternative is a file that loads and silently routes nothing.
        case kind, entry
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.entry) || container.contains(.kind) {
            throw DecodingError.dataCorruptedError(
                forKey: container.contains(.entry) ? .entry : .kind, in: container,
                debugDescription: "'kind' and 'entry' are retired — give the graph a message "
                    + #"node ({"id": "message", "message": {}}) and one edge out of it per "#
                    + "kind it accepts, e.g. {\"from\": \"message\", \"outcome\": \"build\", "
                    + "\"to\": \"decompose\"}")
        }
        name = try container.decode(String.self, forKey: .name)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        hint = try container.decodeIfPresent(String.self, forKey: .hint)
        caps = try container.decodeIfPresent(Caps.self, forKey: .caps)
        nodes = try container.decode([Node].self, forKey: .nodes)
        edges = try container.decodeIfPresent([Edge].self, forKey: .edges) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(hint, forKey: .hint)
        try container.encodeIfPresent(caps, forKey: .caps)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(edges, forKey: .edges)
    }
}

extension SZAgentGraph.Node: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, onMessage, step, turn, dispatch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        // Collect, then insist on exactly one — a four-wide tuple switch is where that
        // pattern stops reading, and the count is what the rule actually says.
        var forms: [SZAgentGraph.Form] = []
        if let message = try container.decodeIfPresent(SZAgentGraph.Message.self, forKey: .onMessage) {
            forms.append(.message(message))
        }
        if let name = try container.decodeIfPresent(String.self, forKey: .step) {
            forms.append(.step(name: name))
        }
        if let turn = try container.decodeIfPresent(SZAgentGraph.Turn.self, forKey: .turn) {
            forms.append(.turn(turn))
        }
        if let dispatch = try container.decodeIfPresent(SZAgentGraph.Dispatch.self, forKey: .dispatch) {
            forms.append(.dispatch(dispatch))
        }
        guard forms.count == 1, let only = forms.first else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container,
                debugDescription: "node '\(id)' must declare exactly one of "
                    + "onMessage/step/turn/dispatch")
        }
        form = only
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        switch form {
        case .message(let message): try container.encode(message, forKey: .onMessage)
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
    case noMessageNode
    case severalMessageNodes(ids: [String])
    case edgeIntoMessage(from: String)
    /// A node the door cannot reach — the floating-fragment defect. The whole reason the
    /// entry map became a node: this is now refusable at load.
    case unreachable(nodes: [String])
    /// A node reachable from two FACTS lanes. Steps and briefs are typed to one lane's
    /// facts, so a node serving two has no checkable type.
    case laneImpure(node: String, lanes: [String])
    case danglingEdge(from: String, to: String)
    case duplicateEdge(from: String, outcome: String)
    case edgeFromDispatch(node: String)
    case undeclaredOutcome(node: String, outcome: String)
    case nonPositiveBound(from: String, outcome: String)
    case nonPositiveRounds(Int)
    case unboundedCycle(nodes: [String])

    public var description: String {
        switch self {
        case .duplicateNode(let id):
            "two nodes share the id '\(id)'"
        case .noMessageNode:
            "the graph has no message node — nothing can be delivered to it"
        case .severalMessageNodes(let ids):
            "the graph has \(ids.count) message nodes (\(ids.joined(separator: ", "))) — "
                + "an agent has one door"
        case .edgeIntoMessage(let from):
            "edge from '\(from)' points back into the message node — a message arrives, "
                + "it is never routed to"
        case .unreachable(let nodes):
            "\(nodes.joined(separator: ", ")) cannot be reached from the message node"
        case .laneImpure(let node, let lanes):
            "'\(node)' is reachable from both \(lanes.joined(separator: " and ")) — a node "
                + "reads one kind's facts, so it belongs to one lane"
        case .danglingEdge(let from, let to):
            "edge \(from) → \(to) names an unknown node"
        case .duplicateEdge(let from, let outcome):
            "two edges leave '\(from)' on '\(outcome)' — the second can never route"
        case .edgeFromDispatch(let node):
            "dispatch '\(node)' sends and concludes — it cannot have an out-edge"
        case .undeclaredOutcome(let node, let outcome):
            "'\(node)' never produces outcome '\(outcome)'"
        case .nonPositiveBound(let from, let outcome):
            "edge \(from) on '\(outcome)' declares a bound below 1"
        case .nonPositiveRounds(let rounds):
            "caps.rounds is \(rounds) — 'no re-entries' is spelled by leaving the message "
                + "node's 'settled' port unwired"
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

        // The door. Everything downstream — reachability, lanes, the engine's entry —
        // reads `messageNode`, so its cardinality is checked before anything uses it.
        let doors = nodes.filter { if case .message = $0.form { true } else { false } }
        switch doors.count {
        case 0: defects.append(.noMessageNode)
        case 1: break
        default: defects.append(.severalMessageNodes(ids: doors.map(\.id).sorted()))
        }

        if let rounds = caps?.rounds, rounds < 1 {
            defects.append(.nonPositiveRounds(rounds))
        }

        var routes: Set<String> = []
        for edge in edges {
            if !routes.insert("\(edge.from)\u{0}\(edge.outcome)").inserted {
                defects.append(.duplicateEdge(from: edge.from, outcome: edge.outcome))
            }
            if !ids.contains(edge.from) || !ids.contains(edge.to) {
                defects.append(.danglingEdge(from: edge.from, to: edge.to))
                continue
            }
            if let bound = edge.maxTraversals, bound < 1 {
                defects.append(.nonPositiveBound(from: edge.from, outcome: edge.outcome))
            }
            if case .message = node(edge.to)?.form {
                defects.append(.edgeIntoMessage(from: edge.from))
            }
            switch node(edge.from)?.form {
            case .dispatch:
                defects.append(.edgeFromDispatch(node: edge.from))
            case .turn where !Turn.outcomes.contains(edge.outcome):
                defects.append(.undeclaredOutcome(node: edge.from, outcome: edge.outcome))
            case .message where !Message.outcomes.contains(edge.outcome):
                // Catches both "that is not a message kind" and "steer never enters a
                // graph" — no rule of their own, because the outcome set already says so.
                defects.append(.undeclaredOutcome(node: edge.from, outcome: edge.outcome))
            default:
                break
            }
        }

        defects.append(contentsOf: unboundedCycles().map { .unboundedCycle(nodes: $0) })

        // Reachability and lane purity read `routes`, which reads the door — skip both
        // when the door is broken, or every node reports as unreachable on top of the
        // defect that actually explains it.
        if doors.count == 1 {
            let door = doors[0].id
            let stranded = nodes.map(\.id)
                .filter { $0 != door && kinds(reaching: $0).isEmpty }
            if !stranded.isEmpty { defects.append(.unreachable(nodes: stranded.sorted())) }
            for node in nodes where node.id != door {
                let lanes = lanes(reaching: node.id)
                if lanes.count > 1 {
                    defects.append(.laneImpure(node: node.id,
                                               lanes: lanes.map(\.rawValue).sorted()))
                }
            }
        }
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
