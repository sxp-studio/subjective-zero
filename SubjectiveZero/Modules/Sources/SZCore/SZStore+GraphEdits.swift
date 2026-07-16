// SPDX-License-Identifier: AGPL-3.0-only
// Named graph-edit operations on SZStore — the single shared mutation path for BOTH the SwiftUI node
// editor (SZUI) and the host's `ui_*` MCP handlers (SZApp). They live here in SZCore because SZUI
// cannot import SZApp, so SZCore is the only home both reach (ARCHITECTURE.md "try SZStore first" —
// no seam protocol is earned for pure state edits). These mutate the loaded project directly;
// TODO: route through the Command/undo engine (STATE.md) once undo/checkpoints ship.
import Foundation

extension SZStore {
    /// Append a prompt (pre-gen) node at `position`. Returns its id, or nil if no project is loaded.
    @discardableResult
    public func addPromptNode(prompt: String?, position: SZPoint) -> SZNodeID? {
        let node = SZNode(kind: .prompt, title: "New Node", prompt: prompt, position: position)
        return mutate { $0.graph.nodes.append(node) } ? node.id : nil
    }

    /// Connect an output port to an input port. Returns the connection id, or nil if no project is
    /// loaded. Type-compatibility is the caller's call (the editor checks before connecting), but
    /// cardinality is enforced here: a data input holds at most ONE incoming connection, so wiring an
    /// occupied input swaps the old edge out. Repeating an existing connection — same data from→to, or
    /// any flow edge between the same node pair — is idempotent and returns the existing id.
    ///
    /// Flow is now a transient *drawing-intent* annotation ("A should feed B"), not a persistent
    /// companion layer. So creating a DATA edge RESOLVES (removes) the matching flow intent edge between
    /// the same node pair — the green intent arrow becomes a solid blue wire, exactly like resolving a
    /// comment. (Inverse of the old `ensureFlow`-on-connect.) An intent the caller never wires stays
    /// visible as an unresolved arrow.
    @discardableResult
    public func connect(from: SZPortRef, to: SZPortRef, kind: SZConnectionKind) -> SZConnectionID? {
        guard let graph = project?.graph else { return nil }
        // Flow compares node pairs (port names vary: "" / "flow") because flow is node-to-node intent.
        if let existing = graph.connections.first(where: {
            $0.kind == kind && (kind == .flow
                ? ($0.from.node == from.node && $0.to.node == to.node)
                : ($0.from == from && $0.to == to))
        }) { return existing.id }
        let connection = SZConnection(from: from, to: to, kind: kind)
        let applied = mutate { project in
            if kind == .data {
                project.graph.connections.removeAll { $0.kind == .data && $0.to == to }
            }
            project.graph.connections.append(connection)
            // Realizing intent: a data edge resolves the matching flow arrow between the same nodes.
            if kind == .data {
                project.graph.connections.removeAll {
                    $0.kind == .flow && $0.from.node == from.node && $0.to.node == to.node
                }
            }
        }
        return applied ? connection.id : nil
    }

    /// Remove a connection by id. Returns whether one was removed.
    @discardableResult
    public func disconnect(connection id: SZConnectionID) -> Bool {
        var removed = false
        mutate { project in
            let before = project.graph.connections.count
            project.graph.connections.removeAll { $0.id == id }
            removed = project.graph.connections.count < before
        }
        return removed
    }

    /// Update a node's presentation / identity in place (nil = leave that field unchanged). Returns whether the
    /// node was found.
    ///
    /// Deliberately CANNOT touch the port surface — that goes through `editPorts`, which is the only path that
    /// diffs the surface and can therefore raise `needsRebuild`. A whole-contract `PUT` here is what silently
    /// dropped a node's controls: a caller that re-sent the contract while omitting ports deleted them.
    @discardableResult
    public func updateNode(
        id: SZNodeID,
        title: String? = nil,
        sfSymbol: String? = nil,
        prompt: String? = nil,
        summary: String? = nil,
        permissions: [SZEntitlement]? = nil
    ) -> Bool {
        var found = false
        mutate { project in
            guard let i = project.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
            found = true
            if let title { project.graph.nodes[i].title = title }
            if let sfSymbol { project.graph.nodes[i].sfSymbol = sfSymbol }
            if let prompt { project.graph.nodes[i].prompt = prompt }

            // `summary` and `permissions` live inside the contract, so a node that has none yet needs one
            // synthesized — otherwise declaring a node's permissions BEFORE its ports (a natural order: "this
            // needs the microphone", then its I/O) would silently drop them. Same failure this whole change
            // exists to remove, one level down. `editPorts` synthesizes on the same terms.
            let node = project.graph.nodes[i]
            if node.contract == nil, summary != nil || permissions != nil {
                project.graph.nodes[i].contract = SZNodeContract(
                    title: node.title, sfSymbol: node.sfSymbol, summary: node.prompt ?? node.title)
            }
            // None of these are in the port surface, so none of them invalidate a build.
            if project.graph.nodes[i].contract != nil {
                if let summary { project.graph.nodes[i].contract?.summary = summary }
                if let permissions { project.graph.nodes[i].contract?.permissions = permissions }
                if let title { project.graph.nodes[i].contract?.title = title }
                if let sfSymbol { project.graph.nodes[i].contract?.sfSymbol = sfSymbol }
            }
        }
        return found
    }

    /// A typed port delta. Omission means "leave alone" and removal is explicit — so a caller that forgets a
    /// field can never silently delete a port, which a whole-contract resend does by construction.
    public struct SZPortEdit: Equatable, Sendable {
        public var upsertInputs: [SZPort]
        public var removeInputs: [String]
        public var upsertOutputs: [SZPort]
        public var removeOutputs: [String]

        public init(upsertInputs: [SZPort] = [], removeInputs: [String] = [],
                    upsertOutputs: [SZPort] = [], removeOutputs: [String] = []) {
            self.upsertInputs = upsertInputs
            self.removeInputs = removeInputs
            self.upsertOutputs = upsertOutputs
            self.removeOutputs = removeOutputs
        }

        public var isEmpty: Bool {
            upsertInputs.isEmpty && removeInputs.isEmpty && upsertOutputs.isEmpty && removeOutputs.isEmpty
        }
    }

    public struct SZPortEditResult: Equatable, Sendable {
        /// The node existed and the edit applied.
        public var found: Bool
        /// The port surface moved on a node that already had a build, so it must be regenerated.
        public var raisedRebuild: Bool
        /// Data edges dropped because a port they named vanished or no longer type-matches.
        public var droppedConnections: [SZConnectionID]
        /// The render endpoint named a port that no longer exists (or stopped being a texture output).
        public var clearedRenderEndpoint: Bool
    }

    /// Apply a port delta to a node's contract, prune whatever the new surface invalidated, and raise
    /// `needsRebuild` if the surface actually moved on a node that already has a build.
    ///
    /// `upsert` matches by name (replacing that port wholesale, so a retype lands here); `remove` deletes by name.
    /// A node with no contract yet gets one synthesized from its identity — this is how the Director declares a
    /// fresh prompt node's typed I/O.
    ///
    /// Pruning mirrors `removeNode`: an edit that orphans a data edge or the render endpoint cleans up after
    /// itself rather than leaving the graph referencing ports that no longer exist. Flow edges are node-to-node
    /// intent and carry no port identity, so they survive untouched.
    @discardableResult
    public func editPorts(node id: SZNodeID, _ edit: SZPortEdit) -> SZPortEditResult {
        var result = SZPortEditResult(found: false, raisedRebuild: false,
                                      droppedConnections: [], clearedRenderEndpoint: false)
        mutate { project in
            guard let i = project.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
            result.found = true
            let node = project.graph.nodes[i]

            var contract = node.contract ?? SZNodeContract(
                title: node.title, sfSymbol: node.sfSymbol, summary: node.prompt ?? node.title)
            let before = node.contract?.portSurface ?? []

            Self.apply(edit.removeInputs, edit.upsertInputs, to: &contract.inputs)
            Self.apply(edit.removeOutputs, edit.upsertOutputs, to: &contract.outputs)

            project.graph.nodes[i].contract = contract

            // A surface change invalidates a build. `kind` is NOT touched: the node keeps rendering its existing
            // source until the fleet regenerates it. Flipping it to `.prompt` would drop it from
            // `renderableSubgraph` and black it out.
            //
            // `.contractChanged` is the optimistic classification — the contract moved, the code hasn't caught
            // up. Whether the code is merely *behind* the contract or actually *contradicts* it (naming ports
            // that no longer exist) takes reading the source, which the store cannot do. The host re-audits
            // after this returns and upgrades to `.sourceMismatch` when warranted.
            if contract.portSurface != before, node.kind == .generated, node.rebuildReason == nil {
                project.graph.nodes[i].rebuildReason = .contractChanged
                result.raisedRebuild = true
            }

            // Prune every data edge on this node that the new surface no longer supports — a vanished port on
            // this end, or a type that stopped matching the far end after a retype.
            let orphaned = project.graph.connections.filter { c in
                guard c.kind == .data, c.from.node == id || c.to.node == id else { return false }
                return !Self.dataEdgeSurvives(c, editedNode: id, in: project.graph)
            }
            result.droppedConnections = orphaned.map(\.id)
            let doomed = Set(result.droppedConnections)
            project.graph.connections.removeAll { doomed.contains($0.id) }

            // The render endpoint must still name a texture output that exists.
            if let ep = project.graph.renderEndpoint, ep.node == id,
               contract.outputs.first(where: { $0.name == ep.port && $0.type == .texture }) == nil {
                project.graph.renderEndpoint = nil
                result.clearedRenderEndpoint = true
            }
        }
        return result
    }

    /// Set (or clear) why a node must be rebuilt. The host owns this classification because deciding between
    /// `.contractChanged` and `.sourceMismatch` means reading the node's `Node.swift` off disk.
    /// `promoteStagedNode` clears it — the one place a rebuild is discharged.
    @discardableResult
    public func setRebuildReason(node id: SZNodeID, _ reason: SZRebuildReason?) -> Bool {
        var found = false
        mutate { project in
            guard let i = project.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
            found = true
            project.graph.nodes[i].rebuildReason = reason
        }
        return found
    }

    /// Remove by name, then upsert by name (append if new, replace in place if it exists — so a port keeps its
    /// position in the list across a retype).
    private static func apply(_ removals: [String], _ upserts: [SZPort], to ports: inout [SZPort]) {
        if !removals.isEmpty {
            let drop = Set(removals)
            ports.removeAll { drop.contains($0.name) }
        }
        for port in upserts {
            if let existing = ports.firstIndex(where: { $0.name == port.name }) {
                ports[existing] = port
            } else {
                ports.append(port)
            }
        }
    }

    /// Whether a data edge touching `editedNode` survives that node's new port surface.
    ///
    /// Judged from the EDITED end only. The far end may legitimately have no contract yet — a prompt node the
    /// user wired ahead of its declaration — and this edit says nothing about it, so an unresolvable far type
    /// is not grounds to drop wiring the user drew. Mirrors the editor's `canConnect` type rule, which lives in
    /// SZUI and so cannot be called from here.
    private static func dataEdgeSurvives(_ c: SZConnection, editedNode id: SZNodeID, in graph: SZGraph) -> Bool {
        func type(_ ref: SZPortRef, isOutput: Bool) -> SZPortType? {
            let contract = graph.node(id: ref.node)?.contract
            let ports = isOutput ? contract?.outputs : contract?.inputs
            return ports?.first(where: { $0.name == ref.port })?.type
        }
        let outType = type(c.from, isOutput: true)
        let inType = type(c.to, isOutput: false)

        // The edited end must still declare the port this edge names.
        if c.from.node == id, outType == nil { return false }
        if c.to.node == id, inType == nil { return false }
        // Types must agree — but only once both ends can actually name a type.
        guard let outType, let inType else { return true }
        return outType == inType
    }

    /// Remove a node and any connections referencing it; clears the render endpoint if it pointed at
    /// the node. Returns whether a node was removed.
    @discardableResult
    public func removeNode(id: SZNodeID) -> Bool {
        var removed = false
        mutate { project in
            let before = project.graph.nodes.count
            project.graph.nodes.removeAll { $0.id == id }
            removed = project.graph.nodes.count < before
            guard removed else { return }
            project.graph.connections.removeAll { $0.from.node == id || $0.to.node == id }
            if project.graph.renderEndpoint?.node == id { project.graph.renderEndpoint = nil }
        }
        return removed
    }

    /// Set a node input port's default value (the unconnected-input control edit, behind
    /// `ui_set_input_default`). Updates the contract in place; returns whether the port was found. The
    /// host also pushes the value into the runtime live + persists to disk.
    ///
    /// The value is bound to what the port's control can produce (`SZPort.clampedDefault`), so the model
    /// can never hold a slider default outside its declared range no matter who writes it. Idempotent, so
    /// a caller that already clamped (the host, to keep its live runtime push in step) is unaffected.
    @discardableResult
    public func setInputDefault(node id: SZNodeID, port: String, value: SZPortValue) -> Bool {
        var found = false
        mutate { project in
            guard let ni = project.graph.nodes.firstIndex(where: { $0.id == id }),
                  var contract = project.graph.nodes[ni].contract,
                  let pi = contract.inputs.firstIndex(where: { $0.name == port }) else { return }
            contract.inputs[pi].def = contract.inputs[pi].clampedDefault(value)
            project.graph.nodes[ni].contract = contract
            found = true
        }
        return found
    }

    /// Re-designate (or clear) the viewport render endpoint — the texture output blitted to the viewport.
    /// `ref == nil` clears it. A non-nil ref must name an existing node's `texture` output; otherwise this
    /// is a no-op returning false. The single shared path for the editor's monitor-icon toggle and the
    /// `ui_toggle_display` MCP tool. The host pushes the change into the runtime live (no reload).
    @discardableResult
    public func setRenderEndpoint(_ ref: SZPortRef?) -> Bool {
        if let ref {
            guard let port = project?.graph.node(id: ref.node)?.contract?.outputs.first(where: { $0.name == ref.port }),
                  port.type == .texture else { return false }
        }
        mutate { $0.graph.renderEndpoint = ref }
        return true
    }

    /// Set a node's card body (preview / custom / none), or nil to clear it back to the editor's legacy
    /// default. Presentation-only — never the port surface, so it can't raise `needsRebuild`. Callers pass a
    /// fully-resolved `SZNodeBody` (the `ui_set_node_body` handler fills in the default preview port). Returns
    /// whether the node was found.
    @discardableResult
    public func setNodeBody(id: SZNodeID, body: SZNodeBody?) -> Bool {
        var found = false
        mutate { project in
            guard let i = project.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
            found = true
            project.graph.nodes[i].body = body
        }
        return found
    }

    /// Move a node to a new canvas position. Returns whether the node was found.
    @discardableResult
    public func moveNode(id: SZNodeID, to position: SZPoint) -> Bool {
        var found = false
        mutate { project in
            guard let i = project.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
            found = true
            project.graph.nodes[i].position = position
        }
        return found
    }

    /// Move several nodes at once (group drag) in a single transaction — one re-render / one persist.
    /// Missing ids are skipped.
    @discardableResult
    public func moveNodes(_ moves: [(id: SZNodeID, to: SZPoint)]) -> Bool {
        mutate { project in
            for move in moves {
                if let i = project.graph.nodes.firstIndex(where: { $0.id == move.id }) {
                    project.graph.nodes[i].position = move.to
                }
            }
        }
    }

    // MARK: - Split / merge

    /// Split node `id` into `pieces` (≥2) data-connected prompt stages, as one atomic transaction
    /// (`SZGraph.split` computes the reconciled graph; this commits it in a single `mutate`). External
    /// inputs feed the first stage, the last stage feeds external outputs (+ the render endpoint moves to
    /// it), and the stages are texture-connected in between. Returns the new piece ids (first→last), or
    /// nil if no project is loaded / the node is missing / `pieces < 2`. The host wrapper authors each
    /// piece's seed prompt, persists the new folders + reloads the runtime (the coding agents fill them).
    @discardableResult
    public func splitNode(id: SZNodeID, pieces: Int = 2) -> [SZNodeID]? {
        guard let result = project?.graph.split(node: id, into: pieces) else { return nil }
        mutate { $0.graph = result.graph }
        return result.pieceIDs
    }

    /// Merge an adjacent, data-connected linear chain of nodes into one prompt node, as one atomic
    /// transaction (`SZGraph.merge`). External connections rewire to the merged node and the internal
    /// edges are dropped; the render endpoint moves to the merged node if it was on the chain. Returns
    /// the merged node's id, or nil if no project is loaded / fewer than 2 ids / the ids don't form a
    /// connected linear data chain.
    @discardableResult
    public func mergeNodes(ids: [SZNodeID]) -> SZNodeID? {
        guard let result = project?.graph.merge(nodes: ids) else { return nil }
        mutate { $0.graph = result.graph }
        return result.mergedID
    }
}
