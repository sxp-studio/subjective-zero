// SPDX-License-Identifier: AGPL-3.0-only
// Chat transcript ops on SZStore — the shared path both the SwiftUI chat panel (SZUI) and the host's
// `ui_send_chat` handler (SZApp) use, same as the graph-edit ops (SZStore+GraphEdits.swift).
// Transcripts live in `SZStore.chat` and persist as per-scope sidecars in the .subz bundle
// (SZChatTranscriptIO; flushed/restored by the host) — not part of project.json.
import Foundation

extension SZStore {
    /// The transcript for a scope (empty if none yet).
    public func messages(for scope: SZChatScope) -> [SZChatMessage] { chat[scope.key] ?? [] }

    /// Append a message to a scope's transcript. Returns its id (handy for streaming text into it).
    @discardableResult
    public func appendChatMessage(_ message: SZChatMessage, to scope: SZChatScope) -> UUID {
        chat[scope.key, default: []].append(message)
        return message.id
    }

    /// Append streamed text to an existing message (by id). No-op if the message isn't found. The
    /// whole array is reassigned so the @Observable change fires for the chat panel.
    public func appendChatText(_ delta: String, to messageID: UUID, in scope: SZChatScope) {
        mutateMessage(messageID, in: scope) { $0.text += delta }
    }

    /// Append to a message's "thinking" trace (tool activity / reasoning), shown collapsed in the panel.
    public func appendChatThinking(_ delta: String, to messageID: UUID, in scope: SZChatScope) {
        mutateMessage(messageID, in: scope) { $0.thinking += delta }
    }

    /// Record how long a turn took (set when it finishes) — shown under the reply.
    public func setChatDuration(_ duration: TimeInterval, _ messageID: UUID, in scope: SZChatScope) {
        mutateMessage(messageID, in: scope) { $0.duration = duration }
    }

    /// Record the token usage a turn's CLI reported — shown next to the duration.
    public func setChatUsage(_ usage: SZTokenUsage, _ messageID: UUID, in scope: SZChatScope) {
        mutateMessage(messageID, in: scope) { $0.usage = usage }
    }

    /// Record the envelope a turn ran (set when it finishes) — shown beside the duration.
    /// Release data, unconditional — never gated on tracing.
    public func setChatGeneration(_ generation: SZTurnGeneration, _ messageID: UUID, in scope: SZChatScope) {
        mutateMessage(messageID, in: scope) { $0.generation = generation }
    }

    /// Record a turn's debug breakdown (set when it finishes, tracing on) — the disclosure under
    /// the duration line. Empty in, no-op: absence stays absence.
    public func setChatBreakdown(_ events: [SZTurnEvent], _ messageID: UUID, in scope: SZChatScope) {
        guard !events.isEmpty else { return }
        mutateMessage(messageID, in: scope) { $0.breakdown = events }
    }

    /// Point a turn at the agent-graph run it belongs to — the transcript's jump into the Agent
    /// Graph panel. Written by the host on the run's own narrations, well after they were appended.
    public func setChatGraphRun(_ runID: UUID, _ messageID: UUID, in scope: SZChatScope) {
        mutateMessage(messageID, in: scope) { $0.graphRunID = runID }
    }

    /// Mark a message transient (a host notice, not conversation): the recap skips it.
    public func setChatTransient(_ messageID: UUID, in scope: SZChatScope) {
        mutateMessage(messageID, in: scope) { $0.transient = true }
    }

    /// Replace ALL transcripts at once — the project-open restore path (the host feeds it
    /// `SZChatTranscriptIO.loadAll` filtered to live scopes). One @Observable fire.
    public func restoreChat(_ transcripts: [String: [SZChatMessage]]) {
        chat = transcripts
    }

    /// Drop one message from a scope's transcript (a bubble that turned out to have nothing to
    /// say). No-op if absent. The whole array is reassigned, like `appendChatText`, so the
    /// @Observable change fires for the chat panel.
    public func removeChatMessage(_ messageID: UUID, in scope: SZChatScope) {
        guard var messages = chat[scope.key], messages.contains(where: { $0.id == messageID }) else { return }
        messages.removeAll { $0.id == messageID }
        chat[scope.key] = messages
    }

    /// Drop a scope's transcript entirely (node delete, split/merge purge, the clear button).
    /// No-op if absent; `messages(for:)` reads a removed scope as empty.
    public func removeChat(scopeKey: String) {
        chat.removeValue(forKey: scopeKey)
    }

    /// The project moved: re-point every attachment at the bundle's new location. Message ids,
    /// text and order are untouched, so a turn streaming into a bubble right now is unaffected.
    public func rebaseAttachments(to projectURL: URL) {
        chat = chat.mapValues { messages in
            messages.map { message in
                guard !message.attachments.isEmpty else { return message }
                var m = message
                for i in m.attachments.indices { m.attachments[i].rebase(in: projectURL) }
                return m
            }
        }
    }

    private func mutateMessage(_ id: UUID, in scope: SZChatScope, _ transform: (inout SZChatMessage) -> Void) {
        guard var messages = chat[scope.key], let i = messages.firstIndex(where: { $0.id == id }) else { return }
        transform(&messages[i])
        chat[scope.key] = messages
    }
}
