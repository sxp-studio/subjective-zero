// SPDX-License-Identifier: AGPL-3.0-only
// The agent-graph RUNS records — where the delivery's observation hooks become
// `SZAgentGraphRun` values the Agent Graph panel draws and `runs.json` archives. The
// engine's note type (SZAI) maps onto the record's own trace entry (SZCore) here, and
// nowhere else. Live records persist too — written at begin, coalesced per note, and
// immediately at seal — so a crash mid-run leaves the run on disk to be restored as
// interrupted; the history caps per budget and is replaced wholesale on project switch.
import Foundation
import SZAI
import SZCore
import SZUI

extension SZHost {
    // MARK: - Record lifecycle

    /// A traversal began — open its live record. `thread` groups a build with the work
    /// children it dispatched (the build passes its OWN record id, which is what makes it
    /// the thread's leader); a conversation passes nil and never joins a thread.
    func beginAgentGraphRun(_ sighting: SZTraversalSighting, thread: UUID?) {
        let record = SZAgentGraphRun(id: sighting.id, agent: sighting.agent,
                                     thread: thread, work: sighting.work)
        agentGraphRuns = SZAgentGraphRun.ordered(agentGraphRuns + [record])
        persistAgentGraphRuns()
    }

    /// One traversal note → the record's own trace entry (the SZAI→SZCore mapping). The
    /// record's sealed guard and stamp-preserving merge do the rest.
    func noteAgentGraphRun(_ id: UUID, _ note: SZTraversalNote) {
        guard let i = agentGraphRuns.firstIndex(where: { $0.id == id }) else { return }
        agentGraphRuns[i].note(SZAgentGraphRun.Entry(note))
        persistAgentGraphRunsSoon()
    }

    /// The traversal concluded — seal, re-order (it just stopped being live), cap, persist,
    /// and carry a work child's bad news onto the node it served.
    func concludeAgentGraphRun(_ id: UUID, _ ending: SZTraversalEnding) {
        guard let i = agentGraphRuns.firstIndex(where: { $0.id == id }) else { return }
        agentGraphRuns[i].seal(conclusion: SZAgentGraphRun.Conclusion(ending))
        surfaceWorkFailure(agentGraphRuns[i], ending)
        agentGraphRuns = SZAgentGraphRun.capped(SZAgentGraphRun.ordered(agentGraphRuns))
        persistAgentGraphRuns()
    }

    /// A failed work child knows WHY it failed; without this the post-run sweep paints the
    /// node with its generic never-compiled line and the reason is lost. An agent's OWN
    /// report always wins; cancelled work says nothing (a stopped run is not a failed node).
    private func surfaceWorkFailure(_ record: SZAgentGraphRun, _ ending: SZTraversalEnding) {
        guard let id = record.work, let node = UUID(uuidString: id),
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

    /// Run-task drain: seal anything of THIS run's still live as cancelled. A no-op on
    /// every healthy path (each traversal seals itself as its engine returns) — the belt
    /// for the task unwinding abnormally. Thread-scoped, so a zombie draining after a
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

    /// Write the whole list, live records included; cancels a pending coalesced write.
    func persistAgentGraphRuns() {
        agentGraphRunsPersistDebounce?.cancel()
        agentGraphRunsPersistDebounce = nil
        guard let projectURL = loadedProjectURL else { return }
        try? SZAgentGraphRunIO.save(agentGraphRuns, projectURL: projectURL)
    }

    /// The coalesced write — `note` fires per node visit; one pending write, ≤1 s behind.
    private func persistAgentGraphRunsSoon() {
        guard agentGraphRunsPersistDebounce == nil else { return }
        agentGraphRunsPersistDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.persistAgentGraphRuns()
        }
    }

    /// Project open: replace the list wholesale with the new project's history.
    func restoreAgentGraphRuns() {
        guard let projectURL = loadedProjectURL else {
            agentGraphRuns = []
            return
        }
        // A record restored live was in flight when the app closed: resurrect it sealed as
        // interrupted, not live — a phantom live record would pulse forever.
        let restored = (SZAgentGraphRunIO.load(projectURL: projectURL) ?? []).map { record in
            var sealed = record
            sealed.sealInterrupted()
            return sealed
        }
        agentGraphRuns = SZAgentGraphRun.ordered(restored)
    }

    // MARK: - What the panel reads

    /// The Plan view's agents: every pack in the library, director first, distilled to the
    /// plain values the panel may see (SZUI never imports SZAI). Cached because view bodies
    /// read it hot; the cache is dropped wherever the materialized tree can move.
    func agentGraphPlanAgents() -> [SZAgentGraphPlanAgent] {
        _ = agentGraphPlanEpoch   // observe: the async declaration fill re-renders readers
        if let cached = agentGraphPlanCache { return cached }
        var agents: [SZAgentGraphPlanAgent] = []
        if let root = Self.graphAgentPacksRoot() {
            let loaded = SZAgentPackLoader.load(root: root)
            let ordered = loaded.packs.sorted {
                (($0.seat == .director) ? 0 : 1, $0.id) < (($1.seat == .director) ? 0 : 1, $1.id)
            }
            agents = ordered.compactMap { pack in
                guard let graph = pack.graph else { return nil }
                return SZAgentGraphPlanAgent(
                    id: pack.id,
                    title: pack.id.isEmpty ? pack.id : pack.id.prefix(1).uppercased() + pack.id.dropFirst(),
                    symbol: Self.agentGraphSymbol(for: pack),
                    graph: graph,
                    seat: pack.seat?.rawValue)
            }
        }
        agentGraphPlanCache = agents
        fillAgentGraphStepOutcomes(into: agents)
        return agents
    }

    /// Attach the compiled steps' declared outcome sets to the cached plan, asynchronously:
    /// declarations come from the step runtime (a compile on first sight, cached after), so
    /// the panel renders immediately with wired ports and gains the unwired — dimmed —
    /// ones as the declarations warm.
    private func fillAgentGraphStepOutcomes(into agents: [SZAgentGraphPlanAgent]) {
        guard let root = Self.graphAgentPacksRoot() else { return }
        agentGraphPlanFill?.cancel()
        agentGraphPlanFill = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = SZHostStepRunning(packsRoot: root, runtime: stepRuntime)
            var enriched = agents
            for (a, agent) in enriched.enumerated() {
                var outcomes: [String: [String]] = [:]
                for node in agent.graph.nodes {
                    guard case .step(let name) = node.form else { continue }
                    if let info = try? await steps.declaration(agent: agent.id, step: name) {
                        outcomes[node.id] = info.outcomes
                    }
                    if Task.isCancelled { return }
                }
                enriched[a].stepOutcomes = outcomes
            }
            // The cache may have been invalidated while we compiled — enrich only the
            // world we were asked about.
            guard !Task.isCancelled, agentGraphPlanCache?.map(\.id) == enriched.map(\.id) else { return }
            agentGraphPlanCache = enriched
            bumpAgentGraphPlanEpoch()
        }
    }

    /// A record's own graph, resolved through the same library the Plan view browses. nil =
    /// the library no longer carries it; the panel degrades to an honest empty canvas.
    func agentGraphResolve(_ run: SZAgentGraphRun) -> SZAgentGraph? {
        agentGraphPlanAgents().first { $0.id == run.agent }?.graph
    }

    /// The seats' glyphs — the app's established agent identities.
    nonisolated private static func agentGraphSymbol(for pack: SZAgentPack) -> String {
        switch pack.seat {
        case .director: "eyeglasses"
        case .coding: "hammer"
        case nil: pack.id == "debug" ? "ladybug.fill" : "person"
        }
    }
}

/// The engine's note, respelled as the record's own trace entry — the SZAI→SZCore map the
/// record model asks its host to own. Wall-clock stamps stay the RECORD's business.
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
