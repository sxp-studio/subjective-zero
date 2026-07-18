// SPDX-License-Identifier: AGPL-3.0-only
// Chat-panel state + messaging — the host-owned tab bookkeeping (open / select / close / reorder
// the Director + per-node chat tabs, driven by both the SwiftUI panel and the `ui_*` MCP surface) and
// `sendChat`, the interactive `ui_send_chat` entry point that cold-starts or resumes an agent session
// and streams the reply through the shared `deliver` substrate.
import Foundation
import SZAI
import SZCore
import SZUI
import UniformTypeIdentifiers

extension SZHost {
    /// The composer autocomplete's pickable @mentions — the addressable ENTITIES: the project
    /// (routed to the Director Agent), every node (broadcast intent, also the Director Agent's to
    /// fan out), and each node (its Coding Agent). Computed from the live graph so a rename shows
    /// immediately; a token freezes whatever title it was picked under.
    var mentionCandidates: [SZMentionCandidate] {
        var candidates = [
            SZMentionCandidate(target: .project, title: "project", sfSymbol: "sparkles",
                               subtitle: "Director Agent"),
            SZMentionCandidate(target: .all, title: "all", sfSymbol: "asterisk",
                               subtitle: "every node · Director Agent"),
        ]
        for node in store.project?.graph.nodes ?? [] {
            candidates.append(SZMentionCandidate(
                target: .node(node.id), title: node.title.isEmpty ? "Untitled" : node.title,
                sfSymbol: node.sfSymbol, subtitle: "Coding Agent"))
        }
        return candidates
    }

    /// Land a host-drafted message in the composer (a context-menu suggestion click): stage the
    /// draft and reveal the recipient's tab. The panel applies it and emphasizes send until acted
    /// on — V1 ruling: suggestions COMPOSE, they never auto-send.
    func injectComposerDraft(_ draft: SZComposerDraft, scope: SZChatScope,
                             replacesNonEmpty: Bool = true) {
        // Inside the Project tab you already address the Director — a leading @project mention is
        // redundant there (and reads oddly). Route stays correct: no leading mention → the Project tab.
        let draft = scope == .director ? draft.strippingLeadingProjectMention() : draft
        pendingComposerDraft = SZComposerDraftInjection(scope: scope, draft: draft,
                                                        replacesNonEmpty: replacesNonEmpty)
        showChat(scope)
    }

    /// The panel applied an injection — id-checked so a stale consume can't drop a newer draft.
    func consumeComposerDraft(_ id: UUID) {
        if pendingComposerDraft?.id == id { pendingComposerDraft = nil }
    }

    /// Scopes whose agent reported it's blocked on the USER (`needsInput`) — the amber tab dot.
    /// Derived live from the typed per-node state, so it clears the moment the agent moves on.
    var needsInputScopes: Set<String> {
        Set(nodeAgentState.filter { $0.value.phase == .needsInput }
            .map { SZChatScope.node($0.key).key })
    }

    /// Select/open a chat tab (a node's bubble, a tab click, or `ui_select_chat`). A node or debug scope
    /// opens a tab if new; either way it becomes active and the panel is shown.
    func showChat(_ scope: SZChatScope) {
        if scope != .director, !tabOrder.contains(scope) { tabOrder.append(scope) }
        activeChatScope = scope
        unreadScopes.remove(scope.key)   // visiting a tab clears its unread dot
        showPanel(.chat)
    }

    /// Open a chat tab WITHOUT making it active or stealing focus — used during a Director run so each
    /// dispatched node's Coding Agent tab appears (and the panel is shown) while the active tab stays put
    /// (the user watches the Director tab; they click into a node tab to see its detail). Idempotent.
    func openChatTab(_ scope: SZChatScope) {
        if scope != .director, !tabOrder.contains(scope) { tabOrder.append(scope) }
        showPanel(.chat)
    }

    /// How many nodes await the fleet — never built, or built against a contract that has since moved. The HUD
    /// Build button's count badge.
    var pendingNodeCount: Int {
        store.project?.graph.nodes.filter(\.needsImplementation).count ?? 0
    }

    /// Pending prompt nodes with no run in flight = work waiting to be kicked off — gates the HUD
    /// Build button's appearance + pulse (see also `pendingNodeCount` for the badge).
    var pendingWorkAvailable: Bool {
        !isRunning && pendingNodeCount > 0
    }

    /// The active node is mid-split/merge → its composer is locked (the node may not exist when the
    /// op settles, so queueing to it would be a lie). A node that is merely mid-chat no longer
    /// locks its composer: a send while its agent streams simply queues — the whole point of the
    /// mailbox — and the queue serializes delivery.
    var activeScopeLocked: Bool {
        guard case .node(let id) = activeChatScope else { return false }
        return graphOpStatus[id] != nil
    }

    /// HUD message icon — a plain toggle for the Director Agent chat: show it (scoped to the Director)
    /// or hide it if it's already the shown Director chat. Kicking off pending work now lives on the
    /// HUD Build button, so this icon no longer drafts an implement message.
    func toggleDirectorChat() {
        if chatVisible && activeChatScope == .director {
            closePanel(.chat)
        } else {
            activeChatScope = .director
            unreadScopes.remove(SZChatScope.directorKey)
            showPanel(.chat)
        }
    }

    /// Close a node or debug chat tab (its ✕ / `ui_close_chat_tab`). The Director tab can't be closed;
    /// closing the active tab falls back to the Director.
    func closeChatTab(_ scope: SZChatScope) {
        guard scope != .director else { return }
        tabOrder.removeAll { $0 == scope }
        unreadScopes.remove(scope.key)
        if activeChatScope == scope { activeChatScope = .director }
    }

    /// Clear a chat tab (the header trash) — a FULL reset via the shared scope teardown
    /// (`resetScopeChat`): transcript (store + sidecar), durable attachment copies, the resumable
    /// session, and any queued Director message — so the next turn cold-starts a fresh agent with
    /// no history (no recap either; the history is gone by choice). Clearing only the visible
    /// transcript while the CLI session still "remembers" would be misleading. Refused while the
    /// scope is streaming; the tab (and a node's status pill) stays — those aren't chat state.
    func clearChatTranscript(_ scope: SZChatScope) {
        guard !chatInFlight.contains(scope.key) else { return }
        resetScopeChat(scope)
        persistAgentSessions()
    }

    /// Reorder tabs (drag-to-reorder): move the dragged tab in front of `target`, or to the end when
    /// `target` is nil (dropped past the last tab). Any tab — including the Director — can be moved.
    func reorderChatTabs(move dragged: SZChatScope, before target: SZChatScope?) {
        guard let i = tabOrder.firstIndex(of: dragged) else { return }
        tabOrder.remove(at: i)
        if let target, let j = tabOrder.firstIndex(of: target) {
            tabOrder.insert(dragged, at: j)
        } else {
            tabOrder.append(dragged)            // nil target (or target gone) → drop at the end
        }
    }

    /// Who initiated a chat send — the panel composer (`.user`) or an MCP `ui_send_chat` call
    /// (`.agent`, e.g. the Director Agent). The one place the two senders legitimately diverge is a
    /// node-scoped message DURING a run: from an agent it's the Director steering that node's Coding
    /// Agent (recorded for the reconcile loop); from the user it gets the busy guard (TODO: mid-run
    /// user messaging).
    enum SZChatSendOrigin { case user, agent }

    /// How `sendChat` routed a message: answered synchronously by a transient guard reply (`.sent`,
    /// no envelope), enqueued for delivery (`.queued` — possibly starting immediately; the id is
    /// the envelope's, pollable via `ui_message_status`), or recorded as a `.steer` for the
    /// reconcile loop (`.recordedForReconcile`).
    enum SZChatSendRouting: Equatable {
        case sent
        case queued(UUID)
        case recordedForReconcile(UUID)
    }

    /// Send a chat message to an agent — THE single entry point for both the chat panel's composer and
    /// the `ui_send_chat` MCP tool, so the two paths can't drift. Reveals the scope's tab,
    /// records the user message, opens an empty assistant message, and streams the reply into it.
    /// A node-scoped chat resumes that node's coding-agent session (built by a run, so it carries
    /// the node's context); a Director chat resumes its session or, on the first turn, starts a fresh
    /// one. Fire-and-forget: streams via the provider's `onOutput` → `assistantText` → transcript.
    /// A fresh session (first-turn Director Agent chat) uses the host's `activeProviderID`; resuming an
    /// existing session ignores it and continues on the CLI that owns that session.
    @discardableResult
    func sendChat(scope: SZChatScope, message: String, attachments: [URL] = [],
                  origin: SZChatSendOrigin = .user) -> SZChatSendRouting {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return .sent }

        // V1 routing (SZChatRouting — the policy seam): a USER message that leads with a mention
        // goes to that entity's agent; `scope` (the composing tab) is only the fallback. Agent-
        // origin sends keep their explicit scope — the Director addressing a node must not be
        // re-routed by mentions inside its own words.
        var scope = scope
        if origin == .user {
            let resolved = SZChatRouting.resolveRecipient(message: trimmed, activeScope: scope)
            if case .node(let id) = resolved, store.project?.graph.node(id: id) == nil {
                // The leading mention names a node that no longer exists — refuse in the composing
                // tab (transient, like the other pre-flight rejections) rather than streaming into
                // a hidden transcript.
                store.appendChatMessage(
                    SZChatMessage(role: .assistant,
                                  text: "(that mention's node no longer exists — message not sent)",
                                  transient: true), to: scope)
                return .sent
            }
            scope = resolved
        }

        // Agent-origin messages DURING a run are fleet-internal steering — recorded, never a nested
        // turn inside a synchronous MCP handler (deadlock-safe: its connection thread is blocked on a
        // semaphore until we return). Neither path steals the tab. A USER's mid-run message falls
        // through instead.
        if origin == .agent, isRunning {
            // Director → a node the run owns: folded into that node's reconcile retry.
            if let nodeID = scope.nodeID, ledger.holder(of: .node(nodeID)) == runClaim {
                return .recordedForReconcile(recordDirectorMessage(node: nodeID, message: trimmed))
            }
            // Coding agent → the Director: rendered into the next reconcile turn's prompt
            // (previously appended to the tab and read by no LLM — a silent black hole).
            if scope == .director {
                return .recordedForReconcile(recordDirectorInboxMessage(trimmed))
            }
            // A node the run does NOT own falls through to the normal enqueue path below.
        }

        showChat(scope)   // reveal/focus the tab — 1:1 with clicking it before typing

        // A pre-flight rejection: shown in the tab but TRANSIENT — never flushed, never recapped.
        // It isn't conversation; restoring "(busy…)" as assistant history (or replaying it to a
        // fresh session) would misrepresent what was said. Only checks queueing can't fix reject
        // here — a busy scope/run is exactly what the queue is for.
        @discardableResult
        func reject(_ note: String) -> SZChatSendRouting {
            store.appendChatMessage(SZChatMessage(role: .assistant, text: note, transient: true), to: scope)
            return .sent
        }

        // Stage attachments on disk first (the native layer owns the bytes): copy each picked/dropped/
        // pasted file into the agent's working dir so a real CLI agent can Read it by absolute path, and
        // so the copy outlives the source URL. The user turn carries the DURABLE records (bundle copies
        // that persist + travel — and that a delivery after a restart can still point the agent at).
        // `.debug` stays staging-only, ephemeral like its transcript.
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "sz-agent-cache")
        let workingDirectory = cacheDirectory.appending(path: "agent/\(scope.key)")
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let staged = Self.stageAttachments(attachments, into: workingDirectory)
        let durable = scope == .debug ? staged : persistAttachmentCopies(staged)
        let userMessage = SZChatMessage(role: .user, text: trimmed, attachments: durable)
        store.appendChatMessage(userMessage, to: scope)

        // Enqueue-time pre-flights — problems no amount of waiting fixes. (Provider readiness is
        // ALSO checked at delivery; the world can change while a message waits.)
        guard agentMCPServer?.port != nil, loadedProjectURL != nil else {
            flushTranscript(scope)
            return reject("(host not ready)")
        }
        let existing = agentSessions[scope.key]
        let providerID = existing?.providerID ?? activeProviderID
        if SZProviderRegistry.shared.provider(id: providerID) == nil {
            flushTranscript(scope)
            return reject("(unknown provider \(providerID))")
        }
        if existing == nil, !isProviderReadyForNewWork(providerID) {
            surfaceProviderNotReady()
            flushTranscript(scope)
            return reject("(\(providerID) is not ready — open Agent Providers)")
        }

        // Queue-everywhere: EVERY send is an envelope; the pump delivers it the moment the scope is
        // free (immediately for an idle scope — the common case is one synchronous hop away). The
        // old rejections ("still replying…", "busy — stop the run…") are gone: a busy scope just
        // means the message waits its turn, visibly queued on its bubble. Envelope BEFORE the
        // transcript flush: a crash between the two leaves envelope-without-bubble (tolerated —
        // redelivery re-appends), never bubble-without-envelope (silent loss).
        let envelope = SZMessageEnvelope(
            recipient: scope.key, sender: origin == .user ? "user" : nil, intent: .chat,
            message: userMessage, transcriptMessageID: userMessage.id)
        mailbox.enqueue(envelope)
        flushTranscript(scope)   // the user's words are durable even if delivery waits or dies
        pumpMailboxes()
        return .queued(envelope.id)
    }

    /// Stop one scope's in-flight chat turn (the transcript's per-turn stop control): cancel its
    /// task — SZProcess SIGKILLs the CLI on cancellation — leaving the session (a killed resume
    /// is still resumable) and the transcript (partial text + "(stopped)") in place. A no-op for
    /// a scope with nothing in flight. Run-driven coding turns are `cancelRun`'s job, not this.
    func cancelChatTurn(_ scope: SZChatScope) {
        chatTurnTasks[scope.key]?.cancel()
    }

    /// Self-heal for expired sessions: a DISK-restored session (on probation — `restoredSessions`,
    /// snapshotted by `restoreTranscripts`) that fails its resumed turn is dropped, so the next
    /// message cold-starts with the transcript recap instead of failing forever against a dead
    /// provider thread. Compared by VALUE: a session minted this process never matches the disk
    /// snapshot, so a transient failure can never cost live conversation context.
    /// Returns whether a session was actually dropped — the probation-retry signal: a delivery
    /// that failed AND healed a stale session deserves one cold-start redelivery (the retry needs
    /// no counter — with the session gone, a second failure can't drop anything, so it terminates).
    @discardableResult
    func dropSessionIfStale(_ scope: SZChatScope) -> Bool {
        guard let restored = restoredSessions.removeValue(forKey: scope.key),
              agentSessions[scope.key] == restored else { return false }
        agentSessions[scope.key] = nil
        persistAgentSessions()
        return true
    }

    /// Copy the picked/dropped/pasted files into `<workingDirectory>/attachments/` and return the staged
    /// records. Name clashes get an 8-char uuid prefix. Files that can't be copied are skipped (best effort).
    static func stageAttachments(_ sources: [URL], into workingDirectory: URL) -> [SZChatAttachment] {
        guard !sources.isEmpty else { return [] }
        let fm = FileManager.default
        let dir = workingDirectory.appending(path: "attachments")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var staged: [SZChatAttachment] = []
        for source in sources {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let name = source.lastPathComponent
            var dest = dir.appending(path: name)
            if fm.fileExists(atPath: dest.path) {
                dest = dir.appending(path: "\(UUID().uuidString.prefix(8))-\(name)")
            }
            do {
                try fm.copyItem(at: source, to: dest)
            } catch { continue }
            let byteCount = (try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int ?? 0
            let isImage = UTType(filenameExtension: dest.pathExtension)?.conforms(to: .image) ?? false
            staged.append(SZChatAttachment(filename: name, url: dest, byteCount: byteCount, isImage: isImage))
        }
        return staged
    }

    /// The text appended to a real agent's prompt so it Reads the staged files by absolute path.
    static func attachmentManifest(_ staged: [SZChatAttachment]) -> String {
        "\n\nAttached files (read these):\n"
            + staged.map { "- \($0.url.path)" }.joined(separator: "\n")
    }

    /// Make the durable canonical copy of each staged attachment inside the .subz bundle
    /// (`attachments/<attachment-uuid>/<filename>` — the uuid dir preserves the exact filename) and
    /// point the record at it: `bundlePath` for the portable sidecar, `url` for the UI (thumbnails
    /// survive relaunch and travel with the project). Best effort like staging: a failed copy leaves
    /// that attachment staging-only (nil bundlePath) rather than failing the send.
    private func persistAttachmentCopies(_ staged: [SZChatAttachment]) -> [SZChatAttachment] {
        guard let projectURL = loadedProjectURL else { return staged }
        let fm = FileManager.default
        return staged.map { attachment in
            var a = attachment
            let relative = "attachments/\(a.id.uuidString)/\(a.filename)"
            let dest = projectURL.appending(path: relative)
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: a.url, to: dest)
                a.bundlePath = relative
                a.url = dest
            } catch { /* staging-only fallback */ }
            return a
        }
    }
}
