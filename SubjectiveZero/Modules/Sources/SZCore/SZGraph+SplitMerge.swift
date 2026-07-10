// SPDX-License-Identifier: AGPL-3.0-only
// Split / merge as pure structural graph transforms (docs/GRAPH_AND_NODES.md "split/merge as
// graph transactions"). Methods on the value-type `SZGraph` itself — they ARE operations on a graph,
// alongside `node(id:)` — so there's no separate helper noun and no store/actor coupling. Non-mutating
// (return a reconciled copy) so the store ops (`SZStore.splitNode`/`mergeNodes`) can commit them
// atomically in one `mutate {…}`; the host wrappers add the disk re-save + runtime reload.
//
// These draft only the STRUCTURAL boundary — typed contracts + rewiring — so external type-compat is
// preserved by construction. The pieces are prompt (dirty) nodes with NO prompt text here: the host
// authors each piece's intent-carrying seed prompt from templates (SZAI) on re-save, and the coding
// agents author the real title/contract/source at Run.
import Foundation

extension SZGraph {

    // MARK: - Split (staged → committed)
    //
    // Two phases so the GUI can show the *original* with a "Splitting" pill while the Director implements
    // the new stages, then swap in the finished cards (deferred-commit UX). `stageSplit` ADDS the
    // stage nodes (with internal wiring + drafted boundary contracts) but leaves the original fully wired
    // and rendering; `commitSplit` rewires the original's external edges to the stages, moves the render
    // endpoint, and removes the original. `split` composes both for the one-shot/structural path + tests.

    /// Add the `pieces` (≥2) stage prompt nodes (internal texture wiring + drafted boundary contracts),
    /// leaving the original node + its external connections + the render endpoint untouched. Returns the
    /// staged graph + the new stage ids (first→last), or nil if the node is missing / `pieces < 2`.
    public func stageSplit(node id: SZNodeID, into pieces: Int) -> (graph: SZGraph, pieceIDs: [SZNodeID])? {
        guard pieces >= 2, let n = node(id: id) else { return nil }

        // External boundary of N — from its contract when generated, else derived from its wiring. First
        // stage keeps N's external inputs (+ permissions); last keeps N's external outputs; the rest
        // expose only the texture boundary ports.
        let externalInputs = n.contract?.inputs ?? derivedInputs(of: id)
        let externalOutputs = n.contract?.outputs ?? derivedOutputs(of: id)
        let permissions = n.contract?.permissions
        let stages: [SZNode] = (0..<pieces).map { k in
            let inputs = (k == 0) ? externalInputs : [Self.boundaryPort("input")]
            let outputs = (k == pieces - 1) ? externalOutputs : [Self.boundaryPort("output")]
            let title = "\(n.title) (\(k + 1)/\(pieces))"
            return SZNode(
                kind: .prompt, title: title, sfSymbol: "sparkles", prompt: nil,
                contract: SZNodeContract(
                    title: title, sfSymbol: "sparkles",
                    summary: "Stage \(k + 1) of \(pieces) of \(n.title).",
                    inputs: inputs, outputs: outputs,
                    permissions: (k == 0) ? permissions : nil),
                position: SZPoint(x: n.position.x + Double(k) * 240, y: n.position.y))
        }

        var g = self
        for k in 0..<(pieces - 1) {   // internal texture edge between adjacent stages
            g.connections.append(SZConnection(
                from: SZPortRef(node: stages[k].id, port: "output"),
                to: SZPortRef(node: stages[k + 1].id, port: "input"), kind: .data))
        }
        g.nodes.append(contentsOf: stages)
        return (g, stages.map(\.id))
    }

    /// Finish a staged split: retarget the original's external edges (incoming → first stage, outgoing →
    /// last stage), move the render endpoint to the last stage, and remove the original. Returns the
    /// committed graph, or nil if the original or the stages are missing.
    public func commitSplit(original id: SZNodeID, pieces: [SZNodeID]) -> SZGraph? {
        guard node(id: id) != nil, let first = pieces.first, let last = pieces.last,
              pieces.allSatisfy({ node(id: $0) != nil }) else { return nil }
        var g = self
        for i in g.connections.indices {
            if g.connections[i].to.node == id { g.connections[i].to.node = first }
            if g.connections[i].from.node == id { g.connections[i].from.node = last }
        }
        if g.renderEndpoint?.node == id { g.renderEndpoint?.node = last }
        g.nodes.removeAll { $0.id == id }
        return g
    }

    /// One-shot split (stage + commit). External inputs feed the first stage, the last stage feeds
    /// external outputs (+ render endpoint), stages are texture-connected between. Returns the reconciled
    /// graph + piece ids, or nil if the node is missing / `pieces < 2`.
    public func split(node id: SZNodeID, into pieces: Int) -> (graph: SZGraph, pieceIDs: [SZNodeID])? {
        guard let staged = stageSplit(node: id, into: pieces),
              let committed = staged.graph.commitSplit(original: id, pieces: staged.pieceIDs) else { return nil }
        return (committed, staged.pieceIDs)
    }

    // MARK: - Merge (staged → committed)

    /// Add the merged prompt node (drafted boundary contract from the chain's external boundary), leaving
    /// the constituents + their connections untouched. Returns the staged graph + the merged id, or nil
    /// for fewer than 2 distinct/known ids or ids that don't form a single linear data chain.
    public func stageMerge(nodes ids: [SZNodeID]) -> (graph: SZGraph, mergedID: SZNodeID)? {
        let set = Set(ids)
        guard set.count >= 2, set.allSatisfy({ node(id: $0) != nil }),
              let ordered = orderedChain(set) else { return nil }
        let members = ordered.compactMap { node(id: $0) }

        // Reconcile the boundary. INPUTS: keep every constituent input that ISN'T fed by an INTERNAL
        // edge — that preserves both externally-fed inputs AND unconnected control knobs (mirror,
        // aspectFit, …), dropping only the internal-boundary inputs (e.g. grayscale's `input` fed by the
        // camera). Full `SZPort` so the control's type/ui/default survive. OUTPUTS: ports feeding OUTSIDE
        // the set (+ the render endpoint if it sits on a member).
        var inputs: [SZPort] = [], outputs: [SZPort] = []
        var inSeen = Set<String>(), outSeen = Set<String>()
        for member in members {
            for p in member.contract?.inputs ?? [] {
                let internallyFed = connections.contains {
                    $0.kind == .data && set.contains($0.from.node) && $0.to.node == member.id && $0.to.port == p.name
                }
                if !internallyFed, inSeen.insert(p.name).inserted { inputs.append(p) }
            }
        }
        for c in connections where c.kind == .data {
            if set.contains(c.from.node), !set.contains(c.to.node), outSeen.insert(c.from.port).inserted {
                outputs.append(port(named: c.from.port, on: c.from.node, isInput: false))
            }
        }
        if let ep = renderEndpoint, set.contains(ep.node) {
            if let i = outputs.firstIndex(where: { $0.name == ep.port }) {
                outputs[i].display = true
            } else if outSeen.insert(ep.port).inserted {
                var p = port(named: ep.port, on: ep.node, isInput: false)
                p.display = true
                outputs.append(p)
            }
        }
        let permissions = Self.mergedPermissions(members)
        let title = members.map(\.title).joined(separator: " + ")
        let m = SZNode(
            kind: .prompt, title: title, sfSymbol: "sparkles", prompt: nil,
            contract: SZNodeContract(
                title: title, sfSymbol: "sparkles", summary: "Merged from \(members.count) nodes.",
                inputs: inputs, outputs: outputs,
                permissions: permissions.isEmpty ? nil : permissions),
            position: centroid(of: ordered) ?? members[0].position)

        var g = self
        g.nodes.append(m)
        return (g, m.id)
    }

    /// Finish a staged merge: drop the internal edges among the constituents, rewire their external edges
    /// to the merged node, move the render endpoint to it, and remove the constituents. Returns the
    /// committed graph, or nil if the merged node or a constituent is missing.
    public func commitMerge(constituents ids: [SZNodeID], merged: SZNodeID) -> SZGraph? {
        let set = Set(ids)
        guard node(id: merged) != nil, set.allSatisfy({ node(id: $0) != nil }) else { return nil }
        var g = self
        g.connections.removeAll { set.contains($0.from.node) && set.contains($0.to.node) }
        for i in g.connections.indices {
            if set.contains(g.connections[i].from.node) { g.connections[i].from.node = merged }
            if set.contains(g.connections[i].to.node) { g.connections[i].to.node = merged }
        }
        if let ep = g.renderEndpoint, set.contains(ep.node) { g.renderEndpoint?.node = merged }
        g.nodes.removeAll { set.contains($0.id) }
        return g
    }

    /// One-shot merge (stage + commit). External connections rewire to the merged node, internal edges
    /// drop, the render endpoint moves to it. Returns the reconciled graph + merged id, or nil for an
    /// invalid chain.
    public func merge(nodes ids: [SZNodeID]) -> (graph: SZGraph, mergedID: SZNodeID)? {
        guard let staged = stageMerge(nodes: ids),
              let committed = staged.graph.commitMerge(constituents: ids, merged: staged.mergedID) else { return nil }
        return (committed, staged.mergedID)
    }

    // MARK: - Shared graph geometry / edges

    /// Average position of the given nodes (nil if none are present). The position-only aggregate used by
    /// merge placement; the bounding-box variant that zoom-to-fit / tidy need lives in SZUI (it requires
    /// each node's rendered size from `SZNodeLayout`).
    public func centroid(of ids: some Sequence<SZNodeID>) -> SZPoint? {
        let positions = ids.compactMap { node(id: $0)?.position }
        guard !positions.isEmpty else { return nil }
        let n = Double(positions.count)
        return SZPoint(x: positions.reduce(0) { $0 + $1.x } / n,
                       y: positions.reduce(0) { $0 + $1.y } / n)
    }

    /// Add a flow (drawing-intent) edge between two nodes if one doesn't already exist.
    /// A pure graph edit. No longer called by prod graph edits (data no longer spawns a companion flow);
    /// retained as a shared helper for constructing intent edges (e.g. test fixtures).
    mutating func ensureFlow(from: SZNodeID, to: SZNodeID) {
        let exists = connections.contains { $0.kind == .flow && $0.from.node == from && $0.to.node == to }
        guard !exists else { return }
        connections.append(SZConnection(
            from: SZPortRef(node: from, port: "flow"), to: SZPortRef(node: to, port: "flow"), kind: .flow))
    }

    // MARK: - Reconciliation helpers (private, pure)

    /// Order a node set into a single linear data chain, or nil if it isn't one (branch / cycle /
    /// disconnected / not exactly n-1 internal data edges).
    private func orderedChain(_ set: Set<SZNodeID>) -> [SZNodeID]? {
        var pairs = Set<[SZNodeID]>()   // unique internal directed [from, to] data edges
        for c in connections where c.kind == .data && set.contains(c.from.node) && set.contains(c.to.node) {
            if c.from.node == c.to.node { return nil }
            pairs.insert([c.from.node, c.to.node])
        }
        guard pairs.count == set.count - 1 else { return nil }
        var succ: [SZNodeID: SZNodeID] = [:], pred: [SZNodeID: SZNodeID] = [:]
        for p in pairs {
            if succ[p[0]] != nil || pred[p[1]] != nil { return nil }   // a fork → not linear
            succ[p[0]] = p[1]; pred[p[1]] = p[0]
        }
        let heads = set.filter { pred[$0] == nil }
        guard heads.count == 1, var cur = heads.first else { return nil }
        var order = [cur]
        while let nxt = succ[cur] {
            order.append(nxt); cur = nxt
            if order.count > set.count { return nil }   // cycle guard
        }
        return order.count == set.count ? order : nil
    }

    /// Resolve a port's declared shape from the owning node's contract (type/ui carried over; input
    /// defaults preserved). Falls back to a plain texture port. Output `display` is managed by the caller.
    private func port(named name: String, on owner: SZNodeID, isInput: Bool) -> SZPort {
        let ports = isInput ? node(id: owner)?.contract?.inputs : node(id: owner)?.contract?.outputs
        if let p = ports?.first(where: { $0.name == name }) {
            return SZPort(name: p.name, type: p.type, ui: p.ui, def: isInput ? p.def : nil, display: nil)
        }
        return SZPort(name: name, type: .texture)
    }

    private func derivedInputs(of id: SZNodeID) -> [SZPort] {
        var seen = Set<String>(), ports: [SZPort] = []
        for c in connections where c.kind == .data && c.to.node == id {
            if seen.insert(c.to.port).inserted { ports.append(Self.boundaryPort(c.to.port)) }
        }
        return ports
    }

    private func derivedOutputs(of id: SZNodeID) -> [SZPort] {
        var seen = Set<String>(), ports: [SZPort] = []
        for c in connections where c.kind == .data && c.from.node == id {
            if seen.insert(c.from.port).inserted { ports.append(Self.boundaryPort(c.from.port)) }
        }
        if let ep = renderEndpoint, ep.node == id, seen.insert(ep.port).inserted {
            ports.append(Self.boundaryPort(ep.port, display: true))
        }
        return ports
    }

    private static func boundaryPort(_ name: String, display: Bool = false) -> SZPort {
        SZPort(name: name, type: .texture, display: display ? true : nil)
    }

    private static func mergedPermissions(_ members: [SZNode]) -> [SZEntitlement] {
        var seen = Set<SZEntitlement>(), out: [SZEntitlement] = []
        for m in members {
            for p in m.contract?.requiredPermissions ?? [] where seen.insert(p).inserted { out.append(p) }
        }
        return out
    }
}
