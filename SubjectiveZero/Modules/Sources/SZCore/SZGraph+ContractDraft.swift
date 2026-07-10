// SPDX-License-Identifier: AGPL-3.0-only
// Contract-first drafting — the procedural Director strategy's flow consumer. A freshly DRAWN
// prompt graph (prompt nodes wired with flow, no contracts/data edges yet) carries its typed I/O only
// implicitly, in the flow topology. This pure `SZGraph` transform makes it explicit UPFRONT: it gives
// every contract-less prompt node a texture contract derived from its flow edges and lays the companion
// data wiring, so the cards show their I/O immediately and the textures bind as the coding fleet fills
// in `Node.swift` — the graph visibly "comes to life" before any code exists. Sibling to the split/merge
// transforms (SZGraph+SplitMerge); the host pins the drafted boundary (reusing `pinnedContracts`).
//
// Texture-output by ASSUMPTION — a deliberate shortcut for this path. Flow edges are type-agnostic
// ("A feeds B" says nothing about WHAT flows), and the procedural strategy has no oracle to infer types,
// so it assumes the dominant case: an image pipeline (texture in per upstream, one texture out). That is
// only acceptable because the procedural strategy is the **transitional** deterministic / offline / CI
// baseline, expected to be retired in favour of the agentic Director — which, being an LLM, declares each
// node's REAL typed I/O (texture / float / event / none) upfront with no guess. The assumption is
// contained here: it does NOT touch the contract model (textures stay optional — a node may have none)
// nor the Director path. Control knobs + permissions stay the coding agent's to author (the host doesn't
// pin an empty permission set; see SZHost.promoteStagedNode). Contract *renegotiation* happens later,
// in the Director's reconcile loop.
import Foundation

extension SZGraph {
    /// Draft a texture contract for every contract-less PROMPT node from its FLOW edges, realize each flow
    /// arrow as a DATA edge (removing the now-resolved intent arrow) so the implemented textures bind, and
    /// — if no render endpoint is set yet —
    /// point it at a terminal drafted node so a freshly drawn pipeline renders without a manual display
    /// toggle. Nodes that already ship a contract (generated, library, split/merge pieces, a re-run node)
    /// are left untouched, so this is idempotent across repeated runs. Returns the reconciled graph + the
    /// ids newly given a contract (the host pins exactly those).
    public func draftContractsFromFlow() -> (graph: SZGraph, drafted: [SZNodeID]) {
        let order = Dictionary(uniqueKeysWithValues: nodes.map(\.id).enumerated().map { ($1, $0) })
        var g = self
        var drafted: [SZNodeID] = []

        // Pass 1 — a texture contract per contract-less prompt node: one input per incoming flow source
        // (named input, input2, …), one `output`. Title/summary are placeholders the agent refines.
        for i in g.nodes.indices {
            let n = g.nodes[i]
            guard n.kind == .prompt, n.contract == nil else { continue }
            let inputs = incomingFlowSources(of: n.id, order: order).indices.map {
                Self.texturePort($0 == 0 ? "input" : "input\($0 + 1)")
            }
            g.nodes[i].contract = SZNodeContract(
                title: n.title, sfSymbol: n.sfSymbol, summary: n.prompt ?? n.title,
                inputs: inputs, outputs: [Self.texturePort("output")])
            drafted.append(n.id)
        }
        guard !drafted.isEmpty else { return (g, []) }

        // Endpoint — if unset, blit a terminal drafted node (no outgoing flow). Mark its output `display`.
        if g.renderEndpoint == nil {
            let terminals = drafted.filter { id in
                !g.connections.contains { $0.kind == .flow && $0.from.node == id }
            }
            if let tail = (terminals.isEmpty ? drafted : terminals).max(by: { order[$0]! < order[$1]! }) {
                g.setOutputDisplay(on: tail, port: "output")
                g.renderEndpoint = SZPortRef(node: tail, port: "output")
            }
        }

        // Pass 2 — realize each flow arrow as a DATA edge into a drafted node, matching the drafted port
        // names (source's existing texture output, else its drafted `output`), skipping pairs already
        // data-connected. This is the flow→data promotion that makes the textures actually bind. As with
        // `SZStore.connect`, realizing an arrow RESOLVES it: the flow intent edges are removed afterward
        // (snapshot the realized pairs first — flow is read here, removed only after the loop).
        var realized: [(from: SZNodeID, to: SZNodeID)] = []
        for nid in drafted {
            for (k, source) in incomingFlowSources(of: nid, order: order).enumerated() {
                realized.append((source, nid))
                let alreadyWired = g.connections.contains {
                    $0.kind == .data && $0.from.node == source && $0.to.node == nid
                }
                guard !alreadyWired else { continue }
                g.connections.append(SZConnection(
                    from: SZPortRef(node: source, port: textureOutputPort(of: source)),
                    to: SZPortRef(node: nid, port: k == 0 ? "input" : "input\(k + 1)"),
                    kind: .data))
            }
        }
        g.connections.removeAll { c in
            c.kind == .flow && realized.contains { $0.from == c.from.node && $0.to == c.to.node }
        }
        return (g, drafted)
    }

    // MARK: - Helpers

    /// Distinct source nodes of flow edges INTO `id`, ordered by declaration index for determinism.
    private func incomingFlowSources(of id: SZNodeID, order: [SZNodeID: Int]) -> [SZNodeID] {
        var seen = Set<SZNodeID>(), sources: [SZNodeID] = []
        for c in connections where c.kind == .flow && c.to.node == id && c.from.node != id {
            if seen.insert(c.from.node).inserted { sources.append(c.from.node) }
        }
        return sources.sorted { order[$0, default: 0] < order[$1, default: 0] }
    }

    /// The name of `id`'s first texture output (its real contract's, else the drafted default `output`).
    private func textureOutputPort(of id: SZNodeID) -> String {
        node(id: id)?.contract?.outputs.first { $0.type == .texture }?.name ?? "output"
    }

    private mutating func setOutputDisplay(on id: SZNodeID, port: String) {
        guard let ni = nodes.firstIndex(where: { $0.id == id }),
              var contract = nodes[ni].contract,
              let pi = contract.outputs.firstIndex(where: { $0.name == port }) else { return }
        contract.outputs[pi].display = true
        nodes[ni].contract = contract
    }

    private static func texturePort(_ name: String) -> SZPort { SZPort(name: name, type: .texture) }
}
