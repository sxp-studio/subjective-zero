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
    func beginAgentGraphRun(_ sighting: SZTraversalSighting) {
        let record = SZAgentGraphRun(id: sighting.id, agent: sighting.agent,
                                     graphName: sighting.graphName, kind: sighting.kind,
                                     thread: runID, item: sighting.item)
        agentGraphRuns = SZAgentGraphRun.ordered(agentGraphRuns + [record])
    }

    /// One traversal note → the record's own trace entry (the SZAI→SZCore mapping). The
    /// record's sealed guard and stamp-preserving merge do the rest.
    func noteAgentGraphRun(_ id: UUID, _ note: SZTraversalNote) {
        guard let i = agentGraphRuns.firstIndex(where: { $0.id == id }) else { return }
        agentGraphRuns[i].note(SZAgentGraphRun.Entry(note))
    }

    /// The traversal concluded — seal, re-order (it just stopped being live), cap, persist.
    func concludeAgentGraphRun(_ id: UUID, _ ending: SZTraversalEnding) {
        guard let i = agentGraphRuns.firstIndex(where: { $0.id == id }) else { return }
        agentGraphRuns[i].seal(conclusion: SZAgentGraphRun.Conclusion(ending))
        agentGraphRuns = SZAgentGraphRun.capped(SZAgentGraphRun.ordered(agentGraphRuns))
        persistAgentGraphRuns()
    }

    /// The machine's live settlement count for a dispatch set, amended onto the SENDING
    /// traversal's record — the one sanctioned post-seal write, re-persisted each time so
    /// the archive's tally is as current as the panel's.
    func amendAgentGraphRunTally(_ id: UUID, settled: Int, total: Int, failed: Int) {
        guard let i = agentGraphRuns.firstIndex(where: { $0.id == id }) else { return }
        agentGraphRuns[i].amendDispatchTally(settled: settled, total: total, failed: failed)
        persistAgentGraphRuns()
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
        agentGraphRuns = SZAgentGraphRun.ordered(SZAgentGraphRunIO.load(projectURL: projectURL) ?? [])
    }

    // MARK: - What the panel reads

    /// The Plan view's agents: every pack in the graph orchestrator's library, director
    /// first, distilled to the plain values the panel may see (SZUI never imports SZAI).
    /// Built once per launch — the packs root is env-static.
    func agentGraphPlanAgents() -> [SZAgentGraphPlanAgent] {
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
                    symbol: Self.agentGraphSymbol(for: pack.seat),
                    graphs: pack.graphs.map { .init(name: $0.name, graph: $0) },
                    // The front door each seat mostly exists for: the Director's build
                    // graph, the coding seat's item graph, else whatever comes first.
                    defaultGraphName: (pack.graph(handling: .build) ?? pack.graph(handling: .item)
                        ?? pack.graphs.first)?.name ?? "")
            }
        }
        agentGraphPlanCache = agents
        return agents
    }

    /// A record's own graph, resolved through the same library the Plan view browses. nil =
    /// the library no longer carries it; the panel degrades to an honest empty canvas.
    func agentGraphResolve(_ run: SZAgentGraphRun) -> SZAgentGraph? {
        agentGraphPlanAgents().first { $0.id == run.agent }?
            .graphs.first { $0.name == run.graphName }?.graph
    }

    /// The seats' glyphs — the panel's one display fact the pack file doesn't carry.
    nonisolated private static func agentGraphSymbol(for seat: SZAgentSeat?) -> String {
        switch seat {
        case .director: "person.badge.shield.checkmark"
        case .coding: "hammer"
        case nil: "person"
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
                  outcome: note.outcome, detail: note.detail)
    }
}
