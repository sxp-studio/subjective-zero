// SPDX-License-Identifier: AGPL-3.0-only
// One graph edit, with WHO made it — the reconcile brief's delta. The host appends an entry at
// each origin-carrying mutation funnel; the Director's brief lists the entries since its last
// turn so it never has to guess whether the user, itself, or a Coding Agent changed the graph.
// In-memory only, bounded, cleared with the project.
import Foundation

public struct SZGraphMutation: Sendable, Equatable {
    /// Who made the edit. `.agent` names the Coding Agent's node (its turn's scope); `.external` is
    /// a tool call that carried no turn identity (a standing bus / an outside driver) — never
    /// claimed as the Director's own work.
    public enum Actor: Sendable, Equatable {
        case user, director, agent(SZNodeID), external
    }

    public var at: Date
    public var actor: Actor
    /// Past-tense verb phrase: "connected", "removed node", "set default", …
    public var kind: String
    /// What it touched, as the brief prints it: node titles, "A.out → B.in", "Node.port = 3".
    public var subjects: [String]

    public init(at: Date = Date(), actor: Actor, kind: String, subjects: [String]) {
        self.at = at
        self.actor = actor
        self.kind = kind
        self.subjects = subjects
    }

    /// Identity for collapsing a burst of the same edit (a control nudged five times, a checkbox
    /// clicked twice): actor + kind + what it touched, with a trailing `= value` dropped so
    /// successive writes to one port fold into their latest value.
    public var coalescingKey: String {
        let touched = subjects.map { $0.components(separatedBy: " = ").first ?? $0 }
        return "\(actor)|\(kind)|\(touched.joined(separator: ","))"
    }
}

/// The bounded journal: the newest `capacity` entries, plus a running count so a reader can keep
/// an absolute cursor ("everything since my last turn") that survives the oldest entries aging out.
public struct SZMutationJournal: Sendable {
    public let capacity: Int
    public private(set) var entries: [SZGraphMutation] = []
    /// Entries ever appended (including the ones aged out) — the cursor space.
    public private(set) var count = 0

    public init(capacity: Int = 200) { self.capacity = max(1, capacity) }

    public mutating func append(_ mutation: SZGraphMutation) {
        entries.append(mutation)
        count += 1
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// The entries appended after `count` stood at `cursor` (oldest first); a cursor older than the
    /// window returns the whole window.
    public func entries(since cursor: Int) -> [SZGraphMutation] {
        let fresh = min(max(0, count - cursor), entries.count)
        return Array(entries.suffix(fresh))
    }

    public mutating func removeAll() {
        entries.removeAll()
        count = 0
    }
}
