// A TASK is the scheduled unit of intent: what was asked, over which nodes, and where it got to.
//
// - The user's words schedule a task; the host admits it when the ledger can claim its work set;
//   an admitted task runs as ONE agent-graph traversal and records one thread-leading run.
// - Tasks with disjoint work sets run at the same time. Overlapping ones queue behind the holder,
//   FIFO — the ledger's reservation fairness is what orders them, not a scheduler here.
// - `workSet` may be empty at schedule time ("make me a bloom") and grows as the task's own tooling
//   creates nodes, through `noteRunCreatedWork`.
// - The vocabulary, deliberately: a task is SCHEDULED, a run is EXECUTED and RECORDED. One admitted
//   task ↔ one `SZAgentGraphRun` thread, linked by `thread` — that is the strip's deep link.
import Foundation

public struct SZTask: Identifiable, Sendable, Equatable, Codable {
    /// Scheduled but unclaimed → live → over. A task leaves the list once `done` has been shown.
    public enum State: String, Sendable, Codable { case pending, running, done }

    public let id: UUID
    /// What the strip calls it — one short phrase, from the ruling that scheduled it.
    public var title: String
    /// The standing instruction the run carries into every brief ("" = none given).
    public var instruction: String
    public var state: State
    /// The nodes this task implements. Empty at schedule time is legal; it grows as work is created.
    public var workSet: Set<SZNodeID>
    /// The agent-graph thread this task became, once admitted — what a strip row links to.
    public var thread: UUID?
    public var createdAt: Date
    /// The transcript bubbles that scheduled it (the words and their ack). They are not prior
    /// conversation to the run they became: `instruction` already carries the words.
    public var origin: Set<UUID>

    public init(id: UUID = UUID(), title: String, instruction: String,
                state: State = .pending, workSet: Set<SZNodeID> = [],
                thread: UUID? = nil, createdAt: Date = Date(), origin: Set<UUID> = []) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.state = state
        self.workSet = workSet
        self.thread = thread
        self.createdAt = createdAt
        self.origin = origin
    }

    /// Tolerant of task files written before `origin` existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        instruction = try c.decode(String.self, forKey: .instruction)
        state = try c.decode(State.self, forKey: .state)
        workSet = try c.decode(Set<SZNodeID>.self, forKey: .workSet)
        thread = try c.decodeIfPresent(UUID.self, forKey: .thread)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        origin = try c.decodeIfPresent(Set<UUID>.self, forKey: .origin) ?? []
    }
}

public extension SZTask {
    /// A title from the words that scheduled it: the first line, clipped. Falls back for an
    /// instruction-less Build press, which is scheduled by a button, not a sentence.
    static func title(fromInstruction instruction: String, nodeCount: Int) -> String {
        let firstLine = instruction
            .split(separator: "\n", omittingEmptySubsequences: true).first
            .map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !firstLine.isEmpty {
            return firstLine.count <= 60 ? firstLine : String(firstLine.prefix(59)) + "…"
        }
        return nodeCount == 1 ? "Implement 1 node" : "Implement \(nodeCount) nodes"
    }
}
