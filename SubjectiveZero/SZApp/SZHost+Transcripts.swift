// SPDX-License-Identifier: AGPL-3.0-only
// Chat-transcript durability — the host side of the two-layer persistence split:
//
//  - PORTABLE: per-scope transcript sidecars in the .subz bundle (SZChatTranscriptIO). They travel
//    with the project; on a machine with no resumable session, the cold-start recap (SZHost+Chat)
//    replays this history so a fresh agent session catches up.
//  - MACHINE-LOCAL: resumable provider session ids in agent-sessions.json (SZAgentSessionIO) — the
//    same-machine fast path. Best-effort by design: the OS purging the temp working dirs doesn't
//    break ~/.claude / ~/.codex session lookup, but providers may expire threads; a disk-restored
//    session that fails its first resumed turn is dropped (self-heal in `sendChat`) and the next
//    turn cold-starts with the recap.
//
// Flush policy: completed messages only. The currently-streaming assistant message (tracked in
// `inFlightAssistantIDs` by `deliver`) is excluded from every flush and lands on the turn-end flush
// in `deliver`'s defer — so a crash mid-stream restores up to the last finished message, never a
// half-reply. Flush points: message completion, run end, project save, quit. `.debug` never persists.
// No dirty-tracking: sidecars are KB-scale and whole-file atomic rewrites are idempotent.
import Foundation
import SZCore

extension SZHost {
    /// Flush one scope's sidecar — best effort, `.debug` skipped, the in-flight streaming message
    /// filtered out.
    func flushTranscript(_ scope: SZChatScope) {
        guard scope != .debug, let url = loadedProjectURL else { return }
        try? SZChatTranscriptIO.save(persistableMessages(for: scope), scopeKey: scope.key, projectURL: url)
    }

    /// A scope's durable view: completed messages only — the currently-streaming assistant message
    /// and transient host notes ("(busy…)" rejections) are excluded. THE definition shared by flushes
    /// and the cold-start recap, so the two can't drift on what counts as conversation.
    private func persistableMessages(for scope: SZChatScope) -> [SZChatMessage] {
        var messages = store.messages(for: scope).filter { !$0.transient }
        if let inFlight = inFlightAssistantIDs[scope.key] {
            messages.removeAll { $0.id == inFlight }
        }
        return messages
    }

    /// Flush every scope with messages (run end, quit, project save).
    func flushAllTranscripts() {
        for key in store.chat.keys {
            guard let scope = SZChatScope(key: key) else { continue }
            flushTranscript(scope)
        }
    }

    /// Persist the resumable-session map to the machine-local store — called wherever
    /// `agentSessions` changes (deliver's persist point, the run-end fold, self-heal, purge/clear).
    func persistAgentSessions() {
        guard let url = loadedProjectURL else { return }
        try? SZAgentSessionIO.save(agentSessions, projectURL: url)
    }

    /// Project-open restore: transcripts from the bundle sidecars, sessions from the machine-local
    /// store — both filtered to live scopes (the Director + node ids still in the graph; a stale
    /// sidecar for a since-deleted node is ignored, not an error).
    func restoreTranscripts() {
        guard let url = loadedProjectURL else { return }
        let live = Set((store.project?.graph.nodes.map(\.id.uuidString) ?? []) + [SZChatScope.directorKey])
        let restored = SZChatTranscriptIO.loadAll(projectURL: url)
            .filter { live.contains($0.key) }
            .mapValues { Self.sanitized($0, projectURL: url) }
            .filter { !$0.value.isEmpty }
        store.restoreChat(restored)

        agentSessions = SZAgentSessionIO.load(projectURL: url).filter { live.contains($0.key) }
        // Disk-restored sessions are on probation until their first resumed turn succeeds — see the
        // header + the self-heal in `sendChat`. Snapshot by VALUE: a session re-minted this process
        // won't match the snapshot, so it can never be dropped as stale.
        restoredSessions = agentSessions
    }

    /// Delete a node through the host — THE delete path for both the editor panel (`onDeleteNodes`)
    /// and the `ui_remove_node` MCP tool, so the two can't drift.
    @discardableResult
    func deleteNode(id: SZNodeID, origin: SZMutationOrigin = .user) -> Bool {
        deleteNodes(ids: [id], origin: origin)
    }

    /// Batch node delete, done properly: store removal + chat-artifact purge + watcher stop, then ONE
    /// persist + runtime reload (a marquee delete reloads once, not per node) — so deletion is real:
    /// it survives relaunch (project.json no longer carries the node; an unpersisted delete would
    /// zombie back amnesiac, its transcript already purged) and the live render drops the node now.
    /// Mid-run this reloads the runtime exactly like `promoteStagedNode`/split/merge already do.
    ///
    /// Deliberately NOT removed: the node's `nodes/<id>/` folder (Node.swift + contract). With no undo
    /// yet it's the only surviving copy of the node's source, so it stays as an orphan (invisible —
    /// nothing references it; `watchNodeSources` skips non-graph folders). TODO: folder cleanup rides
    /// the undo/checkpoint layer when it ships. Ditto the wider asymmetry that add/move/connect/update
    /// edits still persist only via run/promote — unifying edit persistence belongs to that command/
    /// checkpoint layer, not a delete fix.
    @discardableResult
    func deleteNodes(ids: [SZNodeID], origin: SZMutationOrigin = .user) -> Bool {
        // The fence, not the view filter, is what actually stops a delete of a held node — the
        // keyboard path's isLocked filter is an affordance any future caller can forget.
        if let denial = fenceDenial(nodes: ids, origin: origin) {
            status = denial
            return false
        }
        let titles = ids.compactMap { store.project?.graph.node(id: $0)?.title }
        let removed = ids.filter { store.removeNode(id: $0) }
        guard !removed.isEmpty else { return false }
        purgeChatArtifacts(for: removed)
        persistGraphEditAndReload(action: "deleted \(titles.isEmpty ? "\(removed.count) node(s)" : titles.joined(separator: ", "))")
        return true
    }

    /// Reset one scope's durable chat state — THE shared teardown for the clear button and the node
    /// purge, so the artifact list can't drift between the two: durable attachment copies, transcript
    /// (store + sidecar), resumable session (+ probation), and any queued Director message (it
    /// belongs to the conversation being reset — folding it into a later retry would resurrect
    /// context the user explicitly discarded). Callers persist the session map when done.
    func resetScopeChat(_ scope: SZChatScope) {
        removeAttachmentFiles(for: store.messages(for: scope))
        store.removeChat(scopeKey: scope.key)
        agentSessions[scope.key] = nil
        restoredSessions[scope.key] = nil
        mailbox.removeAll(for: scope.key)   // queued messages die with the conversation (waiters resume .removed)
        if let url = loadedProjectURL { SZChatTranscriptIO.remove(scopeKey: scope.key, projectURL: url) }
    }

    /// Chat-side cleanup for node ids leaving the graph (delete, split/merge commit and rollback):
    /// the shared scope reset PLUS the node-level artifacts a clear deliberately keeps — the status
    /// pill state (node state, not chat state), the open tab, and the source watcher (a removed
    /// node's watcher must stop on EVERY removal path, or an edit to the orphaned `nodes/<id>/`
    /// folder resurrects ghost agent state).
    func purgeChatArtifacts(for ids: some Sequence<SZNodeID>) {
        for id in ids {
            resetScopeChat(.node(id))
            nodeAgentState[id] = nil
            closeChatTab(.node(id))
            stopWatchingNodeSource(id)
        }
        persistAgentSessions()
    }

    /// A bounded, labeled replay of a scope's completed history — the portable catch-up for a chat
    /// turn that cold-starts against an existing transcript (another machine, an expired session,
    /// post-crash). nil when there's nothing to catch up on. Tail-bounded (last 20 messages / ~8 KB):
    /// enough to hit the ground running without ballooning the prompt. Data only — the transcript IS
    /// the context, no framing prose beyond the one-line header.
    /// NOTE: this is the exact seam a future memory system replaces (TODO: distilled project/node
    /// memory files instead of transcript replay).
    /// `excluding` keeps the recap "strictly prior conversation" for a QUEUED delivery: the message
    /// being delivered (and every still-queued bubble behind it) already sits in the store, and a
    /// cold-start recap that replayed it would send the same words twice in one prompt.
    func transcriptRecap(for scope: SZChatScope, excluding: Set<UUID> = []) -> String? {
        guard scope != .debug else { return nil }
        let messages = persistableMessages(for: scope).filter { !excluding.contains($0.id) }
        guard !messages.isEmpty else { return nil }

        let tail = messages.suffix(20)
        var lines: [String] = []
        if tail.count < messages.count { lines.append("(…\(messages.count - tail.count) earlier turns omitted)") }
        for message in tail {
            let label = switch message.role {
            case .user: "user"
            case .assistant: "assistant"
            case .director: "director agent"
            }
            // Mentions replay as readable `@display`; ONE aggregate manifest below re-expands them
            // (per-message manifests would bloat a 20-message replay) — so a fresh session can act
            // on a mention exactly like the live session that first received it.
            lines.append("\(label): \(SZMentionMarkup.plainText(message.text))")
            // Durable attachment copies are readable by absolute path on THIS machine (urls are
            // fixed up against the project at restore) — name them once, here, so a fresh session
            // can Read a previously-attached file. Staging-only attachments (nil bundlePath) are
            // gone by now and stay unmentioned.
            for attachment in message.attachments where attachment.bundlePath != nil {
                lines.append("[attached: \(attachment.url.path)]")
            }
        }
        let graphNodes = (store.project?.graph.nodes ?? []).map { (id: $0.id, title: $0.title) }
        if let manifest = SZMentionExpansion.recapManifest(for: tail.map(\.text), nodes: graphNodes) {
            lines.append("")
            lines.append(manifest)
        }
        var body = lines.joined(separator: "\n")
        if body.count > 8_000 { body = "(…truncated)\n" + String(body.suffix(8_000)) }
        return """
        Prior conversation restored from the project (you are a fresh session; catch up from this):
        ---
        \(body)
        ---
        """
    }

    /// Delete the durable bundle copies referenced by these messages — each attachment's
    /// `attachments/<uuid>/` dir (the clear button, node delete, split/merge purge). Best effort.
    func removeAttachmentFiles(for messages: [SZChatMessage]) {
        guard let projectURL = loadedProjectURL else { return }
        for message in messages {
            for attachment in message.attachments {
                guard let path = attachment.bundlePath else { continue }
                try? FileManager.default.removeItem(
                    at: projectURL.appending(path: path).deletingLastPathComponent())
            }
        }
    }

    /// Restore-side sanitation for one scope: drop empty assistant husks a crash between flushes can
    /// leave (never-completed turns: empty text + thinking, nil duration — narration and guard
    /// replies always carry text, so this only matches true husks), and resolve each attachment's
    /// url from its bundle-relative path against THIS machine's project URL.
    private static func sanitized(_ messages: [SZChatMessage], projectURL: URL) -> [SZChatMessage] {
        messages
            .filter { !($0.role == .assistant && $0.text.isEmpty && $0.thinking.isEmpty && $0.duration == nil) }
            .map { message in
                var m = message
                m.attachments = m.attachments.map { attachment in
                    var a = attachment
                    if let path = a.bundlePath { a.url = projectURL.appending(path: path) }
                    return a
                }
                return m
            }
    }
}
