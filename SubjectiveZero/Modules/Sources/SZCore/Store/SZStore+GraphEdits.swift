// SPDX-License-Identifier: AGPL-3.0-only
// Named graph-edit operations on SZStore — the single shared mutation path for BOTH the SwiftUI node
// editor (SZUI) and the host's `ui_*` MCP handlers (SZApp). They live here in SZCore because SZUI
// cannot import SZApp, so SZCore is the only home both reach (ARCHITECTURE.md "try SZStore first" —
// no seam protocol is earned for pure state edits). These mutate the loaded project directly;
// TODO: route through the Command/undo engine (STATE.md) once undo/checkpoints ship.
import Foundation

extension SZStore {
    /// A single typed port to pre-declare on a spawned prompt node — how a data wire dropped on
    /// empty canvas gets a legal endpoint (`canConnect` requires exact type equality).
    public enum SZPromptSeed: Equatable, Sendable {
        case input(SZPortType)
        case output(SZPortType)

        /// The minted port's name (`SZDraftPortName`) — the spawner wires its follow-up edge to
        /// this, so seed and edge can never disagree.
        public var portName: String {
            switch self {
            case .input: return SZDraftPortName.input()
            case .output: return SZDraftPortName.output
            }
        }
    }

    /// Append a prompt (pre-gen) node at `position`. Returns its id, or nil if no project is loaded.
    /// A `seed` additionally mints a one-port contract — node + contract in ONE mutation, never a
    /// contract-less intermediate state. The seeded contract is the declaration the coding agent
    /// later implements against; `draftContractsFromFlow` never rewrites it (though it still
    /// realizes flow arrows into the node's unwired texture inputs).
    @discardableResult
    public func addPromptNode(prompt: String?, position: SZPoint,
                              seed: SZPromptSeed? = nil) -> SZNodeID? {
        var node = SZNode(kind: .prompt, title: SZNode.placeholderTitle, prompt: prompt, position: position)
        if let seed {
            let ports: (inputs: [SZPort], outputs: [SZPort])
            switch seed {
            case .input(let type):  ports = ([SZPort(name: seed.portName, type: type)], [])
            case .output(let type): ports = ([], [SZPort(name: seed.portName, type: type)])
            }
            node.contract = SZNodeContract(title: node.title, sfSymbol: node.sfSymbol,
                                           summary: prompt ?? node.title,
                                           inputs: ports.inputs, outputs: ports.outputs)
        }
        return mutate { $0.graph.nodes.append(node) } ? node.id : nil
    }

    /// The outcome of `tryConnect` — `connect`'s result-carrying form, so a refusal is legible
    /// instead of folding into nil.
    public enum SZConnectResult: Equatable, Sendable {
        case connected(SZConnectionID)
        /// The data edge would close a cycle; `path` is the offending walk (from → … → from).
        case cycleRefused(path: [SZNodeID])
        case noProject
    }

    /// Connect an output port to an input port. Type-compatibility is the caller's call (the editor
    /// checks before connecting), but cardinality is enforced here: a data input holds at most ONE
    /// incoming connection, so wiring an occupied input swaps the old edge out. Repeating an existing
    /// connection — same data from→to, or a flow edge between the same node pair with the same pins
    /// (`SZConnection.pinnedPort`) — is idempotent and returns the existing id. And the graph must stay a DAG: a DATA edge that would close a cycle is
    /// refused, judged against the graph as if the occupied input's edge were already swapped out, so
    /// a replace that breaks the old cycle path is never a false positive. Flow is never checked.
    ///
    /// Flow is a transient *drawing-intent* annotation ("A should feed B"), not a persistent
    /// companion layer. So creating a DATA edge RESOLVES (removes) the matching flow intent edge between
    /// the same node pair — the green intent arrow becomes a solid blue wire, exactly like resolving a
    /// comment. (Inverse of the old `ensureFlow`-on-connect.) An intent the caller never wires stays
    /// visible as an unresolved arrow.
    @discardableResult
    public func tryConnect(from: SZPortRef, to: SZPortRef, kind: SZConnectionKind) -> SZConnectResult {
        guard let graph = project?.graph else { return .noProject }
        assertFenceCleared([from.node, to.node])
        // Flow compares node + pin per end (markers "" / "flow" agree); a different pin is a new intent.
        if let existing = graph.connections.first(where: {
            $0.kind == kind && (kind == .flow
                ? (SZConnection.sameFlowEnd($0.from, from) && SZConnection.sameFlowEnd($0.to, to))
                : ($0.from == from && $0.to == to))
        }) {
            // Repeating a data edge still clears the arrow behind it. Returning the id bare left one
            // standing over wiring that already existed, which reads as work still owed.
            if kind == .data { mutate { $0.graph.connections.removeAll { $0.isFlowIntent(realizedBy: from, to) } } }
            return .connected(existing.id)
        }
        if kind == .data {
            var probe = graph
            probe.connections.removeAll { $0.kind == .data && $0.to == to }   // the swap victim goes either way
            if let path = probe.wouldCloseCycle(from: from.node, to: to.node) {
                return .cycleRefused(path: path)
            }
        }
        let connection = SZConnection(from: from, to: to, kind: kind)
        let applied = mutate { project in
            if kind == .data {
                project.graph.connections.removeAll { $0.kind == .data && $0.to == to }
            }
            project.graph.connections.append(connection)
            // Realizing intent: a data edge resolves the matching flow arrows between the same nodes —
            // an arrow pinned to another slot is a different intent and stays.
            if kind == .data {
                project.graph.connections.removeAll { $0.isFlowIntent(realizedBy: from, to) }
            }
        }
        return applied ? .connected(connection.id) : .noProject
    }

    /// `tryConnect` with every non-connection folded to nil — the original signature, kept so the
    /// call sites that only need the id don't churn.
    @discardableResult
    public func connect(from: SZPortRef, to: SZPortRef, kind: SZConnectionKind) -> SZConnectionID? {
        if case .connected(let id) = tryConnect(from: from, to: to, kind: kind) { return id }
        return nil
    }

    /// Remove a connection by id. Returns whether one was removed.
    @discardableResult
    public func disconnect(connection id: SZConnectionID) -> Bool {
        if let c = project?.graph.connections.first(where: { $0.id == id }) {
            assertFenceCleared([c.from.node, c.to.node])
        }
        var removed = false
        mutate { project in
            let before = project.graph.connections.count
            project.graph.connections.removeAll { $0.id == id }
            removed = project.graph.connections.count < before
        }
        return removed
    }

    public struct SZNodeUpdateResult: Equatable, Sendable {
        /// The node existed and the edit applied.
        public var found: Bool
        /// This edit turned a clean built node dirty (its intent moved off the build stamp).
        public var raisedRebuild: Bool

        /// Public so a caller outside SZCore can report an outcome it settled WITHOUT reaching the store —
        /// the host's `updateNodeContent` funnel answers `found: false` for a missing node and
        /// `found: true, raisedRebuild: false` for a no-op edit it short-circuits (a blur with no
        /// keystrokes), so neither costs a persist. A fence refusal is not this shape: the funnel returns
        /// nil for that, so "refused" can never be misread as "no such node".
        public init(found: Bool, raisedRebuild: Bool) {
            self.found = found
            self.raisedRebuild = raisedRebuild
        }
    }

    /// Update a node's presentation / identity in place (nil = leave that field unchanged).
    ///
    /// Deliberately CANNOT touch the port surface — that goes through `editPorts`, the one editorial path for a
    /// node's typed I/O. A whole-contract `PUT` here is what silently dropped a node's controls: a caller that
    /// re-sent the contract while omitting ports deleted them.
    ///
    /// A `prompt` change DOES invalidate a build, though: the code still renders, but it implements what the
    /// prompt used to say. Nothing is raised here — `SZNode.rebuildReason` derives `.intentChanged` from the
    /// build stamp — but `raisedRebuild` reports whether THIS edit made the node dirty, so a run can pick it up.
    @discardableResult
    public func updateNode(
        id: SZNodeID,
        title: String? = nil,
        sfSymbol: String? = nil,
        prompt: String? = nil,
        summary: String? = nil,
        permissions: [SZEntitlement]? = nil
    ) -> SZNodeUpdateResult {
        assertFenceCleared([id])
        var result = SZNodeUpdateResult(found: false, raisedRebuild: false)
        mutate { project in
            guard let i = project.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
            result.found = true
            if let title { project.graph.nodes[i].title = title }
            if let sfSymbol { project.graph.nodes[i].sfSymbol = sfSymbol }
            if let prompt {
                let wasDirty = project.graph.nodes[i].needsRebuild
                project.graph.nodes[i].prompt = prompt
                result.raisedRebuild = !wasDirty && project.graph.nodes[i].needsRebuild
            }

            // `summary` and `permissions` live inside the contract, so a node that has none yet needs one
            // synthesized — otherwise declaring a node's permissions BEFORE its ports (a natural order: "this
            // needs the microphone", then its I/O) would silently drop them. Same failure this whole change
            // exists to remove, one level down. `editPorts` synthesizes on the same terms.
            let node = project.graph.nodes[i]
            if node.contract == nil, summary != nil || permissions != nil {
                project.graph.nodes[i].contract = SZNodeContract(
                    title: node.title, sfSymbol: node.sfSymbol, summary: node.prompt ?? node.title)
            }
            // None of these touch the port surface or the intent, so none of them invalidate a build.
            if project.graph.nodes[i].contract != nil {
                if let summary { project.graph.nodes[i].contract?.summary = summary }
                if let permissions { project.graph.nodes[i].contract?.permissions = permissions }
                if let title { project.graph.nodes[i].contract?.title = title }
                if let sfSymbol { project.graph.nodes[i].contract?.sfSymbol = sfSymbol }
            }
        }
        return result
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
        /// This edit turned a clean built node dirty (its surface moved off the build stamp).
        public var raisedRebuild: Bool
        /// Data edges dropped because a port they named vanished or no longer type-matches.
        public var droppedConnections: [SZConnectionID]
        /// The render endpoint named a port that no longer exists (or stopped being a texture output).
        public var clearedRenderEndpoint: Bool
        /// Every port whose stored value this edit moved. The host pushes these into the runtime.
        public var changedValues: [SZPortValueChange]

        /// One line per port whose value this edit could not carry: a type it no longer fits, or an `enum`
        /// option withdrawn while it was in use. Every other re-declared port keeps the value it held.
        public var droppedValues: [String] { changedValues.compactMap(\.note) }
    }

    /// One input whose stored value a port edit moved: rebound into a control that changed under it, cleared
    /// where it could no longer stand, or seeded onto a port that held none.
    ///
    /// Reported because the contract is only where a value PERSISTS: the runtime holds the live override the
    /// node actually reads, and a reload deliberately keeps that override (a slider drag must survive a
    /// structural edit). So a value this edit moved reaches the render only if the host pushes it.
    public struct SZPortValueChange: Equatable, Sendable {
        /// The port, on the edited node.
        public var port: String
        /// What it holds now — nil where the edit cleared it.
        public var value: SZPortValue?
        /// The line for the agent, where the value was lost rather than rebound.
        public var note: String?
    }

    /// Apply a port delta to a node's contract and prune whatever the new surface invalidated. On a node that
    /// already has a build, `needsRebuild` follows from the surface moving off the build stamp (derived).
    ///
    /// `upsert` matches by name, rewriting that port's declaration (a retype lands here) but never the value it
    /// holds — see `apply`. `remove` deletes by name.
    /// A node with no contract yet gets one synthesized from its identity — this is how the Director declares a
    /// fresh prompt node's typed I/O.
    ///
    /// Pruning mirrors `removeNode`: an edit that orphans a data edge or the render endpoint cleans up after
    /// itself rather than leaving the graph referencing ports that no longer exist. Flow edges are node-to-node
    /// intent and carry no port identity, so they survive untouched.
    @discardableResult
    public func editPorts(node id: SZNodeID, _ edit: SZPortEdit) -> SZPortEditResult {
        assertFenceCleared([id])
        var result = SZPortEditResult(found: false, raisedRebuild: false, droppedConnections: [],
                                      clearedRenderEndpoint: false, changedValues: [])
        mutate { project in
            guard let i = project.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
            result.found = true
            let node = project.graph.nodes[i]

            var contract = node.contract ?? SZNodeContract(
                title: node.title, sfSymbol: node.sfSymbol, summary: node.prompt ?? node.title)

            Self.apply(edit.removeInputs, edit.upsertInputs, to: &contract.inputs,
                       side: "input", changed: &result.changedValues)
            Self.apply(edit.removeOutputs, edit.upsertOutputs, to: &contract.outputs,
                       side: "output", changed: &result.changedValues)

            project.graph.nodes[i].contract = contract

            // A surface change invalidates a build — derived by `SZNode.rebuildReason` from the surface moving
            // off the build stamp, so undoing the edit heals it. `kind` is NOT touched: the node keeps
            // rendering its existing source until the fleet regenerates it (flipping it to `.prompt` would
            // drop it from `SZGraph.renderable` and black it out). Whether the code is merely *behind* the
            // contract or *contradicts* it (naming ports that no longer exist) takes reading the source,
            // which the store cannot do; the host re-audits after this returns.
            result.raisedRebuild = !node.needsRebuild && project.graph.nodes[i].needsRebuild

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

    /// Commit one entry of a node's derived-binding table, as ONE transaction: update the table input's
    /// default, upsert the output the entry declares, and (optionally) wire that output to a target
    /// input — one revision, one persistable state.
    ///
    /// For nodes whose output set is DERIVED from an input's data (a binding/mapping table): the node's
    /// code reads the table and emits on whatever ports it names, so the surface change carries no new
    /// code obligation and deliberately does NOT raise `needsRebuild`. `editPorts` remains the editorial
    /// path — a human/agent reshaping a node's declared I/O — where a build IS invalidated. Wiring
    /// follows `connect`'s cardinality rule (a data input holds one incoming edge; occupying swaps).
    ///
    /// Returns false (no mutation applied) if the node, its contract, or a string-typed `tableInput`
    /// is missing.
    @discardableResult
    public func commitDerivedBinding(
        node id: SZNodeID, tableInput: String, tableJSON: String,
        output: SZPort, target: SZPortRef?
    ) -> Bool {
        assertFenceCleared([id])
        var applied = false
        mutate { project in
            guard let ni = project.graph.nodes.firstIndex(where: { $0.id == id }),
                  var contract = project.graph.nodes[ni].contract,
                  let ti = contract.inputs.firstIndex(where: { $0.name == tableInput }),
                  contract.inputs[ti].type == .string else { return }
            contract.inputs[ti].def = .string(tableJSON)
            if let existing = contract.outputs.firstIndex(where: { $0.name == output.name }) {
                contract.outputs[existing] = output
            } else {
                contract.outputs.append(output)
            }
            project.graph.nodes[ni].contract = contract
            // The build implements this output by construction (table-generic code), so the stamp's surface
            // follows the contract — otherwise the derived reason would read the new port as unbuilt.
            if let stamped = project.graph.nodes[ni].buildStamp?.portSurface {
                project.graph.nodes[ni].buildStamp?.portSurface = Self.derivedSurface(
                    stamped, removing: output.name,
                    adding: .init(direction: .output, name: output.name, type: output.type))
            }
            if let target {
                project.graph.connections.removeAll { $0.kind == .data && $0.to == target }
                project.graph.connections.append(SZConnection(
                    from: SZPortRef(node: id, port: output.name), to: target, kind: .data))
            }
            applied = true
        }
        return applied
    }

    /// Remove one derived-binding entry — the inverse of `commitDerivedBinding`, same single
    /// transaction: update the table input's default, drop the named output, and prune the data edges
    /// that output fed. Same rebuild exemption, same grounds. Returns false if nothing matched.
    @discardableResult
    public func removeDerivedBinding(
        node id: SZNodeID, tableInput: String, tableJSON: String, output name: String
    ) -> Bool {
        assertFenceCleared([id])
        var applied = false
        mutate { project in
            guard let ni = project.graph.nodes.firstIndex(where: { $0.id == id }),
                  var contract = project.graph.nodes[ni].contract,
                  let ti = contract.inputs.firstIndex(where: { $0.name == tableInput }),
                  contract.inputs[ti].type == .string else { return }
            contract.inputs[ti].def = .string(tableJSON)
            contract.outputs.removeAll { $0.name == name }
            project.graph.nodes[ni].contract = contract
            if let stamped = project.graph.nodes[ni].buildStamp?.portSurface {
                project.graph.nodes[ni].buildStamp?.portSurface = Self.derivedSurface(stamped, removing: name, adding: nil)
            }
            let source = SZPortRef(node: id, port: name)
            project.graph.connections.removeAll { $0.kind == .data && $0.from == source }
            applied = true
        }
        return applied
    }

    /// A stamp surface with the derived output `name` swapped for `adding` (nil = dropped).
    private static func derivedSurface(_ surface: Set<SZNodeContract.PortSignature>, removing name: String,
                                       adding: SZNodeContract.PortSignature?) -> Set<SZNodeContract.PortSignature> {
        var s = surface.filter { !($0.direction == .output && $0.name == name) }
        if let adding { s.insert(adding) }
        return s
    }

    /// Remove by name, then upsert by name (append if new, merge in place if it exists — so a port keeps its
    /// position in the list across a retype).
    ///
    /// The declaration is the caller's, the value is the user's. An upsert's `type` and every facet it states
    /// land; a facet it omits (`ui`, `options`, `display`) is kept, and the `def` the port already holds
    /// outranks the incoming one — that is where `setInputDefault` writes the user's knob, and
    /// `setInputDefault` is the one way to change it. Same polarity as the promote merge's
    /// `live.def ?? staged.def`. A port holding no value still takes the caller's, so a first declaration
    /// lands verbatim. `side` only names the direction in the reported lines.
    private static func apply(_ removals: [String], _ upserts: [SZPort], to ports: inout [SZPort],
                              side: String, changed: inout [SZPortValueChange]) {
        if !removals.isEmpty {
            let drop = Set(removals)
            ports.removeAll { drop.contains($0.name) }
        }
        for port in upserts {
            guard let existing = ports.firstIndex(where: { $0.name == port.name }) else {
                ports.append(port)
                continue
            }
            let live = ports[existing]
            var merged = port
            // Only at the same type: a retype's facets described the old type, so a stale option list or a
            // slider's bounds must not survive onto the new one.
            if port.type == live.type {
                merged.ui = port.ui ?? live.ui
                merged.options = port.options ?? live.options
                merged.display = port.display ?? live.display
            }
            // Last, and against the merged port: a value is judged by the declaration this edit leaves behind.
            let carried = carriedDefault(live.def, into: merged, side: side)
            merged.def = carried.value
            ports[existing] = merged
            // Only a value that actually moved: an edit that leaves one alone must not disturb the live
            // override the node is reading (a card gesture or a controller binding drives that, not `def`).
            if carried.value != live.def {
                changed.append(SZPortValueChange(port: merged.name, value: carried.value, note: carried.note))
            }
        }
    }

    /// The value a re-declared port keeps, re-snapped into its new declaration by `clampedDefault`. Dropped
    /// only where it cannot stand — a type it no longer fits, or an `enum` whose options no longer offer it —
    /// and each drop names the port in `dropped`, so the agent hears which knob it just reset instead of the
    /// user finding it in the render.
    ///
    /// The caller's own `def` then applies, on the same terms: nothing reaches a contract through here that
    /// the port's own control could not produce, which is the invariant `setInputDefault` documents.
    private static func carriedDefault(_ value: SZPortValue?, into port: SZPort,
                                       side: String) -> (value: SZPortValue?, note: String?) {
        var note: String?
        if let value {
            if value.type != port.type {
                note = "\(side) '\(port.name)': dropped its value"
                    + " (\(value.type.rawValue) does not fit the \(port.type.rawValue) you declared)"
            } else if !offers(port, value) {
                note = "\(side) '\(port.name)': dropped its value (not among the options you declared)"
            } else {
                return (port.clampedDefault(value), nil)
            }
        }
        guard let stated = port.def, stated.type == port.type, offers(port, stated) else { return (nil, note) }
        return (port.clampedDefault(stated), note)
    }

    /// Whether `port` declares `value` as one of its choices. An `enum` with no `options` is dynamic (the node
    /// supplies them at runtime, like `camera`), so it vouches for nothing and the value stands. Kept out of
    /// `SZPort.clampedDefault`: that snaps onto a nearest legal value, this rejects with none to land on, and
    /// a live node's option list may exceed the contract's, so `setInputDefault` must not consult it.
    private static func offers(_ port: SZPort, _ value: SZPortValue) -> Bool {
        guard port.type == .enumeration, case .enumeration(let choice) = value,
              let options = port.options, !options.isEmpty else { return true }
        return options.contains { $0.value == choice }
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
        assertFenceCleared([id])
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
        assertFenceCleared([id])
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
        assertFenceCleared([id])
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
