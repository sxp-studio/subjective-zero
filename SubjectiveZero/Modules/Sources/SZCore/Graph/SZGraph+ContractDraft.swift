// SPDX-License-Identifier: AGPL-3.0-only
// Contract-first drafting — the procedural Director strategy's flow consumer. A freshly DRAWN
// prompt graph (prompt nodes wired with flow, no contracts/data edges yet) carries its typed I/O only
// implicitly, in the flow topology. This pure `SZGraph` transform makes it explicit UPFRONT: it gives
// every contract-less prompt node a texture contract derived from its flow edges and lays the companion
// data wiring, so the cards show their I/O immediately and the textures bind as the coding fleet fills
// in `Node.swift` — the graph visibly "comes to life" before any code exists. Sibling to the split/merge
// transforms (SZGraph+SplitMerge); the drafted boundary is what a promote merges the agent's contract into.
//
// Texture-output by ASSUMPTION — a deliberate shortcut for this path. Flow edges are type-agnostic
// ("A feeds B" says nothing about WHAT flows), and the procedural strategy has no oracle to infer types,
// so it assumes the dominant case: an image pipeline (texture in per upstream, one texture out). That is
// only acceptable because the procedural strategy is the **transitional** deterministic / offline / CI
// baseline, expected to be retired in favour of the agentic Director — which, being an LLM, declares each
// node's REAL typed I/O (texture / float / event / none) upfront with no guess. The assumption is
// contained here: it does NOT touch the contract model (textures stay optional — a node may have none)
// nor the Director path. Control knobs + permissions stay the coding agent's to author (the promote merge
// keeps both; see SZContract+PromoteMerge). Contract *renegotiation* happens later,
// in the Director's reconcile loop.
import Foundation

/// The draft port-naming convention — the ONE home for the literal names a drafted or seeded
/// contract mints. `draftContractsFromFlow` declares them in pass 1 and wires them in pass 2, and
/// `SZPromptSeed` mints a spawn's one-port contract with them; the coding-agent brief tells the
/// agent to keep them verbatim.
public enum SZDraftPortName {
    public static let output = "output"
    /// `input`, `input2`, … by incoming-arrow index: arrow k owns input k.
    public static func input(_ k: Int = 0) -> String {
        k == 0 ? "input" : "input\(k + 1)"
    }
}

extension SZGraph {
    /// Why a flow arrow was left as unresolved intent instead of realized into a data edge.
    public enum SZFlowSkipReason: Equatable, Sendable {
        /// The data edge would close a cycle.
        case wouldCloseCycle
        /// No compatible texture wiring: the source declares no texture output, or the target has no
        /// unwired texture input left to bind.
        case noCompatiblePort
    }

    /// Draft a texture contract for every contract-less PROMPT node from its FLOW edges, realize each flow
    /// arrow as a DATA edge (removing the now-resolved intent arrow) so the implemented textures bind, and
    /// — if no render endpoint is set yet —
    /// point it at a terminal drafted node so a freshly drawn pipeline renders without a manual display
    /// toggle. Contracts that already exist (generated, library, split/merge pieces, a re-run node, a
    /// data-spawn seed) are never rewritten, so this is idempotent across repeated runs — but arrows INTO
    /// an already-contracted prompt node are still pass 2's to realize, into its declared unwired texture
    /// inputs. An arrow that can't be realized — it would close a cycle, or no compatible texture port
    /// exists on either end — stays visible as unresolved intent, reported in `skipped` with its reason
    /// so the run can say why. Returns the reconciled graph + the ids newly given a contract + the
    /// skipped arrows.
    public func draftContractsFromFlow()
        -> (graph: SZGraph, drafted: [SZNodeID],
            skipped: [(from: SZNodeID, to: SZNodeID, reason: SZFlowSkipReason)]) {
        let order = Dictionary(uniqueKeysWithValues: nodes.map(\.id).enumerated().map { ($1, $0) })
        var g = self
        var drafted: [SZNodeID] = []

        // Pass 1 — a texture contract per contract-less prompt node: one input per incoming flow source
        // (named input, input2, …), one `output`. Title/summary are placeholders the agent refines.
        for i in g.nodes.indices {
            let n = g.nodes[i]
            guard n.kind == .prompt, n.contract == nil else { continue }
            let inputs = incomingFlowSources(of: n.id, order: order).indices.map {
                Self.texturePort(SZDraftPortName.input($0))
            }
            g.nodes[i].contract = SZNodeContract(
                title: n.title, sfSymbol: n.sfSymbol, summary: n.prompt ?? n.title,
                inputs: inputs, outputs: [Self.texturePort(SZDraftPortName.output)])
            drafted.append(n.id)
        }
        // Arrows INTO prompt nodes that already ship a contract (a data-spawn seed, a permission-
        // declaring camera) are realized too — into their declared unwired texture inputs, the
        // declaration respected, never rewritten — or reported, so drafting is never silent about
        // an arrow the user drew.
        let draftedSet = Set(drafted)
        let contracted = g.nodes.filter { n in
            n.kind == .prompt && n.contract != nil && !draftedSet.contains(n.id)
                && g.connections.contains { $0.kind == .flow && $0.to.node == n.id && $0.from.node != n.id }
        }.map(\.id)
        guard !drafted.isEmpty || !contracted.isEmpty else { return (g, [], []) }

        // Endpoint — if unset, blit a terminal drafted node (no outgoing flow). Mark its output `display`.
        if g.renderEndpoint == nil, !drafted.isEmpty {
            let terminals = drafted.filter { id in
                !g.connections.contains { $0.kind == .flow && $0.from.node == id }
            }
            if let tail = (terminals.isEmpty ? drafted : terminals).max(by: { order[$0]! < order[$1]! }) {
                g.setOutputDisplay(on: tail, port: SZDraftPortName.output)
                g.renderEndpoint = SZPortRef(node: tail, port: SZDraftPortName.output)
            }
        }

        // Pass 2 — realize each flow arrow as a DATA edge into a drafted or contracted target,
        // skipping pairs already data-connected. Drafted targets bind their pass-1 names (input,
        // input2, …); contracted targets bind their first unwired declared texture input. This is
        // the flow→data promotion that makes the textures actually bind. As with `SZStore.connect`,
        // realizing an arrow RESOLVES it: the flow intent edges are removed afterward (snapshot the
        // realized pairs first — flow is read here, removed only after the loop).
        var realized: [(from: SZNodeID, to: SZNodeID)] = []
        var skipped: [(from: SZNodeID, to: SZNodeID, reason: SZFlowSkipReason)] = []
        for nid in drafted + contracted {
            for (k, source) in incomingFlowSources(of: nid, order: order).enumerated() {
                let alreadyWired = g.connections.contains {
                    $0.kind == .data && $0.from.node == source && $0.to.node == nid
                }
                if alreadyWired { realized.append((source, nid)); continue }
                // Both ports resolved against the DRAFTED graph (a pass-1 source's contract lives
                // only in `g`). A source with no texture output, or a target with no free texture
                // input, can't carry this wiring — the arrow stays as intent instead of an edge
                // pointing at a phantom or mistyped port. Drafted targets keep the k-indexed names
                // deliberately (arrow k owns input k, so a cycle-skipped arrow leaves ITS slot
                // unwired); first-unwired would compact later arrows into earlier slots.
                let inputPort = draftedSet.contains(nid)
                    ? SZDraftPortName.input(k)
                    : g.firstUnwiredTextureInput(of: nid)
                guard let sourcePort = g.textureOutputPort(of: source), let inputPort else {
                    skipped.append((source, nid, .noCompatiblePort))
                    continue
                }
                // A realization that would close a data cycle is not laid: the arrow stays as
                // unresolved intent (its input stays unwired), and the pair is reported.
                guard g.wouldCloseCycle(from: source, to: nid) == nil else {
                    skipped.append((source, nid, .wouldCloseCycle))
                    continue
                }
                realized.append((source, nid))
                g.connections.append(SZConnection(
                    from: SZPortRef(node: source, port: sourcePort),
                    to: SZPortRef(node: nid, port: inputPort),
                    kind: .data))
            }
        }
        g.connections.removeAll { c in
            c.kind == .flow && realized.contains { $0.from == c.from.node && $0.to == c.to.node }
        }
        return (g, drafted, skipped)
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

    /// The name of `id`'s first texture output, resolved against THIS graph's contracts — nil when the
    /// node declares none, in which case a flow arrow out of it has no texture wiring to realize.
    /// The plain FIRST texture output, not `preferredTextureOutput`'s display-marked pick: the two
    /// disagree on multi-output sources, and drafting wires from the first.
    private func textureOutputPort(of id: SZNodeID) -> String? {
        node(id: id)?.contract?.outputs.first { $0.type == .texture }?.name
    }

    /// The name of `id`'s first texture input with no incoming data edge, in declaration order — the
    /// slot pass 2 binds when realizing an arrow into an already-contracted prompt node.
    private func firstUnwiredTextureInput(of id: SZNodeID) -> String? {
        node(id: id)?.contract?.inputs.first { p in
            p.type == .texture && !connections.contains {
                $0.kind == .data && $0.to == SZPortRef(node: id, port: p.name)
            }
        }?.name
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
