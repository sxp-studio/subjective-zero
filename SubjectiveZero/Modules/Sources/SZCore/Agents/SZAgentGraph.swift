// SPDX-License-Identifier: AGPL-3.0-only
// The agent-graph model. Three node forms: step (compiled code), turn (a mustache brief;
// ok/error), dispatch (fan out, WAIT, settle onward). Every delivery enters at the node
// with the reserved id `door`, which must be a STEP — the agent's routing is code the
// author opens and edits; there is no kind anywhere. One message is one traversal: nothing
// re-enters a graph.
//
// Lives in SZCore (SZUI draws graphs, may not import SZAI). `defects()` checks SHAPE only;
// checks needing pack context (step declarations, templates, seats) live in the loader.
import Foundation

public struct SZAgentGraph: Sendable, Equatable {
    /// Optional display name / picker hint (drawn by the panel; never routing input).
    public var label: String?
    public var hint: String?
    public var nodes: [Node]
    public var edges: [Edge]

    /// The reserved id of the graph's entry node — the door.
    public static let doorID = "door"

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
        /// The brief template's STEM — `prompts/<brief>.md.mustache`. The template IS the
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
            /// Continue the scope's existing session (spawning when none exists).
            case resume
        }
        /// A turn reports process truth and nothing else; content routing belongs to steps.
        public static let outcomes: Set<String> = ["ok", "error"]
    }

    public struct Dispatch: Codable, Sendable, Equatable {
        /// The seat (role) receiving the work — resolved to an agent at pack load. What it
        /// sends is the run's work set: the only dispatchable list the system has.
        public var to: String
        public init(to: String) {
            self.to = to
        }
        /// A dispatch WAITS: the orders go out, the traversal holds at this node while the
        /// set works, and when the last item lands (or the watchdog synthesizes the
        /// stragglers) the node produces `settled` and routes its one edge — or ends the
        /// traversal right here when nothing is wired, which is how "no retry" is spelled.
        /// A settled edge that loops back MUST be leashed (`maxTraversals`): the leash IS
        /// the retry budget, using the same bound every other loop already speaks.
        public static let outcomes: Set<String> = ["settled"]
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

    public init(label: String? = nil, hint: String? = nil,
                nodes: [Node], edges: [Edge]) {
        self.label = label
        self.hint = hint
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

    /// The graph's entry — the node with the reserved id. Validation guarantees it exists
    /// and is a step; a nil here means a broken file.
    public var door: Node? {
        node(Self.doorID)
    }

    /// The largest leash on any dispatch node's settled edge — the retry budget the
    /// reconcile brief's `{{cap}}` states. 0 when no dispatch loops.
    public var retryCap: Int {
        edges.filter { edge in
            guard edge.outcome == "settled",
                  case .dispatch = node(edge.from)?.form else { return false }
            return true
        }.compactMap(\.maxTraversals).max() ?? 0
    }
}

// MARK: - Wire format

extension SZAgentGraph: Codable {
    enum CodingKeys: String, CodingKey {
        case label, hint, nodes, edges
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        hint = try container.decodeIfPresent(String.self, forKey: .hint)
        nodes = try container.decode([Node].self, forKey: .nodes)
        edges = try container.decodeIfPresent([Edge].self, forKey: .edges) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(hint, forKey: .hint)
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
        // Collect, then insist on exactly one — the count is what the rule actually says.
        var forms: [SZAgentGraph.Form] = []
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
                debugDescription: "node '\(id)' must declare exactly one of step/turn/dispatch")
        }
        form = only
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
    /// No node carries the reserved `door` id — nothing can be delivered to the graph.
    case noDoor
    /// The door exists but is not a step — the entry must be code the author can open.
    case doorNotStep
    case edgeIntoDoor(from: String)
    /// A node the door cannot reach — the floating-fragment defect, refusable at load
    /// because the entry is one known node.
    case unreachable(nodes: [String])
    case danglingEdge(from: String, to: String)
    case duplicateEdge(from: String, outcome: String)
    case edgeFromDispatch(node: String, outcome: String)
    case undeclaredOutcome(node: String, outcome: String)
    case nonPositiveBound(from: String, outcome: String)
    case unboundedCycle(nodes: [String])

    public var description: String {
        switch self {
        case .duplicateNode(let id):
            "two nodes share the id '\(id)'"
        case .noDoor:
            "the graph has no 'door' node — nothing can be delivered to it"
        case .doorNotStep:
            "the 'door' node is not a step — the entry is code the author opens and edits"
        case .edgeIntoDoor(let from):
            "edge from '\(from)' points back into the door — a message arrives, it is "
                + "never routed to"
        case .unreachable(let nodes):
            "\(nodes.joined(separator: ", ")) cannot be reached from the door"
        case .danglingEdge(let from, let to):
            "edge \(from) → \(to) names an unknown node"
        case .duplicateEdge(let from, let outcome):
            "two edges leave '\(from)' on '\(outcome)' — the second can never route"
        case .edgeFromDispatch(let node, let outcome):
            "dispatch '\(node)' produces only 'settled' — an edge on '\(outcome)' can never route"
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

        // The door. Everything downstream — reachability, the engine's entry — starts at
        // it, so its existence and form are checked before anything uses it.
        var doorUsable = false
        if let door {
            if case .step = door.form { doorUsable = true } else { defects.append(.doorNotStep) }
        } else {
            defects.append(.noDoor)
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
            if edge.to == Self.doorID {
                defects.append(.edgeIntoDoor(from: edge.from))
            }
            switch node(edge.from)?.form {
            case .dispatch where !Dispatch.outcomes.contains(edge.outcome):
                defects.append(.edgeFromDispatch(node: edge.from, outcome: edge.outcome))
            case .turn where !Turn.outcomes.contains(edge.outcome):
                defects.append(.undeclaredOutcome(node: edge.from, outcome: edge.outcome))
            default:
                break
            }
        }

        defects.append(contentsOf: unboundedCycles().map { .unboundedCycle(nodes: $0) })

        // Reachability walks out from the door over every edge — bounded ones included,
        // since a loop reaches what it loops over. Skipped while the door is broken, or
        // every node would report unreachable on top of the defect that explains it.
        if doorUsable {
            var reached: Set<String> = [Self.doorID]
            var queue = [Self.doorID]
            while let current = queue.popLast() {
                for edge in edges
                where edge.from == current && ids.contains(edge.to)
                    && reached.insert(edge.to).inserted {
                    queue.append(edge.to)
                }
            }
            let stranded = nodes.map(\.id).filter { !reached.contains($0) }
            if !stranded.isEmpty { defects.append(.unreachable(nodes: stranded.sorted())) }
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
