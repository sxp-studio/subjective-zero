// SPDX-License-Identifier: AGPL-3.0-only
// Read-side queries over a controller node's derived bindings: the mappings table a node carries as
// port data, and the edge↔table join that says which derived output feeds a given target. Pure graph
// logic so the rebind rule (a target's existing binding is REPLACED in place, never duplicated) and
// the surfaces that show bindings share one testable answer. Source-agnostic: a row's `key` is the
// controller's own wire identity (MIDI `"ch1/cc7"`, OSC `"/1/fader1"`) — opaque to the graph.
import Foundation

/// One decoded row of a controller node's `mappings` table: the wire `key`, the output range the
/// node scales into, and the optional human label.
public struct SZBindingEntry: Equatable, Sendable {
    public var key: String
    public var min: Double
    public var max: Double
    public var label: String?

    public init(key: String, min: Double = 0, max: Double = 1, label: String? = nil) {
        self.key = key
        self.min = min
        self.max = max
        self.label = label
    }
}

extension SZNodeContract {
    /// The one capability check for "this node is a binding source": it carries a string `mappings`
    /// table input and emits the learn key on a string `lastKey` output. Used by the learn layer, the
    /// MCP tools, and the card verb allowlist — never re-derived elsewhere.
    public var isBindingSource: Bool {
        inputs.contains { $0.name == SZBindingSource.tableInput && $0.type == .string }
            && outputs.contains { $0.name == SZBindingSource.lastKeyOutput && $0.type == .string }
    }
}

/// The port names a binding source declares (the seed contract of `midi.macos`, `osc-input`, …).
public enum SZBindingSource {
    /// String input holding the JSON `[{"key","port","min","max","label"}]` binding table.
    public static let tableInput = "mappings"
    /// String output: the wire key of the most recent event (the learn signal's identity half).
    public static let lastKeyOutput = "lastKey"
    /// float2 output `[seq, value01]`: seq increments per event received (the learn signal's clock half).
    public static let lastEventOutput = "lastEvent"
}

extension SZGraph {
    /// A node's mappings table decoded by output port name. Degrades to empty on a missing
    /// node/input or malformed JSON — readers render "unbound", they don't throw. Rows without a
    /// `port` and `key` are skipped (same tolerance as the source node's own parser).
    public func mappingsTable(node id: SZNodeID, tableInput: String = SZBindingSource.tableInput)
        -> [String: SZBindingEntry] {
        guard let raw = node(id: id)?.contract?.inputs
            .first(where: { $0.name == tableInput && $0.type == .string })?.def?.string,
            let rows = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]]
        else { return [:] }
        var table: [String: SZBindingEntry] = [:]
        for row in rows {
            guard let port = row["port"] as? String, let key = row["key"] as? String, !key.isEmpty
            else { continue }
            table[port] = SZBindingEntry(
                key: key,
                min: (row["min"] as? NSNumber)?.doubleValue ?? 0,
                max: (row["max"] as? NSNumber)?.doubleValue ?? 1,
                label: row["label"] as? String)
        }
        return table
    }

    /// The derived-binding output on `source` that currently feeds `target`, or nil when the
    /// target is unbound. The edge alone is not enough: only a from-port named by a mappings-table
    /// row is a binding — a hand-wired `lastEvent` (or any other output) never masquerades as one.
    public func derivedBindingPort(source: SZNodeID, target: SZPortRef,
                                   tableInput: String = SZBindingSource.tableInput) -> String? {
        guard let port = connections.first(where: {
            $0.kind == .data && $0.to == target && $0.from.node == source
        })?.from.port else { return nil }
        return mappingsTable(node: source, tableInput: tableInput)[port] != nil ? port : nil
    }
}
