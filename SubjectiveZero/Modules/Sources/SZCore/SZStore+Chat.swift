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

    /// Replace ALL transcripts at once — the project-open restore path (the host feeds it
    /// `SZChatTranscriptIO.loadAll` filtered to live scopes). One @Observable fire.
    public func restoreChat(_ transcripts: [String: [SZChatMessage]]) {
        chat = transcripts
    }

    /// Drop a scope's transcript entirely (node delete, split/merge purge, the clear button).
    /// No-op if absent; `messages(for:)` reads a removed scope as empty.
    public func removeChat(scopeKey: String) {
        chat.removeValue(forKey: scopeKey)
    }

    private func mutateMessage(_ id: UUID, in scope: SZChatScope, _ transform: (inout SZChatMessage) -> Void) {
        guard var messages = chat[scope.key], let i = messages.firstIndex(where: { $0.id == id }) else { return }
        transform(&messages[i])
        chat[scope.key] = messages
    }
}
