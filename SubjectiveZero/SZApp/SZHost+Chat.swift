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

    /// THE feed the one chat panel shows: every Director message, plus each node agent's own
    /// conversation, in the order they were said. A node's fleet turns are left out — they carry
    /// the run they belong to and are read in that task's drill-in, not in the conversation.
    ///
    /// Derived per body evaluation from the per-scope transcripts (a few hundred messages at
    /// most); the transcripts stay the storage, so sessions and recaps are untouched.
    var chatFeed: [SZChatFeedItem] {
        var items = store.messages(for: .director).map { SZChatFeedItem(scope: .director, message: $0) }
        for node in store.project?.graph.nodes ?? [] {
            let scope = SZChatScope.node(node.id)
            items += store.messages(for: scope)
                .filter { $0.graphRunID == nil }   // a fleet turn belongs to its task, not to us
                .map { SZChatFeedItem(scope: scope, message: $0) }
        }
        return items.sorted { $0.message.timestamp < $1.message.timestamp }
    }

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

    /// The scheduled work the chat strip lists: what was asked, and — when something holds the
    /// nodes it needs — what it is behind, so a queued task never reads as a stalled one.
    var scheduledTaskRows: [SZScheduledRow] {
        pendingTasks.map { task in
            let blocker = task.workSet
                .compactMap { ledger.holder(of: .node($0))?.label }
                .first
            return SZScheduledRow(id: task.id, title: task.title, waitingOn: blocker)
        }
    }

    /// The node card's chat button: put a reference to that node in the message you are writing.
    /// With one conversation there is no tab to open — talking about a node means MENTIONING it,
    /// which the Director's triage reads as the target. The panel inserts it at the caret and
    /// focuses the field.
    func mentionNodeInComposer(_ id: SZNodeID) {
        guard let node = store.project?.graph.node(id: id) else { return }
        pendingComposerMention = SZComposerMentionInjection(candidate: SZMentionCandidate(
            target: .node(id), title: node.title.isEmpty ? "Untitled" : node.title,
            sfSymbol: node.sfSymbol, subtitle: "Coding Agent"))
        showChat()
    }

    /// The panel inserted a mention — id-checked so a stale consume can't drop a newer one.
    func consumeComposerMention(_ id: UUID) {
        if pendingComposerMention?.id == id { pendingComposerMention = nil }
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
        showChat()
    }

    /// The panel applied an injection — id-checked so a stale consume can't drop a newer draft.
    func consumeComposerDraft(_ id: UUID) {
        if pendingComposerDraft?.id == id { pendingComposerDraft = nil }
    }

    /// Show the one chat panel. There is a single conversation, so there is nothing to select —
    /// and no scope argument, because accepting one and dropping it made every call site read as
    /// addressing something it could not address.
    func showChat() {
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

    /// HUD message icon — show the chat, or hide it if it is already showing.
    func toggleDirectorChat() {
        if chatVisible { closePanel(.chat) } else { showPanel(.chat) }
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


    /// Who initiated a chat send — the panel composer (`.user`) or an MCP `ui_send_chat` call
    /// (`.agent`, e.g. the Director Agent). The one place the two senders legitimately diverge is a
    /// node-scoped message DURING a run: from an agent it's the Director steering that node's Coding
    /// Agent (recorded for the reconcile loop); from the user it gets the busy guard (TODO: mid-run
    /// user messaging).
    enum SZChatSendOrigin { case user, agent }

    /// How `sendChat` routed a message: refused synchronously by a transient guard reply
    /// (`.rejected` — no envelope, nothing will deliver), enqueued for delivery (`.queued` —
    /// possibly starting immediately; the id is pollable via `ui_message_status`), or recorded as
    /// a `.steer` for the reconcile loop (`.recordedForReconcile`).
    enum SZChatSendRouting: Equatable {
        case rejected
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
        guard !trimmed.isEmpty || !attachments.isEmpty else { return .rejected }

        // V1 routing (SZChatRouting — the policy seam): a USER message that leads with a mention
        // goes to that entity's agent; `scope` (the composing tab) is only the fallback. Agent-
        // origin sends keep their explicit scope — the Director addressing a node must not be
        // re-routed by mentions inside its own words.
        var scope = scope
        if origin == .user {
            let resolved = SZChatRouting.resolveRecipient(message: trimmed)
            if case .node(let id) = resolved, store.project?.graph.node(id: id) == nil {
                // The leading mention names a node that no longer exists — refuse in the composing
                // tab (transient, like the other pre-flight rejections) rather than streaming into
                // a hidden transcript.
                store.appendChatMessage(
                    SZChatMessage(role: .assistant,
                                  text: "(that mention's node no longer exists — message not sent)",
                                  transient: true), to: scope)
                return .rejected
            }
            scope = resolved
        }

        // Agent-origin messages DURING a run are fleet-internal steering — recorded, never a nested
        // turn inside a synchronous MCP handler (deadlock-safe: its connection thread is blocked on a
        // semaphore until we return). Neither path steals the tab. A USER's mid-run message falls
        // through instead.
        if origin == .agent, isRunning {
            // Director → a node the run owns: folded into that node's reconcile retry.
            if let nodeID = scope.nodeID, isRunClaim(ledger.holder(of: .node(nodeID))) {
                return .recordedForReconcile(recordDirectorMessage(node: nodeID, message: trimmed))
            }
            // Coding agent → the Director: rendered into the next reconcile turn's prompt
            // (previously appended to the tab and read by no LLM — a silent black hole).
            if scope == .director {
                return .recordedForReconcile(recordDirectorInboxMessage(trimmed))
            }
            // A node the run does NOT own falls through to the normal enqueue path below.
        }

        // A user send reveals the panel. An agent's does not — background traffic lands in the
        // one feed on its own, and there is no tab left for it to steal.
        if origin == .user {
            showChat()
            admissionSuspended = false   // the user is asking again; the queue may move
        }

        // A pre-flight rejection: shown in the tab but TRANSIENT — never flushed, never recapped.
        // It isn't conversation; restoring "(busy…)" as assistant history (or replaying it to a
        // fresh session) would misrepresent what was said. Only checks queueing can't fix reject
        // here — a busy scope/run is exactly what the queue is for.
        @discardableResult
        func reject(_ note: String) -> SZChatSendRouting {
            store.appendChatMessage(SZChatMessage(role: .assistant, text: note, transient: true), to: scope)
            if origin == .user {   // a refused first ask is a funnel fact, not silence
                trackPromptSentTelemetry(scope: Self.telemetryScopeLabel(scope), providerID: activeProviderID, rejected: true)
            }
            return .rejected
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
        // The envelope's id IS the bubble's id: the panel's queued chip looks messages up by the
        // bubble id, and one shared id keeps envelope, bubble, and `ui_message_status` congruent.
        let envelope = SZMessageEnvelope(
            id: userMessage.id,
            recipient: scope.key, sender: origin == .user ? "user" : nil, intent: .chat,
            message: userMessage, transcriptMessageID: userMessage.id)
        mailbox.enqueue(envelope)
        flushTranscript(scope)   // the user's words are durable even if delivery waits or dies
        pumpMailboxes()
        if origin == .user {
            trackPromptSentTelemetry(scope: Self.telemetryScopeLabel(scope), providerID: providerID, rejected: false)
        }
        return .queued(envelope.id)
    }

    /// Stop one scope's in-flight chat turn (the transcript's per-turn stop control): cancel its
    /// task — SZProcess SIGKILLs the CLI on cancellation — leaving the session (a killed resume
    /// is still resumable) and the transcript (partial text + "(stopped)") in place. A no-op for
    /// a scope with nothing in flight. Run-driven coding turns are `cancelRun`'s job, not this.
    func cancelChatTurn(_ scope: SZChatScope) {
        chatTurnTasks[scope.key]?.cancel()
    }

    /// The one composer's per-turn Stop. With a single feed there is no shown scope to key on, and
    /// keying it to the Director left a streaming node turn — visible in that same feed — with no
    /// Stop anywhere. Interactive turns are few and the user means "stop what is being written".
    func cancelStreamingChatTurns() {
        for task in chatTurnTasks.values { task.cancel() }
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
