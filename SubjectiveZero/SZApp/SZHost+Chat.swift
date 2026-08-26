// SPDX-License-Identifier: AGPL-3.0-only
// Chat-panel state + messaging: `chatFeed` (the one conversation, derived from the per-scope
// transcripts), the composer's staged draft/mention, and `sendChat` — the entry point shared by the
// panel and `ui_send_chat`, which cold-starts or resumes an agent session and streams the reply
// through `deliver`.
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
                // A fleet turn belongs to its task, not to us — and anything from before this
                // project's `feedEpoch` predates that stamp, so it is fleet work until proven
                // otherwise rather than conversation until proven otherwise.
                .filter { $0.graphRunID == nil && $0.timestamp >= feedEpoch }
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

    /// Land a host-drafted message in the composer and show the chat. The panel applies it and
    /// emphasizes send until acted on. Canned suggestion rows do not come through here — those are
    /// whole sentences and send themselves (`pickContextSuggestion`); this is for drafts you finish.
    func injectComposerDraft(_ draft: SZComposerDraft, scope: SZChatScope,
                             replacesNonEmpty: Bool = true) {
        // Every message already addresses the Director, so a leading @project mention is
        // redundant here (and reads oddly). Routing is unaffected: the door reads mentions as hints.
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
    /// Nodes still waiting to be kicked off — the HUD Build badge. Nodes a run ALREADY holds are
    /// not pending: they are being built, and counting them made Build offer work it could not take.
    var pendingNodeCount: Int {
        let claimed = runWorkSet
        return store.project?.graph.nodes
            .filter { $0.needsImplementation && !claimed.contains($0.id) }.count ?? 0
    }

    /// Work waiting to be kicked off. NOT gated on "nothing is running" any more: a run is scoped
    /// to its own nodes, so a draft added while another build is going is perfectly buildable —
    /// and gating it here was half of why that draft had no control at all.
    ///
    /// Wiring counts, though it is not a node to build: reading only `pendingNodeCount` hid the Build
    /// control on the one graph that needs it. The badge still counts nodes; this decides whether the
    /// control is there at all, and matches what `startRun` would admit.
    var pendingWorkAvailable: Bool { pendingNodeCount > 0 || wiringWorkAvailable }

    /// Whether any arrow could be realized right now — the admission rule, asked without starting.
    var wiringWorkAvailable: Bool {
        !Self.unwiredCandidates(in: store.project?.graph, excluding: runWorkSet, named: []).isEmpty
    }

    /// HUD message icon — show the chat, or hide it if it is already showing.
    func toggleDirectorChat() {
        if chatVisible { closePanel(.chat) } else { showPanel(.chat) }
    }

    /// Clear THE CONVERSATION (the composer's ⋯ menu): every scope the one feed is made of, not
    /// just the Director's — resetting one left the visible half nothing could reach. Each is a
    /// FULL reset via `resetScopeChat`: transcript, attachment copies, resumable session, queued
    /// messages, so the next turn cold-starts. A scope mid-turn keeps its transcript; resetting it
    /// under a streaming agent would strand the reply.
    func clearChatTranscript(_ scope: SZChatScope) {
        var scopes: [SZChatScope] = [scope]
        if scope == .director {
            scopes += (store.project?.graph.nodes ?? []).map { SZChatScope.node($0.id) }
        }
        for target in scopes where !chatInFlight.contains(target.key) {
            guard !store.messages(for: target).isEmpty else { continue }
            resetScopeChat(target)
        }
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
    /// the `ui_send_chat` MCP tool, so the two paths can't drift. Reveals the chat,
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
        let providerID: String
        switch providerForTurn(scope, heal: false) {
        case .refused(let note):
            flushTranscript(scope)
            return reject(note)
        case .ready(let provider, _, _):
            providerID = provider.id
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

    /// Which CLI takes a scope's next turn: the pinned session's provider while it is ready,
    /// else the active provider on a fresh session (`heal` drops the pin; enqueue only looks).
    /// Nothing is dropped unless the active provider can actually take the turn.
    enum TurnProvider {
        case ready(any SZProvider, session: SZAgentSession?, note: String?)
        case refused(String)
    }
    func providerForTurn(_ scope: SZChatScope, heal: Bool) -> TurnProvider {
        var session = agentSessions[scope.key]
        var note: String?
        if let pinned = session?.providerID, !isProviderReadyForNewWork(pinned) {
            guard isProviderReadyForNewWork(activeProviderID) else {
                surfaceProviderNotReady(pinned)
                return .refused("(\(pinned) is not ready, open Agent Providers)")
            }
            if heal { agentSessions[scope.key] = nil; persistAgentSessions() }
            session = nil
            note = "(\(pinned) is not ready, continuing on \(activeProviderID) with a fresh session)"
        }
        let providerID = session?.providerID ?? activeProviderID
        guard let provider = SZProviderRegistry.shared.provider(id: providerID) else {
            return .refused("(unknown provider \(providerID))")
        }
        if session == nil, !isProviderReadyForNewWork(providerID) {
            surfaceProviderNotReady()
            return .refused("(\(providerID) is not ready, open Agent Providers)")
        }
        return .ready(provider, session: session, note: note)
    }

    /// A resumed turn that failed drops its pin so the redelivery cold-starts on the transcript
    /// recap. Returns whether a pin was dropped; with it gone a second failure cannot drop again.
    @discardableResult
    func dropSessionAfterFailedResume(_ scope: SZChatScope) -> Bool {
        guard agentSessions[scope.key] != nil else { return false }
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
