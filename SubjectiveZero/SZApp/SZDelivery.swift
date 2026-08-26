// SPDX-License-Identifier: AGPL-3.0-only
// One delivered message's binding — the single serving object every traversal runs
// against, whatever the lane. The host constructs one per delivery with the message's
// words, a live world projection for the delivery's scope, the turn transport, and (for a
// build) the fleet seam. The engine sees only `SZTraversalServing`.
import Foundation
import SZAI
import SZCore

@MainActor
final class SZDelivery: SZTraversalServing {
    let agent: String
    let message: String
    let extras: SZBriefExtras
    private let renderer: SZBriefRenderer
    private let queries: SZQueryService
    /// Live world projection for this delivery's binding — read fresh per node visit.
    private let world: @MainActor () -> SZWorld
    private let turn: @MainActor (SZTurnOrder, @escaping @MainActor @Sendable (UUID, String?) -> Void) async -> SZTurnReport
    /// The fleet seam — only the build delivery carries one. nil at a dispatch node is an
    /// honest defect (the gate keeps dispatch nodes wired to a seat; the lane must serve it).
    var fleet: (@MainActor (_ orders: [SZWorkOrder], _ seat: String,
                            _ progress: @escaping @MainActor @Sendable (SZAgentGraphRun.Tally) -> Void)
                async -> SZSettledSummary?)?
    private let effect: @MainActor (SZEffect) async -> Void
    private let onNote: @MainActor (SZTraversalNote) -> Void
    /// The snapshot the current evaluation is pinned to — set by `facts()`, read by
    /// `serveAsk` so a step's asks render against the same world its evaluation saw.
    private var pinned: SZWorld?

    init(agent: String, message: String, extras: SZBriefExtras = SZBriefExtras(),
         renderer: SZBriefRenderer, queries: SZQueryService,
         world: @escaping @MainActor () -> SZWorld,
         turn: @escaping @MainActor (SZTurnOrder, @escaping @MainActor @Sendable (UUID, String?) -> Void) async -> SZTurnReport,
         effect: @escaping @MainActor (SZEffect) async -> Void,
         onNote: @escaping @MainActor (SZTraversalNote) -> Void) {
        self.agent = agent
        self.message = message
        self.extras = extras
        self.renderer = renderer
        self.queries = queries
        self.world = world
        self.turn = turn
        self.effect = effect
        self.onNote = onNote
    }

    func facts() -> SZFacts {
        let snapshot = world()
        pinned = snapshot
        return snapshot.facts(message: message)
    }

    func render(template: String) throws -> String {
        try renderer.render(agent: agent, template: template, message: message,
                            world: world(), extras: extras)
    }

    func conversation() -> String? {
        let snapshot = world()
        return SZConversationRecap.render(
            snapshot.conversation,
            nodes: (snapshot.graph?.nodes ?? []).map { (id: $0.id, title: $0.title) })
    }

    func runTurn(_ order: SZTurnOrder,
                 opened: @escaping @MainActor @Sendable (UUID, String?) -> Void) async -> SZTurnReport {
        await turn(order, opened)
    }

    func deliver(orders: [SZWorkOrder], to seat: String,
                 progress: @escaping @MainActor @Sendable (SZAgentGraphRun.Tally) -> Void)
        async -> SZSettledSummary? {
        await fleet?(orders, seat, progress)
    }

    func serveAsk(step: String, slot: String?, requestJSON: String) async throws -> String {
        try await queries.serve(agent: agent, step: step, slot: slot, message: message,
                                world: pinned ?? world(), extras: extras,
                                requestJSON: requestJSON)
    }

    func perform(effect value: SZEffect) async {
        await effect(value)
    }

    func note(_ note: SZTraversalNote) {
        onNote(note)
    }
}
