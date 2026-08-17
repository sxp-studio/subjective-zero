// SPDX-License-Identifier: AGPL-3.0-only
// The world one delivery evaluates against — everything here is true between messages; a
// message only adds words. Steps see the `facts(message:)` slice over the wire; the graph
// and statuses feed brief rendering host-side and never cross the step ABI.
import Foundation

public struct SZWorld: Sendable {
    /// The REAL typed project document; nil = no project open.
    public var graph: SZGraph?
    /// Agent-reported status per node — `{{blockers}}`, and the `{{blocker}}` derivation
    /// for the delivery's own node.
    public var statuses: [SZNodeID: String]
    /// The node this delivery is bound to (its scope); nil = a director/debug conversation.
    public var node: SZNodeID?
    /// Whether the scope already has a session — the doors' cold-vs-resumed fork.
    public var resuming: Bool
    /// The granted build this delivery serves, while one is live.
    public var run: SZRun?
    /// The standing work assigned to this scope, surviving the retry loop.
    public var assignment: SZAssignment?
    /// Graph edits since this scope's previous turn, with their actors — the reconcile brief's
    /// `{{mutations}}`. Host-side like the graph; never crosses the step ABI.
    public var mutations: [SZGraphMutation]

    public init(graph: SZGraph? = nil, statuses: [SZNodeID: String] = [:],
                node: SZNodeID? = nil, resuming: Bool = false, run: SZRun? = nil,
                assignment: SZAssignment? = nil, mutations: [SZGraphMutation] = []) {
        self.graph = graph
        self.statuses = statuses
        self.node = node
        self.resuming = resuming
        self.run = run
        self.assignment = assignment
        self.mutations = mutations
    }

    /// The step-visible slice: the wire document an evaluation (and its asks) is pinned to.
    public func facts(message: String) -> SZFacts {
        SZFacts(message: message, node: node, resuming: resuming,
                run: run, assignment: assignment)
    }
}
