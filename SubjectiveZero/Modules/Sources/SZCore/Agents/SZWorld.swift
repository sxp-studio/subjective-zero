// SPDX-License-Identifier: AGPL-3.0-only
// The durable host state one delivery is evaluated against; the message itself only adds
// its text. Compiled steps receive just the serialized `facts(message:)` subset — the
// graph and node statuses stay host-side, used only to render briefs.
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
    /// Tasks scheduled and not yet started, oldest first — the director door's `amend` fork
    /// and the `{{tasks}}` brief token.
    public var pendingTasks: [SZTask]
    /// Graph edits since this scope's previous turn, with their actors — the reconcile brief's
    /// `{{mutations}}`. Host-side like the graph; never crosses the step ABI.
    public var mutations: [SZGraphMutation]
    /// The scope's prior conversation, oldest first, strictly before the message being served
    /// (not the delivered bubble, not bubbles queued behind it, not the ones that scheduled a
    /// run). Read by a turn declaring `context: conversation`. Host-side like the graph.
    public var conversation: [SZChatMessage]

    public init(graph: SZGraph? = nil, statuses: [SZNodeID: String] = [:],
                node: SZNodeID? = nil, resuming: Bool = false, run: SZRun? = nil,
                assignment: SZAssignment? = nil, pendingTasks: [SZTask] = [],
                mutations: [SZGraphMutation] = [], conversation: [SZChatMessage] = []) {
        self.graph = graph
        self.statuses = statuses
        self.node = node
        self.resuming = resuming
        self.run = run
        self.assignment = assignment
        self.pendingTasks = pendingTasks
        self.mutations = mutations
        self.conversation = conversation
    }

    /// The step-visible slice: the wire document an evaluation (and its asks) is pinned to.
    public func facts(message: String) -> SZFacts {
        SZFacts(message: message, node: node, resuming: resuming,
                run: run, assignment: assignment, pendingTasks: pendingTasks.map(\.id))
    }
}
