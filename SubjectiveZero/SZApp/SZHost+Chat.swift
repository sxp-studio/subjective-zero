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

    /// The active node is agent-owned OUTSIDE a run (its Coding Agent is mid-chat-turn, or it's
    /// splitting/merging) → its composer is locked. The run case (which locks EVERY tab) is handled
    /// in the panel via `isRunning`; this covers only the node-specific busy states.
    var activeScopeLocked: Bool {
        guard case .node(let id) = activeChatScope else { return false }
        return nodeAgentState[id]?.isChatting == true || graphOpStatus[id] != nil
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

    /// How `sendChat` routed a message: streamed to the agent (or answered synchronously by a guard
    /// reply in the transcript), or recorded for the reconcile loop to deliver on the node's retry.
    enum SZChatSendRouting { case sent, recordedForReconcile }

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

        // A node-scoped message DURING a run from an agent is the Director messaging that node's
        // Coding Agent. Record it (returns immediately — deadlock-safe: no nested agent turn inside a
        // synchronous MCP handler); the reconcile loop delivers it on the node's next retry. Does NOT
        // steal the tab. A USER's mid-run node message falls through to the busy guard below instead.
        if origin == .agent, isRunning, let nodeID = scope.nodeID {
            recordDirectorMessage(node: nodeID, message: trimmed)
            return .recordedForReconcile
        }

        showChat(scope)   // reveal/focus the tab — 1:1 with clicking it before typing

        // Catch-up (the portable path): a turn with no resumable session but restored history
        // replays that history into the fresh session's first prompt — covers another machine (no
        // session store), an expired session (self-heal drop), and post-crash. Computed BEFORE this
        // turn's messages land in the store so the recap is strictly prior conversation.
        let recap = agentSessions[scope.key] == nil ? transcriptRecap(for: scope) : nil

        // Stage attachments on disk first (the native layer owns the bytes): copy each picked/dropped/
        // pasted file into the agent's working dir so a real CLI agent can Read it by absolute path, and
        // so the copy outlives the source URL. The user turn carries the staged records (chips/thumbnails).
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "sz-agent-cache")
        let workingDirectory = cacheDirectory.appending(path: "agent/\(scope.key)")
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let staged = Self.stageAttachments(attachments, into: workingDirectory)
        // The message carries the DURABLE records (bundle copies that persist + travel); the agent
        // manifest below keeps pointing at the staging copies (its own working dir — unchanged
        // permission surface). `.debug` stays staging-only, ephemeral like its transcript.
        let durable = scope == .debug ? staged : persistAttachmentCopies(staged)
        store.appendChatMessage(SZChatMessage(role: .user, text: trimmed, attachments: durable), to: scope)
        flushTranscript(scope)   // the user's words are durable even if the turn below dies

        // A pre-flight rejection: shown in the tab but TRANSIENT — never flushed, never recapped.
        // It isn't conversation; restoring "(busy…)" as assistant history (or replaying it to a
        // fresh session) would misrepresent what was said.
        @discardableResult
        func reject(_ note: String) -> SZChatSendRouting {
            store.appendChatMessage(SZChatMessage(role: .assistant, text: note, transient: true), to: scope)
            return .sent
        }

        // One turn per scope at a time: a second send while this scope streams would overwrite its
        // in-flight marker (inFlightAssistantIDs is one id per scope), letting a flush persist the
        // half-streamed first reply — the invariant the marker exists to protect.
        guard !chatInFlight.contains(scope.key) else {
            return reject("(still replying — wait for the current answer to finish)")
        }
        guard !isRunning else { return reject("(busy — finish or stop the agent run first)") }
        guard let mcpPort = agentMCPServer?.port, let projectURL = loadedProjectURL else {   // agents dial the debug-free bus
            return reject("(host not ready)")
        }
        let existing = agentSessions[scope.key]
        let providerID = existing?.providerID ?? activeProviderID
        guard let provider = SZProviderRegistry.shared.provider(id: providerID) else {
            return reject("(unknown provider \(providerID))")
        }
        // Pre-flight NEW sessions only: a resume must continue on the CLI that owns it, and its
        // failure already narrates in this tab. A fresh turn on a missing/logged-out CLI refuses
        // with the setup sheet + remedy instead of a dead spawn (roadmap Task 2).
        if existing == nil, !isProviderReadyForNewWork(providerID) {
            surfaceProviderNotReady()
            return reject("(\(providerID) is not ready — open Agent Providers)")
        }

        let assistantID = store.appendChatMessage(SZChatMessage(role: .assistant, text: ""), to: scope)

        // A synchronous fallback on a REAL turn's empty/failed outcome — genuine history, persisted.
        @discardableResult
        func reply(_ note: String) -> SZChatSendRouting {
            store.appendChatText(note, to: assistantID, in: scope)
            flushTranscript(scope)
            return .sent
        }

        // CLI egress: the transcript stores the CANONICAL mention markup; the agent receives the
        // expanded form — inline @display plus a manifest resolving each mentioned entity against
        // the live graph (uuid + current title, actionable via the MCP tools).
        let graphNodes = (store.project?.graph.nodes ?? []).map { (id: $0.id, title: $0.title) }
        let expanded = SZMentionExpansion.agentText(trimmed, nodes: graphNodes)

        // A node with no session yet (e.g. a hand-authored node, no prior run) cold-starts a fresh
        // Coding Agent seeded with the node's current contract + Node.swift; later turns resume that
        // session. An already-sessioned node chat sends the raw message (its context is the session).
        var chatPrompt = expanded
        if case .node(let nodeID) = scope, existing == nil {
            let nodeDir = projectURL.appending(path: "nodes/\(nodeID.uuidString)")
            let source = (try? String(contentsOf: nodeDir.appending(path: "Node.swift"), encoding: .utf8))
                ?? "(this node has no Node.swift yet)"
            let contract = (try? String(contentsOf: nodeDir.appending(path: "node-contract.json"), encoding: .utf8))
                ?? "(no contract yet)"
            chatPrompt = SZChatPrompts.nodeColdStart(
                node: nodeID.uuidString, userMessage: expanded, currentContract: contract, currentSource: source)
        } else if scope == .director {
            // A fresh Director Agent chat gets its real framing (persona + live graph + the shared ui_*
            // toolbelt + the ui_run rules). A RESUMED one still gets the live graph, just without re-sending
            // the persona: its session's memory of the graph is a snapshot that every run invalidates, and it
            // will otherwise answer questions about node state from that stale snapshot without re-reading.
            let graph = store.project?.graph ?? SZGraph(nodes: [])
            chatPrompt = existing == nil
                ? SZDirectorPrompt.renderChat(graph: graph, message: expanded)
                : SZDirectorPrompt.renderResumedChat(graph: graph, message: expanded)
        } else if scope == .debug, existing == nil {
            // Frame the debug chat agent on its first turn so it answers as a plain conversational
            // assistant (it has no graph context and no MCP tools — just the Read tool for attachments).
            chatPrompt = """
            You are a helpful assistant in a debug chat panel of the SubjectiveZero macOS app. Reply \
            conversationally to the user. If files are attached, you may Read them to answer.

            User: \(expanded)
            """
        }
        if let recap { chatPrompt = recap + "\n\n" + chatPrompt }
        // Point the agent at the staged files (it Reads them by absolute path).
        if !staged.isEmpty { chatPrompt += Self.attachmentManifest(staged) }

        status = "chatting (\(scope.key.prefix(8))…)"
        // Mark a node's card Coding + locked for the duration of the turn (a node chat recompiles it).
        let workingNodeID: SZNodeID? = { if case .node(let id) = scope { return id } else { return nil } }()
        if let workingNodeID { setNodeChatting(workingNodeID, true) }

        chatTurnTasks[scope.key] = Task { @MainActor in
            defer {
                chatTurnTasks[scope.key] = nil
                if let workingNodeID { setNodeChatting(workingNodeID, false) }   // in-flight + duration: `deliver`
            }
            // Resolved for the session's own provider (a resume continues on the CLI that owns it).
            // A resumed turn picks up the current effort/fast selection — argv re-sends both on every
            // resume, and they retune the thread rather than reinterpret it. The model can't drift
            // here: picking a new one reset this provider's sessions (`setActiveModel`), so a resume
            // always carries the model that opened the thread.
            let generation = resolvedGenerationSettings(for: providerID)
            let request = SZAgentRunRequest(
                prompt: chatPrompt,
                workingDirectory: workingDirectory,
                packageDirectory: projectURL,
                cacheDirectory: cacheDirectory,
                mcpServerPort: scope == .debug ? nil : mcpPort,   // the debug chat agent is tool-free (no graph mutation)
                resumeSessionID: existing?.sessionID,
                model: generation.model,
                reasoningEffort: generation.reasoningEffort,
                fastMode: generation.fastMode ?? false,
                timeout: 300)
            do {
                // The shared agent-turn substrate — streams into this scope's transcript, reusing the
                // assistant message already opened above for the guard replies, and persists the session.
                let result = try await deliver(
                    scope: scope, request: request, provider: provider, existingAssistantID: assistantID).result
                // A stopped turn (the transcript's stop control): SZProcess SIGKILLed the CLI, so
                // deliver returns a failed exit — but it's a user choice, not a dead session (a
                // killed resume is still resumable), so no self-heal drop and no failure reply.
                if Task.isCancelled {
                    let empty = store.messages(for: scope).first(where: { $0.id == assistantID })?.text.isEmpty == true
                    reply(empty ? "(stopped)" : "\n(stopped)")
                    status = "chat turn stopped"
                    pendingDirectorRun = nil   // a stopped turn's queued run dies with it — user's choice
                    return
                }
                if result.outcome.failed { dropSessionIfStale(scope) }
                // Generic status FIRST — when the failure is provider-shaped,
                // providerFailureDetail overrides it with the actionable "<id> not ready" line
                // (setting it after would clobber that surface).
                status = result.outcome.failed ? "chat turn failed" : "chat reply ready"
                let empty = store.messages(for: scope).first(where: { $0.id == assistantID })?.text.isEmpty == true
                if let detail = await providerFailureDetail(result: result, provider: provider) {
                    // A mid-turn provider death. The resume path has no pre-flight (deliberate),
                    // so this line is its only surface — appended even when partial text already
                    // streamed, which would otherwise fail silently.
                    reply((empty ? "" : "\n") + "⚠️ Provider error: \(detail)")
                } else if empty {
                    reply(result.outcome.failed ? "(agent run failed)" : "(no text response)")
                }
            } catch {
                dropSessionIfStale(scope)
                reply("(chat failed: \(error))")
                status = "chat failed"
            }
            // A ui_run recorded during THIS Director turn starts now — the chat turn was the
            // decompose turn (its ui_* shaping is done), and starting mid-turn would have raced
            // the same transcript. Applies even if the turn's exit was a late failure: the tool
            // call happened, the graph is shaped.
            if scope == .director, let instruction = pendingDirectorRun {
                pendingDirectorRun = nil
                startRun(instruction: instruction, directorAlreadyBriefed: true)
            }
        }
        return .sent
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
    private func dropSessionIfStale(_ scope: SZChatScope) {
        guard let restored = restoredSessions.removeValue(forKey: scope.key),
              agentSessions[scope.key] == restored else { return }
        agentSessions[scope.key] = nil
        persistAgentSessions()
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
