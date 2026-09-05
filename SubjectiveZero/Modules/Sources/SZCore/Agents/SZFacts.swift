// SPDX-License-Identifier: AGPL-3.0-only
// The spec of everything a step can read. It compiles into SZCore, and SZFactGen splices
// the sentinel-marked region into the step kit verbatim — one source on both sides of the
// ABI.
//
// The model: a message is WORDS. Everything structural is world state, true between
// messages (a run exists, an assignment stands). New machinery mints
// world state; the message never grows.
//
// The consumer rule: every field's doc names the shipped reader. A fact nothing reads is
// deleted. Growing the spec = add the field here, project it in SZWorld.
//
// Grammar (enforced by Plugins/SZFactGenCore, any other line fails the build): structs
// `public struct SZ<Name>: Codable, Sendable {` (one must be SZFacts, the wire document);
// one documented `public var name: Type` per line (Int, Int?, Bool, String, String?,
// [String], UUID?, [UUID], [String: String], or an optional of a struct declared here);
// `public init` blocks pass through unparsed; at most one `SZEffect` string enum.
// Conveniences go below the end sentinel.
import Foundation

// SZFactGen:begin

public struct SZFacts: Codable, Sendable {
    /// The delivered message — what was said; "" when machinery knocks. Read by the doors' triage and every `{{message}}` brief.
    public var message: String
    /// The node this delivery is bound to (its scope); nil = a director/debug conversation. Read by `{{node}}` briefs and the blocker derivation.
    public var node: UUID?
    /// Whether this scope already has a session — the doors' cold-vs-resumed fork.
    public var resuming: Bool
    /// The granted build this delivery serves, while one is live; nil otherwise. The director door's `build` ruling.
    public var run: SZRun?
    /// The standing work assigned to this scope, surviving the retry loop; nil when none. The coding door's `implement`-vs-`continue` fork.
    public var assignment: SZAssignment?
    /// Tasks scheduled but not yet started, oldest first. The director door's `amend`-vs-`schedule` fork — with none, there is nothing to fold into and the ruling cannot be `amend`. Their titles are the `{{tasks}}` brief token.
    public var pendingTasks: [UUID]
    /// Tasks being built now, oldest first. The other half of the director door's `amend` fork: without it a message about work under way can only schedule a second run over the same nodes. Listed beside the scheduled ones in `{{tasks}}`.
    public var runningTasks: [UUID]

    public init(message: String, node: UUID? = nil, resuming: Bool = false,
                run: SZRun? = nil, assignment: SZAssignment? = nil,
                pendingTasks: [UUID] = [], runningTasks: [UUID] = []) {
        self.message = message
        self.node = node
        self.resuming = resuming
        self.run = run
        self.assignment = assignment
        self.pendingTasks = pendingTasks
        self.runningTasks = runningTasks
    }
}

public struct SZRun: Codable, Sendable {
    /// The run's still-owed work — what a dispatch sends, and `hasWorkLeft`'s evidence.
    public var workSet: [UUID]
    /// The 1-based dispatch round — the reconcile brief's `{{round}}`.
    public var round: Int
    /// The retry budget, read off the settled edge's leash — the reconcile brief's `{{cap}}`.
    public var roundCap: Int
    /// Steering messages folded into the NEXT brief, oldest first — the reconcile brief's `{{inbox}}`.
    public var steers: [String]
    /// The run's standing instruction — the decompose brief's `{{instruction}}`.
    public var instruction: String
    /// Work-set nodes with an arrow nobody wired. `hasWorkLeft`'s other evidence, and the reconcile brief's `{{unwired}}`.
    public var unwired: [UUID]
    /// What the run is for when it is not a build (`SZRunIntent.convert` after a target switch, as its raw value); nil for a build. The director door's `convert` ruling.
    public var intent: String?

    public init(workSet: [UUID], round: Int, roundCap: Int, steers: [String],
                instruction: String, unwired: [UUID] = [], intent: String? = nil) {
        self.workSet = workSet
        self.round = round
        self.roundCap = roundCap
        self.steers = steers
        self.instruction = instruction
        self.unwired = unwired
        self.intent = intent
    }
}

public struct SZAssignment: Codable, Sendable {
    /// The 1-based attempt this delivery is — the coding door's retry fork. A node whose last attempt the host failed (a spent budget) and whose session survived counts its next dispatch as a retry, so the agent continues rather than starting over.
    public var attempt: Int
    /// The sender's note riding the handoff, when there is one — the work brief's `{{director_message}}`.
    public var note: String?

    public init(attempt: Int, note: String? = nil) {
        self.attempt = attempt
        self.note = note
    }
}

public enum SZEffect: String, Codable, Sendable {
    case requestBuild
}

// SZFactGen:end

extension SZFacts {
    /// Whether the run still owes work: nodes to build, or nodes carrying an arrow nobody wired. A
    /// node that builds leaves the first list and stays in the second, which is how a run used to end
    /// over a built node whose declared inputs were never connected.
    public var hasWorkLeft: Bool {
        guard let run else { return false }
        return !run.workSet.isEmpty || !run.unwired.isEmpty
    }
}

