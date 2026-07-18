// SPDX-License-Identifier: AGPL-3.0-only
// The AGENTIC Director strategy — directs via an autonomous LLM Director Agent. "Director"
// is the orchestration role both strategies fill; this one fills it with an actual MCP agent (claude /
// codex) that reads the live graph and COORDINATES: it establishes + pins each node's typed contract
// upfront and dispatches the coding fleet, adding nodes only when intent is under-specified (e.g. one
// "make the camera grayscale" node → Camera→Grayscale). Plain Swift + LLM calls. (TODO: if a
// declarative behavior-tree engine ever earns its place, it would replace this hardcoded flow.)
// It composes its sibling `SZProceduralDirectorStrategy`'s dispatch: decompose/pin/wire, then hand
// the flow-drafted graph to the shared flow-ordered coding dispatch. See docs/AGENT_ORCHESTRATION.md.
//
// Flow: (1) DECOMPOSE/COORDINATE — one Director Agent turn, streamed live into the Director tab,
// that reads the graph and establishes each node's typed contract + wiring via `ui_*` (adding nodes only
// when intent is under-specified); (2) PIN + DISPATCH — pin the now-declared contracts and hand the
// graph to the SHARED parallel coding dispatch (composed from the procedural strategy); then
// (3) RECONCILE — the Director↔Coding messaging loop below.
import Foundation
import SZCore

public struct SZAgenticDirectorStrategy: SZOrchestrating {
    private let registry: SZProviderRegistry
    private let procedural: SZProceduralDirectorStrategy

    /// Max reconcile rounds AFTER the initial dispatch. A hard cap so a stuck node can't loop the
    /// fleet — and the user's token quota — forever; a node still unresolved after the cap is left for the
    /// user to inspect (its transcript/logs are in the node's tab).
    static let reconcileCap = 2

    public init(registry: SZProviderRegistry = .shared) {
        self.registry = registry
        self.procedural = SZProceduralDirectorStrategy(registry: registry)
    }

    @MainActor
    @discardableResult
    public func run(_ context: SZOrchestrationContext) async throws -> [SZNodeID: String] {
        guard let provider = registry.provider(id: context.providerID) else {
            throw SZOrchestratorError.unknownProvider(context.providerID)
        }

        // (1) Decompose/coordinate — the Director Agent declares contracts + wiring through `ui_*`. A
        // failed Director turn is non-fatal: we still dispatch whatever the graph already expresses (so a
        // flaky Director degrades to "implement what's drawn" rather than aborting the run).
        // SKIPPED for a chat-triggered run (`directorAlreadyBriefed`): the Director's own chat turn
        // just did this job with identical tools — a second turn would be pure latency+tokens.
        if !context.directorAlreadyBriefed,
           let directorTurn = context.directorTurn, let graph = context.store.project?.graph {
            do {
                _ = try await directorTurn(SZDirectorPrompt.render(graph: graph, instruction: context.instruction))
            } catch {
                print("[SZAgenticDirectorStrategy] Director turn failed: \(error) — dispatching the graph as-is")
            }
        }

        // (2) Pin + dispatch — pin the Director-declared contracts, then fan out the coding fleet. Read the
        // graph AFTER the Director turn so plans reflect any nodes it added/contracted.
        context.pinContracts()
        guard let project = context.store.project else { throw SZOrchestratorError.noProject }
        var sessions = try await procedural.dispatch(
            SZProceduralDirectorStrategy.plans(for: project.graph, workSet: context.workSet(),
                                              stagedPieces: context.stagedPieces()), provider: provider, context: context)

        // (3) Reconcile loop — converse with the nodes that didn't finish. A node still `.prompt`
        // after a dispatch never promoted (it failed / stalled / reported needsInput), so `plans(for:)`
        // returns exactly the unresolved set. Each round: the Director adjusts the blocked nodes' contract
        // / prompt via `ui_*`, then the fleet retries them — RESUMING each coding session (so it's the same
        // agent continuing its own conversation) re-grounded with the blocker. Bounded by `reconcileCap`.
        for round in 1...Self.reconcileCap {
            guard let graph = context.store.project?.graph else { break }
            let unresolved = SZProceduralDirectorStrategy.plans(for: graph, workSet: context.workSet(),
                                                               stagedPieces: context.stagedPieces())
            guard !unresolved.isEmpty else { break }
            let statuses = context.nodeStatus()

            // The Director decides per unresolved node (renegotiate contract / refine prompt via `ui_*`);
            // a failed reconcile turn is non-fatal — the nodes are still retried with their prior blocker.
            if let directorTurn = context.directorTurn {
                do {
                    _ = try await directorTurn(SZDirectorPrompt.renderReconcile(
                        graph: graph, unresolved: unresolved.map(\.node), statuses: statuses,
                        inbox: context.takeDirectorInbox(),   // the fleet's messages TO the Director
                        round: round, cap: Self.reconcileCap))
                } catch {
                    print("[SZAgenticDirectorStrategy] reconcile turn \(round) failed: \(error) — retrying nodes as-is")
                }
            }
            context.pinContracts()   // re-pin any contract the Director changed
            // Drain any messages the Director authored this round (its `ui_send_chat`-to-a-node calls).
            let directorMessages = context.takeDirectorMessages()

            // Re-dispatch the (re-read) unresolved nodes — read plans AFTER the reconcile turn so any
            // contract/prompt change is reflected. Resume each prior session; carry its blocker + the
            // Director's message forward.
            guard let updated = context.store.project?.graph else { break }
            let retry = SZProceduralDirectorStrategy.plans(for: updated, workSet: context.workSet(),
                                                          stagedPieces: context.stagedPieces())
            guard !retry.isEmpty else { break }
            let reconcile = Dictionary(uniqueKeysWithValues: retry.map { plan in
                (plan.node, SZProceduralDirectorStrategy.CodingReconcile(
                    resumeSession: sessions[plan.node],
                    blocker: statuses[plan.node] ?? "the previous attempt did not finish",
                    directorMessage: directorMessages[plan.node]))
            })
            let redispatched = try await procedural.dispatch(
                retry, provider: provider, context: context, reconcile: reconcile)
            sessions.merge(redispatched) { _, new in new }
        }
        return sessions
    }
}
