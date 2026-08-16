// SPDX-License-Identifier: AGPL-3.0-only
// The single commit path behind controller→parameter bindings: the `binding_*` MCP tools and a
// controller card's `learn_commit` / `remove_binding` verbs both land here, so the rebind rule lives
// in exactly one place. A binding is ordinary graph state — a mappings-table row, a derived output
// on the source's contract, and a data edge to the target — committed as ONE store transaction,
// live-pushed to the running frame, then persisted. Source-agnostic: the row's `key` is whatever
// wire identity the controller node emits on `lastKey` (MIDI, OSC, …).
import Foundation
import SZCore

extension SZHost {
    struct BindingResult {
        let key: String
        let port: String
        let min: Double
        let max: Double
        let target: SZPortRef?
    }

    /// Commit (or re-commit) a controller→parameter binding on a binding-source node. Replace-aware:
    /// when one of `source`'s derived outputs already feeds `target`, its port NAME is reused, so
    /// the table row and contract output update in place — no suffixed duplicate names, no orphaned
    /// rows — and the whole rebind is still one transaction. The same controller may drive several
    /// targets (each keeps its own row/output); range defaults to the target's declared control range.
    ///
    /// `target: nil` MINTS: the binding lands as a table row + a derived output socket and NO edge —
    /// the user wires the new output by an ordinary canvas drag (learning grows the node's IO, wiring
    /// stays a graph gesture). Re-learning the same key replaces its row in place, so moving a control
    /// twice never mints a duplicate. Fenced like every other graph mutation (`origin`).
    func commitBinding(source: SZNodeID, target: SZPortRef?, key: String,
                       min requestedMin: Double? = nil, max requestedMax: Double? = nil,
                       label: String? = nil, origin: SZMutationOrigin = .user) throws -> BindingResult {
        guard let contract = store.project?.graph.node(id: source)?.contract else {
            throw SZMCPError.message("node has no contract")
        }
        guard contract.isBindingSource else {
            throw SZMCPError.message("node \(source) is not a binding source")
        }
        guard !key.isEmpty else { throw SZMCPError.message("binding key must not be empty") }
        if let denial = fenceDenial(nodes: [source] + (target.map { [$0.node] } ?? []), origin: origin) {
            throw SZMCPError.message(denial)
        }

        let min: Double
        let max: Double
        let portName: String
        let action: String
        var resolvedLabel = label
        if let target {
            guard let targetModel = store.project?.graph.node(id: target.node)?.contract?.inputs
                .first(where: { $0.name == target.port }) else {
                throw SZMCPError.message("target: no input port \(target.port) on node \(target.node)")
            }
            guard targetModel.type == .float else {
                throw SZMCPError.message("target \(target.port) is \(targetModel.type.rawValue) — bindings drive `float` inputs")
            }
            min = requestedMin ?? targetModel.ui?.min ?? 0
            max = requestedMax ?? targetModel.ui?.max ?? 1
            let targetTitle = store.project?.graph.node(id: target.node)?.title ?? target.port
            // A target-bound row is labeled for what it drives ("Distortion Amount"), so the strip
            // reads as the parameter, not the wire.
            resolvedLabel = label ?? Self.humanized(target.port)
            portName = store.project?.graph.derivedBindingPort(source: source, target: target)
                ?? Self.uniquePortName(Self.portSlug(label ?? "\(targetTitle) \(target.port)"), in: contract)
            action = "bound \(key) → \(targetTitle).\(target.port)"
        } else {
            min = requestedMin ?? 0
            max = requestedMax ?? 1
            // Mint: re-learning the same controller reuses its row's output name (idempotent learn);
            // a fresh controller mints a new port named for the label or the key itself.
            portName = Self.existingPort(for: key, in: contract)
                ?? Self.uniquePortName(Self.portSlug(label ?? key), in: contract)
            action = "learned \(key) → output \(portName)"
        }

        // Merge the mappings table (replace the entry already claiming this output name, if any).
        var entry: [String: Any] = ["key": key, "port": portName, "min": min, "max": max]
        if let resolvedLabel { entry["label"] = resolvedLabel }
        let table = try Self.mergedTable(contract, upsert: entry, removePort: portName)

        guard store.commitDerivedBinding(
            node: source, tableInput: SZBindingSource.tableInput, tableJSON: table,
            output: SZPort(name: portName, type: .float), target: target) else {
            throw SZMCPError.message("binding commit failed — node/table missing")
        }
        // Live-push the new table (the store write alone doesn't reach the running frame — same
        // discipline as setInputDefault), then persist + incremental reload so the new edge schedules.
        runtime?.setInputString(node: source, port: SZBindingSource.tableInput, string: table)
        persistGraphEditAndReload(action: action)
        // The gesture is answered — a lingering arm would immediately re-catch the just-bound control.
        if bindingLearn?.node == source {
            bindingLearn?.cancel()
            bindingLearn = nil
        }
        return BindingResult(key: key, port: portName, min: min, max: max, target: target)
    }

    /// Remove a binding by its output port name: drops the table row, the derived output, and the
    /// edges it fed — one transaction, the inverse of `commitBinding`.
    func removeBinding(source: SZNodeID, port portName: String, origin: SZMutationOrigin = .user) throws {
        guard let contract = store.project?.graph.node(id: source)?.contract else {
            throw SZMCPError.message("node has no contract")
        }
        guard contract.outputs.contains(where: { $0.name == portName }),
              store.project?.graph.mappingsTable(node: source)[portName] != nil else {
            throw SZMCPError.message("no binding output named \(portName)")
        }
        if let denial = fenceDenial(nodes: [source], origin: origin) { throw SZMCPError.message(denial) }
        let table = try Self.mergedTable(contract, upsert: nil, removePort: portName)
        guard store.removeDerivedBinding(
            node: source, tableInput: SZBindingSource.tableInput, tableJSON: table, output: portName) else {
            throw SZMCPError.message("binding removal failed — node/table missing")
        }
        runtime?.setInputString(node: source, port: SZBindingSource.tableInput, string: table)
        persistGraphEditAndReload(action: "removed binding \(portName)")
    }

    /// Arm learn on a binding-source node (a fresh arm replaces any prior session — the controller
    /// snapshots the arm-time event so the control already mid-move is excluded until it settles).
    func armBindingLearn(source: SZNodeID) throws {
        guard store.project?.graph.node(id: source)?.contract?.isBindingSource == true else {
            throw SZMCPError.message("node \(source) is not a binding source")
        }
        bindingLearn?.cancel()
        bindingLearn = SZBindingLearnController(host: self, node: source)
    }

    /// Disarm learn if it is armed on `source` (no commit).
    func cancelBindingLearn(source: SZNodeID) {
        guard bindingLearn?.node == source else { return }
        bindingLearn?.cancel()
        bindingLearn = nil
    }

    // MARK: - Table + name helpers

    /// The node's current mappings table with `removePort`'s entry dropped and `upsert` (if any)
    /// appended, re-serialized deterministically.
    private static func mergedTable(
        _ contract: SZNodeContract, upsert: [String: Any]?, removePort: String
    ) throws -> String {
        var entries = tableRows(contract)
        entries.removeAll { ($0["port"] as? String) == removePort }
        if let upsert { entries.append(upsert) }
        let data = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func tableRows(_ contract: SZNodeContract) -> [[String: Any]] {
        let raw = contract.inputs.first { $0.name == SZBindingSource.tableInput }?.def?.string ?? "[]"
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]] ?? []
    }

    /// The output name an existing mappings row already gives this key, if any — the mint path's
    /// idempotence: learn the same control twice, keep one output.
    private static func existingPort(for key: String, in contract: SZNodeContract) -> String? {
        tableRows(contract).first { ($0["key"] as? String) == key }?["port"] as? String
    }

    /// A port name as words: `distortionAmount` / `pixel_size` / `blur-radius` → "Distortion Amount".
    static func humanized(_ port: String) -> String {
        var words: [String] = []
        var current = ""
        for character in port {
            if character == "_" || character == "-" || character == " " {
                if !current.isEmpty { words.append(current); current = "" }
            } else if character.isUppercase, let lastChar = current.last, lastChar.isLowercase || lastChar.isNumber {
                words.append(current); current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// A port-safe slug: lowercased, alphanumerics kept, runs of anything else collapsed to "-".
    static func portSlug(_ text: String) -> String {
        var out = ""
        var pendingDash = false
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(character)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "control" : out
    }

    /// `base`, or `base-2`, `base-3`, … — the first name no port on the contract already claims.
    /// Reached only for NEW bindings; a rebind reuses the existing name (`derivedBindingPort`).
    private static func uniquePortName(_ base: String, in contract: SZNodeContract) -> String {
        let taken = Set((contract.outputs + contract.inputs).map(\.name))
        if !taken.contains(base) { return base }
        var i = 2
        while taken.contains("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }
}
