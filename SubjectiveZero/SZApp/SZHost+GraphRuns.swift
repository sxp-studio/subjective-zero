// SPDX-License-Identifier: AGPL-3.0-only
// The agent-graph RUNS records — where the graph strategy's observation hooks become
// `SZAgentGraphRun` values the Agent Graph panel draws and `runs.json` archives. This file
// is the host seam the record model documents: the engine's note type (SZAI) maps onto the
// record's own trace entry (SZCore) here, and nowhere else.
//
// The salvaged discipline, kept: live records exist ONLY in `agentGraphRuns` (a crash
// mid-traversal loses the record; the transcript survives); the sidecar is written at seal
// and on the one sanctioned post-seal write (the dispatch-tally amend); the history caps
// per budget and is replaced wholesale on project switch.
import Foundation
import SZAI
import SZCore
import SZUI

extension SZHost {
    // MARK: - Record lifecycle (the strategy's hooks land here, in hook order)

    /// A traversal began — open its live record. The THREAD is the host's run identity: one
    /// Build press and every traversal it causes share `runID`, which is what groups them
    /// in the RUNS list.
    ///
    /// A CHAT is never part of a build thread, even one delivered mid-run: a node outside
    /// the work set can be chatted while the fleet works, and the list's thread header
    /// picks the newest non-item traversal as the thread's DECIDER — so a chat joining the
    /// group would paint its own ending as the build's.
    func beginAgentGraphRun(_ sighting: SZTraversalSighting) {
        let record = SZAgentGraphRun(id: sighting.id, agent: sighting.agent,
                                     graphName: sighting.graphName, kind: sighting.kind,
                                     thread: sighting.kind == .message ? nil : runID,
                                     work: sighting.work)
        agentGraphRuns = SZAgentGraphRun.ordered(agentGraphRuns + [record])
    }

    /// One traversal note → the record's own trace entry (the SZAI→SZCore mapping). The
    /// record's sealed guard and stamp-preserving merge do the rest.
    func noteAgentGraphRun(_ id: UUID, _ note: SZTraversalNote) {
        guard let i = agentGraphRuns.firstIndex(where: { $0.id == id }) else { return }
        agentGraphRuns[i].note(SZAgentGraphRun.Entry(note))
    }

    /// The traversal concluded — seal, re-order (it just stopped being live), cap, persist,
    /// and carry an ITEM traversal's bad news onto the node it served.
    func concludeAgentGraphRun(_ id: UUID, _ ending: SZTraversalEnding) {
        guard let i = agentGraphRuns.firstIndex(where: { $0.id == id }) else { return }
        agentGraphRuns[i].seal(conclusion: SZAgentGraphRun.Conclusion(ending))
        surfaceWorkFailure(agentGraphRuns[i], ending)
        agentGraphRuns = SZAgentGraphRun.capped(SZAgentGraphRun.ordered(agentGraphRuns))
        persistAgentGraphRuns()
    }

    /// A failed work traversal knows WHY it failed; without this the post-run sweep paints
    /// the node with its generic "never compiled this node or reported a blocker" line and
    /// the reason is lost. Keyed on the traversal's own conclusion, so it covers every
    /// graph — a retryless strategy that ends at its first settlement included.
    ///
    /// An agent's OWN report always wins: a coding agent that said `needsInput` with its
    /// question keeps saying that. Only a node whose agent never reported takes this word.
    /// Cancelled work says nothing at all — a stopped run is not a failed node.
    private func surfaceWorkFailure(_ record: SZAgentGraphRun, _ ending: SZTraversalEnding) {
        guard record.kind == .work, let id = record.work, let node = UUID(uuidString: id),
              let message = Self.workFailureMessage(ending) else { return }
        let reported = nodeAgentState[node]?.phase
        guard reported != .error, reported != .needsInput else { return }
        recordNodeStatus(node: node, phase: .error, message: message)
    }

    /// The node-facing sentence for a work ending, or nil when the node should stay quiet.
    nonisolated static func workFailureMessage(_ ending: SZTraversalEnding) -> String? {
        switch ending {
        case .ended, .cancelled: nil
        case .failed(let reason): reason
        case .declined(let reason): "declined — \(reason)"
        case .defect(let detail): detail
        }
    }

    /// Run-task drain: seal anything of THIS run's still live as cancelled. Structured
    /// concurrency makes this a no-op on every healthy path (each traversal seals itself as
    /// its engine returns) — this is the belt for the task unwinding abnormally, so a
    /// record can never pulse "live" forever. Thread-scoped, so a zombie draining after a
    /// cancel-and-restart can never touch the NEW run's records.
    func sealLeakedAgentGraphRuns(thread: UUID?) {
        guard let thread else { return }
        var sealed = false
        for i in agentGraphRuns.indices
        where agentGraphRuns[i].thread == thread && agentGraphRuns[i].isLive {
            agentGraphRuns[i].seal(conclusion: .cancelled)
            sealed = true
        }
        if sealed {
            agentGraphRuns = SZAgentGraphRun.capped(SZAgentGraphRun.ordered(agentGraphRuns))
            persistAgentGraphRuns()
        }
    }

    // MARK: - The sidecar

    /// Sealed records only — a live record is never on disk.
    func persistAgentGraphRuns() {
        guard let projectURL = loadedProjectURL else { return }
        try? SZAgentGraphRunIO.save(agentGraphRuns.filter { !$0.isLive }, projectURL: projectURL)
    }

    /// Project open: replace the list wholesale with the new project's history (every
    /// restored record is sealed by construction).
    func restoreAgentGraphRuns() {
        guard let projectURL = loadedProjectURL else {
            agentGraphRuns = []
            return
        }
        // A record restored without an ending was truncated (nothing ever WRITES one that
        // way): resurrect it sealed, not live. A phantom live record would sit at the head
        // forever — exempt from eviction, pulsing, arming the follow-cam on a traversal
        // that will never grow. The decoder stays tolerant; the list invariant wins here.
        let restored = (SZAgentGraphRunIO.load(projectURL: projectURL) ?? []).map { record in
            guard record.isLive else { return record }
            var sealed = record
            sealed.seal(conclusion: .defect(detail: "the record was truncated"),
                        at: record.startedAt)
            return sealed
        }
        agentGraphRuns = SZAgentGraphRun.ordered(restored)
    }

    // MARK: - What the panel reads

    /// The Plan view's agents: every pack in the graph orchestrator's library, director
    /// first, distilled to the plain values the panel may see (SZUI never imports SZAI).
    /// Cached because view bodies read it hot; the cache is dropped wherever the
    /// user-editable materialized tree can move — pack materialization and each run start.
    func agentGraphPlanAgents() -> [SZAgentGraphPlanAgent] {
        _ = agentGraphPlanEpoch   // observe: the async declaration fill re-renders readers
        if let cached = agentGraphPlanCache { return cached }
        var agents: [SZAgentGraphPlanAgent] = []
        if let root = Self.graphAgentPacksRoot() {
            let loaded = SZAgentPackLoader.load(root: root)
            let ordered = loaded.packs.sorted {
                (($0.seat == .director) ? 0 : 1, $0.id) < (($1.seat == .director) ? 0 : 1, $1.id)
            }
            agents = ordered.map { pack in
                SZAgentGraphPlanAgent(
                    id: pack.id,
                    title: pack.id.isEmpty ? pack.id : pack.id.prefix(1).uppercased() + pack.id.dropFirst(),
                    symbol: Self.agentGraphSymbol(for: pack),
                    graphs: pack.graphs.map { .init(name: $0.name, graph: $0) },
                    // The front door each seat mostly exists for: the Director's build
                    // graph, the coding seat's item graph, else whatever comes first.
                    defaultGraphName: (pack.graph(routing: .build) ?? pack.graph(routing: .work)
                        ?? pack.graphs.first)?.name ?? "",
                    seat: pack.seat?.rawValue,
                    // Only the agent that opens builds carries a strategy chip, and only
                    // when its lane actually OFFERS strategies and one was requested — the
                    // shipped agentic-only pack shows nothing.
                    activeStrategy: pack.seat == .director && !directorBuildStrategyNames().isEmpty
                        ? activeRunGraphVariant() : nil)
            }
        }
        agentGraphPlanCache = agents
        fillAgentGraphStepOutcomes(into: agents)
        return agents
    }

    /// Attach the compiled steps' declared outcome sets to the cached plan, asynchronously:
    /// declarations come from the step runtime (a compile on first sight, cached after), so
    /// the panel renders immediately with wired ports and gains the unwired ones — the
    /// dimmed "this answer ends the run" ports — as the declarations warm.
    private func fillAgentGraphStepOutcomes(into agents: [SZAgentGraphPlanAgent]) {
        guard let root = Self.graphAgentPacksRoot() else { return }
        agentGraphPlanFill?.cancel()
        agentGraphPlanFill = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = SZHostStepRunning(packsRoot: root, runtime: stepRuntime)
            var enriched = agents
            for (a, agent) in enriched.enumerated() {
                for (g, entry) in agent.graphs.enumerated() {
                    var outcomes: [String: [String]] = [:]
                    for node in entry.graph.nodes {
                        guard case .step(let name) = node.form else { continue }
                        if let info = try? await steps.declaration(agent: agent.id, step: name) {
                            outcomes[node.id] = info.outcomes
                        }
                        if Task.isCancelled { return }
                    }
                    enriched[a].graphs[g].stepOutcomes = outcomes
                }
            }
            // The cache may have been invalidated (packs re-materialized, a run started)
            // while we compiled — enrich only the world we were asked about.
            guard !Task.isCancelled, agentGraphPlanCache?.map(\.id) == enriched.map(\.id) else { return }
            agentGraphPlanCache = enriched
            bumpAgentGraphPlanEpoch()
        }
    }

    /// A record's own graph, resolved through the same library the Plan view browses. nil =
    /// the library no longer carries it; the panel degrades to an honest empty canvas.
    func agentGraphResolve(_ run: SZAgentGraphRun) -> SZAgentGraph? {
        agentGraphPlanAgents().first { $0.id == run.agent }?
            .graphs.first { $0.name == run.graphName }?.graph
    }

    /// The seats' glyphs — the panel's one display fact the pack file doesn't carry.
    /// The app's established agent glyphs, matched to the chat surface: the Director's
    /// eyeglasses, the debug agent's ladybug — one identity per agent everywhere it appears.
    nonisolated private static func agentGraphSymbol(for pack: SZAgentPack) -> String {
        switch pack.seat {
        case .director: "eyeglasses"
        case .coding: "hammer"
        case nil: pack.id == "debug" ? "ladybug.fill" : "person"
        }
    }
}

/// The engine's note, respelled as the record's own trace entry — the SZAI→SZCore map the
/// record model asks its host to own. Wall-clock stamps stay the RECORD's business
/// (`note(_:at:)` stamps on first sight / settle), so SZAI's outputs remain date-free.
private extension SZAgentGraphRun.Entry {
    init(_ note: SZTraversalNote) {
        let phase: SZAgentGraphRun.Entry.Phase = switch note.phase {
        case .running: .running
        case .done: .done
        case .failed: .failed
        }
        self.init(ordinal: note.ordinal, node: note.node, phase: phase,
                  outcome: note.outcome, detail: note.detail, tally: note.tally)
    }
}
