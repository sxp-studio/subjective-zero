// SPDX-License-Identifier: AGPL-3.0-only
// The typed per-node agent lifecycle state the host tracks during runs / chat turns / hot reloads —
// one struct per node, keyed by SZNodeID.
// The AGENT-facing wire stays strings (`agent_report_status` status values, the reconcile-prompt
// blocker lines); this is the HOST-internal representation, converted at the MCP boundary.
import Foundation

/// A node's last observable agent/workflow phase. `.idle` = nothing reported (a fresh node); the rest
/// mirror the `agent_report_status` vocabulary (queued/planning/coding/ok/needsInput/error) plus the
/// host's own `.reloading` (a hand-edited Node.swift recompiling). Raw values are the wire spelling.
public enum SZNodeAgentPhase: String, Sendable, Equatable {
    case idle
    case queued
    case planning
    case coding
    case ok
    case needsInput
    case reloading
    case error

    /// Map a wire status string (an `agent_report_status` `status` argument) to a phase — tolerant of
    /// the loose spellings agents produce, mirroring the editor's historical prefix/contains checks.
    /// Anything unrecognized reads as `.ok` (it never drove a pill before either).
    public init(wire status: String) {
        let s = status.lowercased()
        if s.hasPrefix("error") { self = .error }
        else if s.contains("needs") { self = .needsInput }
        else if s.hasPrefix("reloading") { self = .reloading }
        else if s.hasPrefix("coding") { self = .coding }
        else if s.hasPrefix("queued") { self = .queued }
        else if s.hasPrefix("planning") { self = .planning }
        else { self = .ok }
    }
}

/// The full per-node agent state: the phase + its concise message (the pill/prompt line), the full
/// diagnostic behind a failure (the clickable error pill's copyable popover), and whether the node's
/// Coding Agent is mid-chat-turn (shown Coding + locked, independent of the reported phase).
public struct SZNodeAgentState: Sendable, Equatable {
    public var phase: SZNodeAgentPhase
    /// The concise human/LLM-readable detail for the phase ("" if none) — an agent's report message,
    /// or the first swiftc error line on a failed hot reload.
    public var message: String
    /// The full diagnostic when the node failed (swiftc log / agent message) — the error pill's
    /// copyable popover. nil once the node compiles again.
    public var errorDetail: String?
    /// The node's Coding Agent is mid-chat-turn (`ui_send_chat` to the node) — editor shows Coding +
    /// locks the card, exactly like a run does.
    public var isChatting: Bool

    public init(phase: SZNodeAgentPhase = .idle, message: String = "",
                errorDetail: String? = nil, isChatting: Bool = false) {
        self.phase = phase
        self.message = message
        self.errorDetail = errorDetail
        self.isChatting = isChatting
    }

    /// The status line the wire/prompts carry — the historical `"<status>: <message>"` shape
    /// (`debug_agent_state` `statuses`, the Director's reconcile-prompt blocker lines).
    public var line: String { message.isEmpty ? phase.rawValue : "\(phase.rawValue): \(message)" }
}
