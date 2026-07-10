// SPDX-License-Identifier: AGPL-3.0-only
// Which of a run's nodes the viewport should show when the run finishes. Pure graph logic, so the rule is
// testable on its own; the host owns the policy around it (the Director's explicit choice wins, and the
// change is pushed live + persisted).
import Foundation

extension SZGraph {
    /// The output to display for a run that implemented `workSet`, or nil when the run produced nothing
    /// worth showing.
    ///
    /// A node qualifies only if it is a graph SINK — it feeds nothing. A node built upstream of an existing
    /// composite (a blur spliced into a live chain) is the last node the run touched but not the graph's
    /// output; showing it would hide the very result it feeds. Among sinks, the newest wins, `nodes` being
    /// append-ordered. Prefers a `display`-marked texture output, else any texture output.
    ///
    /// Only `.generated` nodes qualify — a node is promoted to that kind when its source compiles. A drawn
    /// node is given a texture contract BEFORE the run (`draftContractsFromFlow`), so a run whose agent
    /// timed out leaves a `.prompt` node that declares an output it cannot render. Adopting it would trade
    /// whatever the user was watching for a black viewport.
    public func runRenderEndpoint(workSet: Set<SZNodeID>) -> SZPortRef? {
        let built = nodes.filter {
            $0.kind == .generated && workSet.contains($0.id)
                && $0.contract?.outputs.contains { $0.type == .texture } == true
        }
        let sinks = built.filter { node in
            !connections.contains { $0.kind == .data && $0.from.node == node.id }
        }
        guard let winner = sinks.last else { return nil }
        let outputs = winner.contract?.outputs ?? []
        guard let port = outputs.first(where: { $0.type == .texture && $0.display == true })
                ?? outputs.first(where: { $0.type == .texture }) else { return nil }
        return SZPortRef(node: winner.id, port: port.name)
    }
}
