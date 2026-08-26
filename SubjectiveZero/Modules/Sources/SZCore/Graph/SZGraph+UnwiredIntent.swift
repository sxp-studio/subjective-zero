// SPDX-License-Identifier: AGPL-3.0-only
// Which drawn arrows nobody wired. An arrow asks for a data edge; laying that edge clears it, so one
// still standing when a run settles is work the run never finished. Pure graph logic, so the run gate
// and the reconcile brief cannot disagree about the list.
//
// A run has two moments. Admission asks the whole graph (`into:`); everything after asks only the
// arrows that run captured at its start (`among:`), so one the user draws mid-run belongs to the next
// run — the rule the work set already follows for nodes. Only users draw arrows, so a start-of-run
// snapshot cannot miss the fleet's own.
import Foundation

extension SZGraph {
    /// Flow arrows landing on `nodes` that were never realized into data wiring.
    public func unwiredIntent(into nodes: Set<SZNodeID>) -> [SZConnection] {
        standingArrows { nodes.contains($0.to.node) }
    }

    /// Those of `arrows` still standing. One since wired or deleted is gone from the graph, so a run's
    /// owed list shrinks on its own.
    public func unwiredIntent(among arrows: Set<SZConnectionID>) -> [SZConnection] {
        standingArrows { arrows.contains($0.id) }
    }

    /// The distinct nodes those arrows land on, in declaration order — the run gate's evidence.
    public func unwiredNodes(in nodes: Set<SZNodeID>) -> [SZNodeID] {
        targets(of: unwiredIntent(into: nodes))
    }

    /// The distinct nodes the captured arrows still land on.
    public func unwiredNodes(among arrows: Set<SZConnectionID>) -> [SZNodeID] {
        targets(of: unwiredIntent(among: arrows))
    }

    /// Every node carrying an unwired arrow — what a run's admission reads, before work is scoped.
    public var nodesWithUnwiredIntent: [SZNodeID] { unwiredNodes(in: Set(nodes.map(\.id))) }

    /// Whether the wire this arrow asks for would ring, so nothing can ever answer it. Judged over data
    /// alone: that is the wire to be laid, and the other arrows are requests, not obstacles.
    public func isStuckIntent(_ arrow: SZConnection) -> Bool {
        arrow.kind == .flow && wouldCloseCycle(from: arrow.from.node, to: arrow.to.node) != nil
    }

    /// Arrows nothing can ever answer — what Build names instead of saying there is nothing to do.
    public var stuckIntent: [SZConnection] {
        unwiredIntent(into: Set(nodes.map(\.id))).filter(isStuckIntent)
    }

    // MARK: - Helpers

    /// Matching arrows, ordered by target then source declaration index so saves do not churn. Two
    /// never count: one pointing at its own node, and one the data already satisfies (an arrow can
    /// outlive its own wiring, since laying an edge that exists returns before the discharge).
    private func standingArrows(_ include: (SZConnection) -> Bool) -> [SZConnection] {
        let order = Dictionary(uniqueKeysWithValues: nodes.map(\.id).enumerated().map { ($1, $0) })
        let data = connections.filter { $0.kind == .data }
        return connections
            .filter { arrow in
                arrow.kind == .flow && arrow.from.node != arrow.to.node && include(arrow)
                    && !data.contains { arrow.isFlowIntent(realizedBy: $0.from, $0.to) }
            }
            .sorted {
                (order[$0.to.node, default: 0], order[$0.from.node, default: 0])
                    < (order[$1.to.node, default: 0], order[$1.from.node, default: 0])
            }
    }

    private func targets(of arrows: [SZConnection]) -> [SZNodeID] {
        var seen: Set<SZNodeID> = []
        return arrows.compactMap { seen.insert($0.to.node).inserted ? $0.to.node : nil }
    }
}
