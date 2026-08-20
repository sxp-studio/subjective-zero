// SPDX-License-Identifier: AGPL-3.0-only
// Chat transcript types. A conversation is scoped to either the Director or a single node's
// coding agent (docs/UI.md, docs/AGENT_ORCHESTRATION.md). Transcripts live on SZStore (observed by
// the chat panel and the MCP surface) and persist per scope as portable sidecars in the .subz bundle
// — transcripts/<scope.key>.json via SZChatTranscriptIO — NOT in project.json. `.debug` transcripts
// stay ephemeral.
//
// Decoding is append-tolerant: every field with a memberwise default decodes via decodeIfPresent, so
// sidecars written before a field existed keep loading (only a message's `role` is hard-required).
// Keep it that way when adding fields.
import Foundation

public enum SZChatRole: String, Codable, Sendable {
    case user, assistant
    /// A message authored by the Director Agent and shown in ANOTHER agent's tab: the Director
    /// messaging a node's Coding Agent on reconcile, so a node tab reads as a multi-party thread
    /// (you / director / coding agent) instead of the Director's words being an invisible side-channel.
    case director
}

/// Who a chat turn is addressed to. `key` is the stable string used as the transcript-map key and as
/// the `ui_send_chat` `scope` argument: a node's uuid, or `"director"`.
public enum SZChatScope: Hashable, Sendable {
    case director
    case node(SZNodeID)
    /// A debug-only scratch chat agent (a sibling tab to the Director / Coding agents): a plain
    /// provider-backed conversation with no graph/Director responsibilities and no MCP tools, used to
    /// exercise the chat panel — notably file attachments — against a real agent (it can Read and
    /// describe attached files). Opened from the Debug menu.
    case debug

    public static let directorKey = "director"
    public static let debugKey = "debug"

    public var key: String {
        switch self {
        case .director: Self.directorKey
        case .debug: Self.debugKey
        case .node(let id): id.uuidString
        }
    }

    /// The node id this scope targets, or nil for the Director / Debug agents.
    public var nodeID: SZNodeID? {
        if case .node(let id) = self { return id }
        return nil
    }

    /// Parse a scope from its string key — `"director"`, `"debug"`, or a node uuid. nil for anything
    /// else, so a caller (the MCP boundary) surfaces a bad scope instead of silently landing the
    /// message in the Director's transcript.
    public init?(key: String) {
        if key == Self.directorKey {
            self = .director
        } else if key == Self.debugKey {
            self = .debug
        } else if let id = SZNodeID(uuidString: key) {
            self = .node(id)
        } else {
            return nil
        }
    }
}

/// One line of the single chat feed: a message, and the conversation it came from.
///
/// The feed is DERIVED from the per-scope transcripts, never a second copy of them — sessions and
/// cold-start recaps are per scope and stay that way. What it shows is what an agent said to YOU:
/// the whole Director conversation, plus a node agent's own replies. What it leaves out is the
/// fleet's implementation turns, which carry the run they belong to (`graphRunID`) and are read in
/// that task's own drill-in.
public struct SZChatFeedItem: Identifiable, Equatable, Sendable {
    /// Where the message lives — its transcript, and who is speaking when it is not the Director.
    public let scope: SZChatScope
    public let message: SZChatMessage
    public var id: UUID { message.id }

    public init(scope: SZChatScope, message: SZChatMessage) {
        self.scope = scope
        self.message = message
    }
}

/// A resumable agent session captured from a run. The provider is remembered alongside the
/// id because a resume turn must go back to the same CLI that minted/owns the session. Codable for
/// the machine-local session store (SZAgentSessionIO) — both fields are hard-required; a session
/// missing either is useless, so a partial entry fails decode and is treated as absent.
public struct SZAgentSession: Codable, Equatable, Sendable {
    public let providerID: String
    public let sessionID: String
    /// The generation envelope the session opened with — what a resume re-runs when routing
    /// has since moved this position (session affinity). nil on pre-routing session files.
    public var envelope: SZRouteEnvelope?

    public init(providerID: String, sessionID: String, envelope: SZRouteEnvelope? = nil) {
        self.providerID = providerID
        self.sessionID = sessionID
        self.envelope = envelope
    }
}

/// A file attached to a chat turn. The native layer owns the bytes: on send the source file is
/// copied into the agent's staging dir (so a real CLI agent can Read it by absolute path — we never
/// inline bytes into the message bus) AND into the project bundle at `bundlePath`
/// (`attachments/<attachment-uuid>/<filename>`), the canonical copy that persists and travels with
/// the project. `url` points at the canonical copy (the staging copy for `.debug`, whose transcript
/// is ephemeral). `url` is deliberately NOT encoded — absolute machine paths don't belong in a
/// portable sidecar; on restore the host re-derives it from `bundlePath` against the project URL.
public struct SZChatAttachment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var filename: String
    public var url: URL          // absolute path to the readable copy (machine-local, not encoded)
    /// Bundle-relative path of the durable copy (`attachments/<uuid>/<filename>`); nil when no
    /// durable copy exists (debug scope, or the bundle copy failed best-effort).
    public var bundlePath: String?
    public var byteCount: Int
    public var isImage: Bool      // image → render a thumbnail; else → a generic file chip

    public init(id: UUID = UUID(), filename: String, url: URL, bundlePath: String? = nil,
                byteCount: Int, isImage: Bool) {
        self.id = id
        self.filename = filename
        self.url = url
        self.bundlePath = bundlePath
        self.byteCount = byteCount
        self.isImage = isImage
    }
}

extension SZChatAttachment: Codable {
    private enum CodingKeys: String, CodingKey { case id, filename, bundlePath, byteCount, isImage }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        filename = try c.decode(String.self, forKey: .filename)
        bundlePath = try c.decodeIfPresent(String.self, forKey: .bundlePath)
        byteCount = try c.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        isImage = try c.decodeIfPresent(Bool.self, forKey: .isImage) ?? false
        // Dangling until the host fixes it up against the project URL on restore.
        url = URL(fileURLWithPath: bundlePath ?? filename)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(filename, forKey: .filename)
        try c.encodeIfPresent(bundlePath, forKey: .bundlePath)
        try c.encode(byteCount, forKey: .byteCount)
        try c.encode(isImage, forKey: .isImage)
    }
}

/// Token usage for one agent turn, as its CLI reported it. `inputTokens` is the TOTAL prompt side
/// including cached traffic — each provider normalizes its CLI's reporting convention at the parse
/// site (some report the cache separately, some as a subset). A CLI that reports no usage yields no
/// value, not zeros. The share fields exist because the sidecar is a one-way door: once a turn is
/// persisted, a split the parser dropped can't be recovered.
public struct SZTokenUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    /// The cached share of `inputTokens`, where the CLI reports one.
    public var cachedInputTokens: Int?
    /// Reasoning share of `outputTokens`, where the CLI splits it out.
    public var reasoningOutputTokens: Int?
    /// The turn's cost, where the CLI prices it.
    public var costUSD: Double?

    public init(inputTokens: Int, outputTokens: Int, cachedInputTokens: Int? = nil,
                reasoningOutputTokens: Int? = nil, costUSD: Double? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.costUSD = costUSD
    }
}

/// The generation envelope a finished turn actually ran — the transcript's per-turn record.
/// Stamped unconditionally at turn end (never trace-gated); `via` names the routing rule
/// that picked it ("fast-fleet · coding", "session", nil = the default). Display only.
public struct SZTurnGeneration: Codable, Equatable, Sendable {
    public var providerID: String
    public var model: String?
    public var reasoningEffort: String?
    public var fastMode: Bool
    public var via: String?

    public init(providerID: String, model: String? = nil, reasoningEffort: String? = nil,
                fastMode: Bool = false, via: String? = nil) {
        self.providerID = providerID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.fastMode = fastMode
        self.via = via
    }

    /// "codex · gpt-5.6-terra · high · fast" — empty parts drop out.
    public var label: String {
        ([providerID, model, reasoningEffort].compactMap { $0 }
            + (fastMode ? ["fast"] : [])).joined(separator: " · ")
    }
}

/// A finished build, as one line of the conversation: the strip's own lane, settled.
///
/// A run is a state while it happens (the run strip owns that) and a RECEIPT once it is over —
/// the same object at two moments, not two vocabularies. The strip's group vanishes when the run
/// ends, so this is the transcript's only durable record that a build happened, and the message's
/// `graphRunID` is what makes it a way back into the Agent Graph.
///
/// It carries no clock of its own: a receipt turn reuses `duration`, the field an agent turn
/// already spends on "Worked for 21s".
public struct SZChatReceipt: Equatable, Sendable {
    /// What the run did, in the lane's name slot — "built Warm Orange", "built 3 nodes",
    /// "built 2 of 3". The work, never a run id: with several builds finishing at once, a count
    /// alone made three different runs read as one sentence repeated.
    public var label: String
    /// The ending, in the ONE badge vocabulary (`SZRunBadge.style(for:)`) — so a receipt, a strip
    /// lane and a RUNS row all say the same word for the same fact. This is the run's ACCOUNTING
    /// outcome, which a traversal's own conclusion need not match: a build whose traversal ended
    /// cleanly with a node unimplemented is `.failed` here, because that is what happened to the
    /// work.
    public var conclusion: SZAgentGraphRun.Conclusion
    /// The one thing a lane cannot say for itself — why a build died (a dead CLI, a spent budget),
    /// shown as a quiet line under the pill. nil on every healthy ending: a run that worked owes no
    /// explanation, and the nodes it could not finish explain themselves in their own turns.
    public var detail: String?

    public init(label: String, conclusion: SZAgentGraphRun.Conclusion, detail: String? = nil) {
        self.label = label
        self.conclusion = conclusion
        self.detail = detail
    }

    // MARK: - What a finished build says
    //
    // Pure, so the wording is testable without a host and a run. `work` is the ONE node's title
    // when the run had exactly one — naming it is what stops three concurrent one-node builds from
    // finishing as the same sentence three times.

    /// The run reached its own end.
    public static func forEnding(implemented: Int, failed: Int, work: String?) -> SZChatReceipt {
        // Some of the work did not land: say the shortfall, and badge it as such even though the
        // TRAVERSAL ended cleanly — the receipt reports on the work, not on the graph walk.
        if failed > 0 {
            return SZChatReceipt(label: shortfallLabel(implemented: implemented, failed: failed, work: work),
                                 conclusion: .failed(reason: "\(failed) unfinished"))
        }
        return SZChatReceipt(label: builtLabel(implemented, work: work), conclusion: .ended)
    }

    /// Someone stopped the run. A Stop is not a failure, so the badge stays neutral either way;
    /// what changes is whether there is a shortfall worth naming.
    public static func forStop(implemented: Int, unfinished: Int, work: String?) -> SZChatReceipt {
        let label = unfinished > 0
            ? "\(unfinished) node\(unfinished == 1 ? "" : "s") unfinished"
            : builtLabel(implemented, work: work)
        return SZChatReceipt(label: label, conclusion: .cancelled)
    }

    /// The run threw — the reason rides along, because nothing else in the transcript will say it.
    public static func forFailure(implemented: Int, unfinished: Int, work: String?,
                                  reason: String) -> SZChatReceipt {
        SZChatReceipt(label: shortfallLabel(implemented: implemented, failed: unfinished, work: work),
                      conclusion: .failed(reason: reason), detail: reason)
    }

    /// A run that fell short. The single-node case is NAMED for the same reason the healthy one is:
    /// a dead CLI takes down whichever builds were in flight, and three of them all reading
    /// "built 0 of 1" — with the same reason underneath — is the exact indistinguishability this
    /// whole change exists to remove. Counts carry the rest, where no one name would be true.
    private static func shortfallLabel(implemented: Int, failed: Int, work: String?) -> String {
        if implemented == 0, failed == 1, let work, !work.isEmpty { return "\(work) unfinished" }
        return "built \(implemented) of \(implemented + failed)"
    }

    // MARK: - Codable
    //
    // HAND-WRITTEN, for the same reason `SZChatAttachment` and `SZTurnEvent` are. `conclusion` is
    // an enum WITH ASSOCIATED VALUES on synthesized Codable, so an unrecognized case does not
    // decode as nil — it THROWS ("Invalid number of keys found, expected one"), and
    // `decodeIfPresent` does not absorb that. One throw unwinds the whole `messages` array →
    // `SZChatTranscriptIO.load`'s `try?` → nil → the scope loads with NO history → the next flush
    // writes that emptiness back over the sidecar. A conversation would be destroyed, silently, by
    // something as ordinary as adding a case to `SZTraversalEnding` and then opening the project
    // under an older build. So the receipt degrades and the MESSAGE always survives: an ending we
    // cannot read is reported as `.ended`, and the words in `text` are the durable fact regardless.

    private enum CodingKeys: String, CodingKey { case label, conclusion, detail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        conclusion = (try? c.decode(SZAgentGraphRun.Conclusion.self, forKey: .conclusion)) ?? .ended
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(conclusion, forKey: .conclusion)
        try c.encodeIfPresent(detail, forKey: .detail)
    }
}

extension SZChatReceipt: Codable {}

extension SZChatReceipt {
    /// "built Warm Orange" when a run had one node, a count otherwise — and an honest sentence
    /// when a build found nothing to do, which is a real outcome and not an empty one.
    private static func builtLabel(_ implemented: Int, work: String?) -> String {
        if implemented == 0 { return "nothing needed building" }
        if implemented == 1, let work, !work.isEmpty { return "built \(work)" }
        return "built \(implemented) node\(implemented == 1 ? "" : "s")"
    }
}

public struct SZChatMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var role: SZChatRole
    public var text: String
    /// The agent's working trace for this turn — tool activity + reasoning/narration — shown in a
    /// collapsible "thinking" disclosure (assistant turns only). Empty when there's nothing to show.
    public var thinking: String
    public let timestamp: Date
    /// How long the turn took (assistant turns) — nil while in flight, set when the turn finishes; shown
    /// under the reply.
    public var duration: TimeInterval?
    /// Token usage the turn's CLI reported (assistant turns) — nil while in flight and for CLIs that
    /// report none; shown next to the duration.
    public var usage: SZTokenUsage?
    /// The turn's debug breakdown — timed phases/instants the host stamped while the turn ran
    /// (queue wait, first output, tool calls, compile/promote…). nil when tracing was off or the
    /// turn recorded nothing; shown as a disclosure under the duration line.
    public var breakdown: [SZTurnEvent]?
    /// Files attached to this turn (user turns) — copied into the agent's staging dir on send, shown
    /// as thumbnails/chips under the message. Empty for turns with no attachments.
    public var attachments: [SZChatAttachment]
    /// A host-authored passing note (a send rejection like "(busy…)"), shown in the tab but excluded
    /// from persistence AND the cold-start recap — it isn't conversation, and replaying it to a fresh
    /// agent session (or restoring it as history) would misrepresent what was said.
    public var transient: Bool
    /// The agent-graph run this turn belongs to (`SZAgentGraphRun.id`) — the transcript's jump into
    /// the Agent Graph panel. Stamped on the run's own narrations; nil on everything else. NOT the
    /// Profiler's `SZTurnEvent.runID`: that is the trace identity, and the two are different ids.
    public var graphRunID: UUID?
    /// The envelope the turn ran (assistant turns) — nil while in flight and on records that
    /// predate receipts; shown beside the duration.
    public var generation: SZTurnGeneration?
    /// Set when this turn IS a finished build rather than something someone said — rendered as a
    /// settled lane instead of a speaker's turn. nil on every ordinary message.
    public var receipt: SZChatReceipt?

    public init(id: UUID = UUID(), role: SZChatRole, text: String, thinking: String = "",
                timestamp: Date = Date(), duration: TimeInterval? = nil, usage: SZTokenUsage? = nil,
                breakdown: [SZTurnEvent]? = nil, attachments: [SZChatAttachment] = [],
                transient: Bool = false, graphRunID: UUID? = nil,
                generation: SZTurnGeneration? = nil, receipt: SZChatReceipt? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.thinking = thinking
        self.timestamp = timestamp
        self.duration = duration
        self.usage = usage
        self.breakdown = breakdown
        self.attachments = attachments
        self.transient = transient
        self.graphRunID = graphRunID
        self.generation = generation
        self.receipt = receipt
    }
}

extension SZChatMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, role, text, thinking, timestamp, duration, usage, breakdown, attachments, transient
        case graphRunID, generation, receipt
    }

    // Hand-written for append tolerance (see header).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decode(SZChatRole.self, forKey: .role)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        thinking = try c.decodeIfPresent(String.self, forKey: .thinking) ?? ""
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        usage = try c.decodeIfPresent(SZTokenUsage.self, forKey: .usage)
        breakdown = try c.decodeIfPresent([SZTurnEvent].self, forKey: .breakdown)
        attachments = try c.decodeIfPresent([SZChatAttachment].self, forKey: .attachments) ?? []
        transient = try c.decodeIfPresent(Bool.self, forKey: .transient) ?? false
        graphRunID = try c.decodeIfPresent(UUID.self, forKey: .graphRunID)
        // `try?` on both extras: a value of the wrong SHAPE entirely (a string where an object
        // belongs) throws in `decodeIfPresent` before any tolerant decoder runs. The message
        // survives either way — its `text` still says what happened.
        generation = (try? c.decodeIfPresent(SZTurnGeneration.self, forKey: .generation)) ?? nil
        receipt = (try? c.decodeIfPresent(SZChatReceipt.self, forKey: .receipt)) ?? nil
    }

    // Hand-written to keep the common case clean: `duration` and `transient` are omitted rather
    // than written as null/false on every message. (Transient messages shouldn't normally reach
    // disk at all — the host filters them from flushes — but the shape stays honest if one does.)
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(text, forKey: .text)
        try c.encode(thinking, forKey: .thinking)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(usage, forKey: .usage)
        try c.encodeIfPresent(breakdown, forKey: .breakdown)
        try c.encode(attachments, forKey: .attachments)
        if transient { try c.encode(true, forKey: .transient) }
        try c.encodeIfPresent(graphRunID, forKey: .graphRunID)
        try c.encodeIfPresent(generation, forKey: .generation)
        try c.encodeIfPresent(receipt, forKey: .receipt)
    }
}
