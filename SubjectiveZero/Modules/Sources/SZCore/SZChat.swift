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

/// A resumable agent session captured from a run. The provider is remembered alongside the
/// id because a resume turn must go back to the same CLI that minted/owns the session. Codable for
/// the machine-local session store (SZAgentSessionIO) — both fields are hard-required; a session
/// missing either is useless, so a partial entry fails decode and is treated as absent.
public struct SZAgentSession: Codable, Equatable, Sendable {
    public let providerID: String
    public let sessionID: String

    public init(providerID: String, sessionID: String) {
        self.providerID = providerID
        self.sessionID = sessionID
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
    /// Files attached to this turn (user turns) — copied into the agent's staging dir on send, shown
    /// as thumbnails/chips under the message. Empty for turns with no attachments.
    public var attachments: [SZChatAttachment]
    /// A host-authored passing note (a send rejection like "(busy…)"), shown in the tab but excluded
    /// from persistence AND the cold-start recap — it isn't conversation, and replaying it to a fresh
    /// agent session (or restoring it as history) would misrepresent what was said.
    public var transient: Bool

    public init(id: UUID = UUID(), role: SZChatRole, text: String, thinking: String = "",
                timestamp: Date = Date(), duration: TimeInterval? = nil,
                attachments: [SZChatAttachment] = [], transient: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.thinking = thinking
        self.timestamp = timestamp
        self.duration = duration
        self.attachments = attachments
        self.transient = transient
    }
}

extension SZChatMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, role, text, thinking, timestamp, duration, attachments, transient
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
        attachments = try c.decodeIfPresent([SZChatAttachment].self, forKey: .attachments) ?? []
        transient = try c.decodeIfPresent(Bool.self, forKey: .transient) ?? false
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
        try c.encode(attachments, forKey: .attachments)
        if transient { try c.encode(true, forKey: .transient) }
    }
}
