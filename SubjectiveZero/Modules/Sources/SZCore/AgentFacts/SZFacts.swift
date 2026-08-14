// SPDX-License-Identifier: AGPL-3.0-only
// The one spec for agent facts: this file compiles twice. It compiles normally into SZCore,
// and the SZFactGen build-tool plugin ALSO parses the sentinel-marked region below to
// generate, at build time (never committed):
//   - SZFactCatalog.generated.swift into SZCore (one SZFactRecord per fact field), and
//   - SZStepSDKGenerated.swift into SZRuntime (the region's verbatim text, so the step SDK
//     embeds the same source and decodes the same wire shape).
//
// The region obeys a RIGID grammar the generator enforces with plain string ops
// (Plugins/SZFactGenCore/SZFactGen.swift is the single home; any line it cannot classify
// fails the build):
//   - facts structs:  `public struct SZ<Kind>Facts: Codable, Sendable {`
//   - one `public var name: Type` per line, preceded by exactly ONE `/// doc` line;
//     types drawn from: Int, Bool, String, String?, [String], [String: String]
//   - a trailing `// lazy` marker flags a heavy field the host materializes on first read
//   - effect enums:   `public enum SZ<Kind>Effect: String, Codable, Sendable {` with plain
//     undocumented cases; a kind may have NO effect enum, but never an empty one
//   - free-floating doc lines, nesting, and anything else are build errors
// Prose and derived conveniences live OUTSIDE the sentinels — extensions go below :end.
import Foundation

// SZFactGen:begin

public struct SZBuildFacts: Codable, Sendable {
    /// The work-set node ids still needing a healthy implementation (unimplemented or broken source; empty prompts excluded), graph order.
    public var unimplemented: [String]
    /// The dispatchable node ids of this run's work set.
    public var workSet: [String]
    /// Per-node lifecycle status, keyed by node id.
    public var nodeStatuses: [String: String]
    /// Per-node compile diagnostics from the last build, keyed by node id.
    public var buildErrors: [String: String]
    /// The 1-based settled re-entry count for this run.
    public var round: Int
    /// The round ceiling before the run gives up.
    public var roundCap: Int
    /// Whether the director has been briefed for this run.
    public var briefed: Bool
    /// Whether a project is open at all.
    public var projectLoaded: Bool
    /// The full project graph as JSON — heavy, so the host materializes it lazily, on first read.
    public var graphJSON: String // lazy
    /// Steering messages that arrived since the run began, oldest first.
    public var steers: [String]
    /// The build strategy this run asked for, verbatim as the host resolved it (env > the persisted choice > ""). The graph decides what the name means.
    public var runVariant: String
}

public struct SZChatFacts: Codable, Sendable {
    /// The user message that opened this chat turn.
    public var sentMessage: String
    /// Whether this turn resumes an existing session.
    public var resuming: Bool
    /// Whether this chat turn left new unimplemented work behind.
    public var draftedWork: Bool
    /// The node id this chat is seeded from, when it is anchored to one.
    public var nodeSeed: String?
}

public struct SZWorkFacts: Codable, Sendable {
    /// The 1-based dispatch attempt for this work message.
    public var attempt: Int
    /// The note the sender attached to the handoff, when there is one.
    public var senderNote: String?
    /// What is blocking this work, when it is blocked.
    public var blocker: String?
    /// The session id to resume, when this continues earlier work on the node.
    public var resumeSession: String?
}

public struct SZRequestFacts: Codable, Sendable {
    /// The requested operation.
    public var op: String
    /// The node ids the request acts on.
    public var nodes: [String]
    /// The free-form instruction attached to the request, when there is one.
    public var instruction: String?
}

public enum SZBuildEffect: String, Codable, Sendable {
    case captureStatuses
}

public enum SZChatEffect: String, Codable, Sendable {
    case requestBuild
}

public enum SZRequestEffect: String, Codable, Sendable {
    case split
    case merge
}

// SZFactGen:end

extension SZBuildFacts {
    /// Whether any work-set node still needs implementation. The predicate-named spelling
    /// steps route on; `unimplemented` is its evidence.
    public var hasWorkLeft: Bool { !unimplemented.isEmpty }
}

extension SZBuildFacts {
    /// Whether the fleet is failing rather than progressing: some node reports a stuck
    /// terminal status, or the last build left compile errors behind.
    public var fleetIsFailing: Bool {
        if !buildErrors.isEmpty { return true }
        let stuck: Set<String> = ["stuck", "failed", "error"]
        return nodeStatuses.values.contains { stuck.contains($0) }
    }
}
