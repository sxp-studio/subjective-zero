// SPDX-License-Identifier: AGPL-3.0-only
// The mutation journal's append side: every origin-carrying host funnel (the connection trio,
// input defaults, content updates, display, delete, node body, bindings, library instantiate,
// split/merge, and the MCP add/edit-ports handlers) notes what it changed and for whom. The actor
// is derived from the fence's origin plus the calling turn's scope (`SZToolCaller.scope`): user
// edits are USER; an agent call from a node-scoped turn is that node's Coding Agent; a
// Director-scoped turn is DIRECTOR; an agent call carrying NO scope (a standing bus, an outside
// driver) is EXTERNAL — never folded into the Director, or the brief would tell it that someone
// else's edits are its own.
//
// Only DECISIONS belong here. Machinery that re-applies graph state on its own — a card's auto-size
// settle, the backdrop aspect follow, a staged op's deferred commit — journals nothing, or the
// delta reads as a user changing their mind dozens of times.
import Foundation
import SZCore

extension SZHost {
    /// Append one journal entry. `subjects` are printed verbatim in the brief — pass titles/ports,
    /// never ids.
    func noteMutation(_ kind: String, _ subjects: [String], origin: SZMutationOrigin) {
        mutationJournal.append(SZGraphMutation(actor: mutationActor(origin), kind: kind, subjects: subjects))
    }

    /// The canvas's node add — the panel writes the store directly (there is no host funnel for it),
    /// so it journals here, at the panel's host callback.
    func noteNodeAdded(_ id: SZNodeID, origin: SZMutationOrigin = .user) {
        noteMutation("added node", [mutationTitle(id)], origin: origin)
    }

    /// The journal actor behind a mutation: see the file header for the rule.
    func mutationActor(_ origin: SZMutationOrigin) -> SZGraphMutation.Actor {
        switch origin {
        case .user: return .user
        case .agent:
            guard let scope = SZToolCaller.scope else { return .external }
            return scope.nodeID.map { .agent($0) } ?? .director
        }
    }

    /// A node's title for the journal (short id when the node is gone/unknown).
    func mutationTitle(_ id: SZNodeID) -> String {
        store.project?.graph.node(id: id)?.title ?? String(id.uuidString.prefix(8))
    }

    /// `Title.port` for the journal.
    func mutationLabel(_ ref: SZPortRef) -> String { "\(mutationTitle(ref.node)).\(ref.port)" }

    /// A port value as the journal prints it: numbers plain, text quoted.
    static func mutationValue(_ value: SZPortValue) -> String {
        if let string = value.string { return "\"\(string)\"" }
        if let floats = value.floats {
            let parts = floats.map(plainDecimal)
            return parts.count == 1 ? parts[0] : "[\(parts.joined(separator: ", "))]"
        }
        return "event"
    }

    /// A float in plain decimal — never `1.23e+03`, which reads as noise in a prompt. Trailing
    /// zeros are trimmed, so a whole number prints as one.
    private static func plainDecimal(_ value: Float) -> String {
        var text = String(format: "%.6f", Double(value))
        guard text.contains(".") else { return text }   // nan / inf
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// `A.out → B.in` for a connection, read BEFORE it is removed.
    func mutationEdge(_ id: SZConnectionID) -> String? {
        guard let c = store.project?.graph.connections.first(where: { $0.id == id }) else { return nil }
        return "\(mutationLabel(c.from)) → \(mutationLabel(c.to))"
    }
}
