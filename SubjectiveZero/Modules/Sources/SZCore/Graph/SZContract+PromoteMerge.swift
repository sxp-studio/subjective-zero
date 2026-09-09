// SPDX-License-Identifier: AGPL-3.0-only
// The promote-time boundary merge — how the contract an agent just authored folds into the one
// already live on the node, instead of replacing it.
//
// A node's contract wears three hats: the typed I/O boundary the graph wires and the runtime enforces,
// the agent surface authored alongside `Node.swift`, and the parameter store holding every unconnected
// input's current value (`SZStore.setInputDefault` writes the user's slider straight into
// `inputs[].def`). Taking the agent's side wholesale drops the user's values and lets a port silently
// change type under live edges; taking the live side deletes the control ports the agent just added
// and wired into its source (a declared-vs-read mismatch — what `SZPortBindingAudit` catches). So
// promote merges per port, by name, under one invariant: **it never retypes a live port and never
// drops one**. Edges, the render endpoint and the runtime's override arity were all validated against
// the live type, so a retype has to go through `SZStore.editPorts`, which prunes what it invalidates
// atomically. Nothing here removes or retypes, so a merge needs no pruning of its own.
import Foundation

/// A merged contract plus the human-readable notes for anything the merge refused to take from the agent.
/// The conflicts ride back to the agent as build warnings, so it learns the boundary held.
public struct SZBoundaryMergeResult: Equatable, Sendable {
    public var contract: SZNodeContract
    /// One line per authored port the boundary overruled, e.g.
    /// `"input 'amount': kept declared type float (you staged texture)"`.
    public var conflicts: [String]

    public init(contract: SZNodeContract, conflicts: [String] = []) {
        self.contract = contract
        self.conflicts = conflicts
    }
}

extension SZNodeContract {
    /// Fold an agent-authored contract into the node's live boundary, keeping every port either side
    /// declares. Per port (matched by `name`, same rules for inputs and outputs):
    /// - **both sides, same type** — the boundary's `type`/`def`/`display` win, and any facet it leaves
    ///   nil (`ui`, `options`, `def`, `display`) is filled from the authored port. `def` is the user's
    ///   current value, so this is what makes a slider survive a rebuild.
    /// - **both sides, different type** — the boundary port stands wholesale, with a `conflicts` line.
    /// - **boundary only** (the agent dropped it) — kept: it may be wired, an unread declared port is a
    ///   warning rather than an error, and removing a port is `ui_edit_ports`' job, not a promote's.
    /// - **authored only** — appended verbatim: the control knobs an agent mints alongside the source
    ///   it just wrote.
    ///
    /// Ordering is boundary-first, authored additions in authored order — stable and idempotent, so
    /// repeated reconcile rounds converge instead of shuffling the card's rows. Outputs come out a
    /// superset of the boundary's, so a render endpoint can never dangle across a promote.
    ///
    /// Permissions are the union (boundary first, new authored appended; empty union → nil), so an
    /// authored entitlement stands when the live boundary declares none (a camera node). Accepted
    /// tradeoff: a union can resurrect a permission the Director removed mid-run — an over-grant prompt
    /// the user answers, not a fault.
    ///
    /// `title`/`sfSymbol` are the boundary's — the card's name and icon belong to whoever named the node
    /// (Director, user), not to the agent that last rebuilt its source; the authored values only fill a
    /// boundary field that is empty or still the drawn-node placeholder (`SZNode.placeholderTitle` /
    /// `placeholderSymbol`). A deliberate rename is an explicit `ui_update_node`, never a promote side
    /// effect. `summary` stays the agent's: it describes the implementation just written.
    public static func mergingAuthored(_ authored: SZNodeContract,
                                       intoBoundary boundary: SZNodeContract) -> SZBoundaryMergeResult {
        var conflicts: [String] = []
        var merged = authored
        let unnamed = boundary.title.isEmpty || boundary.title == SZNode.placeholderTitle
        let uniconed = boundary.sfSymbol.isEmpty || boundary.sfSymbol == SZNode.placeholderSymbol
        merged.title = unnamed ? authored.title : boundary.title
        merged.sfSymbol = uniconed ? authored.sfSymbol : boundary.sfSymbol
        merged.inputs = mergedPorts(authored: authored.inputs, boundary: boundary.inputs,
                                    side: "input", conflicts: &conflicts)
        merged.outputs = mergedPorts(authored: authored.outputs, boundary: boundary.outputs,
                                     side: "output", conflicts: &conflicts)
        let union = boundary.requiredPermissions
            + authored.requiredPermissions.filter { !boundary.requiredPermissions.contains($0) }
        merged.permissions = union.isEmpty ? nil : union
        // Card mount hints: the authored block wins when present; a silent re-stage keeps the live one
        // (an agent editing Node.swift must not strip the card's footprint by omission).
        merged.card = authored.card ?? boundary.card
        return SZBoundaryMergeResult(contract: merged, conflicts: conflicts)
    }

    /// The promote's entry: fold an authored contract into a node — its live contract as the port
    /// boundary (none → an empty one, so the authored ports land verbatim) and the node's displayed
    /// `title`/`sfSymbol` as the identity boundary. The node, not its contract, is the identity truth: a
    /// Director-titled node the run dispatched contract-less keeps its name, and a bundle whose node and
    /// contract identities drifted apart resolves to what the card shows. Placeholders still count as unset.
    /// Host-named pieces ("X (1/2)", "A + B") are real names, so a stage agent keeps them too — intended.
    public static func mergingAuthored(_ authored: SZNodeContract, intoNode node: SZNode) -> SZBoundaryMergeResult {
        var boundary = node.contract
            ?? SZNodeContract(title: node.title, sfSymbol: node.sfSymbol, summary: authored.summary)
        boundary.title = node.title
        boundary.sfSymbol = node.sfSymbol
        return mergingAuthored(authored, intoBoundary: boundary)
    }

    /// One side's ports merged by name — see `mergingAuthored` for the rules. `side` only names the port
    /// direction in the conflict lines.
    private static func mergedPorts(authored: [SZPort], boundary: [SZPort],
                                    side: String, conflicts: inout [String]) -> [SZPort] {
        var merged: [SZPort] = []
        merged.reserveCapacity(boundary.count + authored.count)
        for live in boundary {
            guard let staged = authored.first(where: { $0.name == live.name }) else {
                merged.append(live)          // the agent dropped it — a live port is never dropped here
                continue
            }
            guard staged.type == live.type else {
                conflicts.append("\(side) '\(live.name)': kept declared type \(live.type.rawValue)"
                    + " (you staged \(staged.type.rawValue))")
                merged.append(live)
                continue
            }
            var port = live
            port.ui = live.ui ?? staged.ui
            port.options = live.options ?? staged.options
            port.def = live.def ?? staged.def
            port.display = live.display ?? staged.display
            merged.append(port)
        }
        let declared = Set(boundary.map(\.name))
        merged.append(contentsOf: authored.filter { !declared.contains($0.name) })
        return merged
    }
}
