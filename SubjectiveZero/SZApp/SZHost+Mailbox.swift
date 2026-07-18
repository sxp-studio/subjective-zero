// SPDX-License-Identifier: AGPL-3.0-only
// The delivery pump — the composition point of SZMessageQueue + SZResourceLedger + `deliver`.
// Sends that can't run immediately are `.chat` envelopes in the mailbox; the pump delivers each
// recipient's FIFO head the moment its resources free (event-driven off `onAvailabilityChanged`,
// plus an explicit pump after every enqueue and after restore — never a polling loop).
//
// The pump's named invariants (docs/AGENT_ORCHESTRATION.md "Cross-agent messaging"):
// 1. `pumpMailboxes()` is FULLY SYNCHRONOUS — no suspension between the queued-head scan,
//    `tryAcquire`, and `markDelivering`, so two pump entries can never double-claim one envelope.
// 2. Each delivery runs as its own Task, so a synchronous failure chain (markFailed → release →
//    onAvailabilityChanged → pump) re-enters the pump only AFTER this scan returned.
// 3. Delivery precondition = the ledger claim AND `inFlightAssistantIDs[key] == nil` — the physical
//    stream marker survives as a gate: after Stop, `cancelRun`'s eager release frees transcripts a
//    killed agent's CLI may still be streaming into for seconds; without the marker check the pump
//    would open a second turn into that transcript and the zombie's defer would clear the in-flight
//    marker mid-stream, breaking the half-streamed-flush protection.
// 4. `tryAcquire` respects earlier waiters' reservations (ledger rule), so the pump cannot starve a
//    parked multi-resource acquire.
// 5. A small delivery-concurrency cap keeps a run-end release from spawning one CLI process per
//    queued scope at once. Burst-after-Stop (queued messages delivering once the run stops) is
//    accepted V1 behavior — capped, not suppressed.
// 6. The pump is suspended for the duration of `switchProject` (which also re-checks the busy guard
//    after its one await).
import Foundation
import SZAI
import SZCore

extension SZHost {
    static let deliveryCap = 3

    /// Deliver every queued `.chat` head whose recipient is free — synchronous scan, spawn per
    /// delivery. Steers are never pumped (their consumer drains them).
    func pumpMailboxes() {
        guard !pumpSuspended else { return }
        for key in mailbox.recipientsWithPending {
            guard activeDeliveries < Self.deliveryCap else { break }
            guard let scope = SZChatScope(key: key),
                  let envelope = mailbox.pending(for: key).first(where: { $0.intent == .chat })
            else { continue }
            guard inFlightAssistantIDs[key] == nil else { continue }   // zombie still streaming
            let claim = SZClaimToken(label: "delivery to \(turnLabel(for: scope))")
            guard ledger.tryAcquire(Self.turnResources(for: scope), as: claim) else { continue }
            mailbox.markDelivering(envelope.id)
            activeDeliveries += 1
            let envelopeID = envelope.id
            chatTurnTasks[scope.key] = Task { @MainActor in
                await performChatTurn(envelopeID, scope: scope, claim: claim)
            }
        }
    }

    /// Deliver one envelope as a real agent turn on its scope — the body `sendChat` used to run
    /// inline, now executed when the queue says it's this message's moment. Prompt, recap, and
    /// mention expansion are built HERE, at delivery time, against the live graph. Never touches
    /// the active tab (delivery must not steal focus). Ends with `markProcessed` → release →
    /// `pendingDirectorRun` — strictly in that order, so a Director turn's queued run acquires the
    /// director transcript AFTER this delivery's claim is gone instead of being silently refused.
    func performChatTurn(_ envelopeID: UUID, scope: SZChatScope, claim: SZClaimToken) async {
        var released = false
        func releaseClaim() {
            guard !released else { return }
            released = true
            activeDeliveries -= 1
            ledger.releaseAll(of: claim)   // fires onAvailabilityChanged → the next pump
        }
        defer {
            chatTurnTasks[scope.key] = nil
            releaseClaim()
        }

        guard let envelope = mailbox.envelope(for: envelopeID) else { return }
        let text = envelope.message.text

        // A transient note under the already-shown bubble — the delivery-time counterpart of
        // sendChat's pre-flight rejects (the enqueue-time checks passed; the world moved since).
        func fail(_ note: String) {
            store.appendChatMessage(SZChatMessage(role: .assistant, text: note, transient: true), to: scope)
            mailbox.markFailed(envelopeID, reason: note)
        }

        guard store.project != nil,
              scope.nodeID == nil || store.project?.graph.node(id: scope.nodeID!) != nil else {
            mailbox.markFailed(envelopeID, reason: "the recipient no longer exists")
            return
        }
        guard let mcpPort = agentMCPServer?.port, let projectURL = loadedProjectURL else {
            return fail("(host not ready — message not delivered)")
        }
        let existing = agentSessions[scope.key]
        let providerID = existing?.providerID ?? activeProviderID
        guard let provider = SZProviderRegistry.shared.provider(id: providerID) else {
            return fail("(unknown provider \(providerID) — message not delivered)")
        }
        if existing == nil, !isProviderReadyForNewWork(providerID) {
            surfaceProviderNotReady()
            return fail("(\(providerID) is not ready — open Agent Providers)")
        }

        // Catch-up recap for a session-less delivery — computed now, excluding this envelope's own
        // bubble and every still-queued bubble behind it (they are NOT prior conversation).
        var recapExclusions = Set(mailbox.pending(for: scope.key).compactMap(\.transcriptMessageID))
        if let own = envelope.transcriptMessageID { recapExclusions.insert(own) }
        let recap = existing == nil ? transcriptRecap(for: scope, excluding: recapExclusions) : nil

        let cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "sz-agent-cache")
        let workingDirectory = cacheDirectory.appending(path: "agent/\(scope.key)")
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let chatPrompt = buildChatPrompt(scope: scope, message: text, existing: existing,
                                         recap: recap, projectURL: projectURL,
                                         attachments: envelope.message.attachments)

        status = "chatting (\(scope.key.prefix(8))…)"
        let workingNodeID = scope.nodeID
        if let workingNodeID { setNodeChatting(workingNodeID, true) }
        defer { if let workingNodeID { setNodeChatting(workingNodeID, false) } }

        let assistantID = store.appendChatMessage(SZChatMessage(role: .assistant, text: ""), to: scope)
        @discardableResult
        func reply(_ note: String) -> Void {
            store.appendChatText(note, to: assistantID, in: scope)
            flushTranscript(scope)
        }

        let generation = resolvedGenerationSettings(for: providerID)
        let request = SZAgentRunRequest(
            prompt: chatPrompt,
            workingDirectory: workingDirectory,
            packageDirectory: projectURL,
            cacheDirectory: cacheDirectory,
            mcpServerPort: scope == .debug ? nil : mcpPort,   // the debug chat agent is tool-free
            resumeSessionID: existing?.sessionID,
            model: generation.model,
            reasoningEffort: generation.reasoningEffort,
            fastMode: generation.fastMode ?? false,
            timeout: 300)
        do {
            let result = try await deliver(scope: scope, request: request, provider: provider,
                                           existingAssistantID: assistantID, claim: claim).result
            if Task.isCancelled {
                // The per-turn Stop: a user choice, not a failure — the killed resume is still
                // resumable, and the message WAS delivered (its turn ran).
                let empty = store.messages(for: scope).first(where: { $0.id == assistantID })?.text.isEmpty == true
                reply(empty ? "(stopped)" : "\n(stopped)")
                status = "chat turn stopped"
                pendingDirectorRun = nil   // a stopped turn's queued run dies with it
                mailbox.markProcessed(envelopeID)
                return
            }
            if result.outcome.failed { dropSessionIfStale(scope) }
            status = result.outcome.failed ? "chat turn failed" : "chat reply ready"
            let empty = store.messages(for: scope).first(where: { $0.id == assistantID })?.text.isEmpty == true
            if let detail = await providerFailureDetail(result: result, provider: provider) {
                reply((empty ? "" : "\n") + "⚠️ Provider error: \(detail)")
            } else if empty {
                reply(result.outcome.failed ? "(agent run failed)" : "(no text response)")
            }
            if result.outcome.failed {
                mailbox.markFailed(envelopeID, reason: result.outcome.message ?? "the turn failed")
            } else {
                mailbox.markProcessed(envelopeID)
            }
        } catch {
            dropSessionIfStale(scope)
            reply("(chat failed: \(error))")
            status = "chat failed"
            mailbox.markFailed(envelopeID, reason: "\(error)")
        }
        // A ui_run recorded during THIS Director turn starts now — AFTER the ack and AFTER this
        // delivery releases the director transcript, or startRun's atomic acquire would hit our own
        // claim and silently drop the queued run.
        if scope == .director, let instruction = pendingDirectorRun {
            releaseClaim()
            pendingDirectorRun = nil
            startRun(instruction: instruction, directorAlreadyBriefed: true)
        }
    }

    /// The per-scope prompt framing — cold-start seeds, Director framing, debug framing, recap
    /// prepend, attachment manifest. Factored from `sendChat` verbatim; runs at DELIVERY time so
    /// mention expansion and graph context reflect the world when the agent actually reads it.
    private func buildChatPrompt(scope: SZChatScope, message: String, existing: SZAgentSession?,
                                 recap: String?, projectURL: URL,
                                 attachments: [SZChatAttachment]) -> String {
        let graphNodes = (store.project?.graph.nodes ?? []).map { (id: $0.id, title: $0.title) }
        let expanded = SZMentionExpansion.agentText(message, nodes: graphNodes)

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
            let graph = store.project?.graph ?? SZGraph(nodes: [])
            chatPrompt = existing == nil
                ? SZDirectorPrompt.renderChat(graph: graph, message: expanded)
                : SZDirectorPrompt.renderResumedChat(graph: graph, message: expanded)
        } else if scope == .debug, existing == nil {
            chatPrompt = """
            You are a helpful assistant in a debug chat panel of the SubjectiveZero macOS app. Reply \
            conversationally to the user. If files are attached, you may Read them to answer.

            User: \(expanded)
            """
        }
        if let recap { chatPrompt = recap + "\n\n" + chatPrompt }
        // Point the agent at the DURABLE attachment copies: staging copies don't survive a restart,
        // and a queued message may deliver after one. (The recap already hands agents bundle-copy
        // absolute paths — same precedent.) Staging-only attachments (nil bundlePath, e.g. .debug)
        // still point at their staging url, which is all they ever had.
        if !attachments.isEmpty { chatPrompt += Self.attachmentManifest(attachments) }
        return chatPrompt
    }
}
