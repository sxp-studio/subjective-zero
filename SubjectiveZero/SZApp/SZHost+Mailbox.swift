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
//    queued scope at once. Burst-after-Stop is accepted V1 behavior — capped, not suppressed.
// 6. The pump is suspended for the duration of `switchProject`.
// 7. A MINTED RUN is admitted at the head of every pump pass — ahead of any queued prose —
//    so the run always beats the next Director message to the freed transcript.
import Foundation
import SZAI
import SZCore

extension SZHost {
    static let deliveryCap = 3

    /// Deliver every queued `.chat` head whose recipient is free — synchronous scan, spawn per
    /// delivery. Steers are never pumped (their consumer drains them).
    func pumpMailboxes() {
        guard !pumpSuspended else { return }
        admitPendingRunIfPossible()
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

    /// Deliver one envelope as a real agent turn on its scope, THROUGH its agent's graph.
    /// Prompt, recap, and mention expansion are built HERE, at delivery time, against the
    /// live graph. Never touches the active tab. Ends with `markProcessed` → release →
    /// the pump's next pass, whose head admits any minted run before queued prose.
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
        // The wait ends HERE — prompt building below (recap, mention expansion) is delivery work,
        // not queueing, and must not inflate the queue.wait row.
        let waitEnded = Date()
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

        // Redelivery after a restart whose transcript lost the bubble (queue survived, sidecar
        // older): re-append it so the conversation shows what is being delivered.
        if let bubbleID = envelope.transcriptMessageID,
           !store.messages(for: scope).contains(where: { $0.id == bubbleID }) {
            store.appendChatMessage(envelope.message, to: scope)
            flushTranscript(scope)
        }

        // Catch-up recap for a session-less delivery — computed now, excluding this envelope's own
        // bubble and every still-queued bubble behind it (they are NOT prior conversation).
        var recapExclusions = Set(mailbox.pending(for: scope.key).compactMap(\.transcriptMessageID))
        if let own = envelope.transcriptMessageID { recapExclusions.insert(own) }
        let recap = existing == nil ? transcriptRecap(for: scope, excluding: recapExclusions) : nil

        let cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "sz-agent-cache")
        let workingDirectory = cacheDirectory.appending(path: "agent/\(scope.key)")
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

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

        // Queue wait, keyed to THIS turn's own message id.
        if SZTrace.isEnabled {
            SZTrace.record(SZTurnEvent(stage: SZTurnStage.queueWait, start: envelope.enqueuedAt,
                                       duration: waitEnded.timeIntervalSince(envelope.enqueuedAt)),
                           turnID: assistantID)
        }

        let generation = resolvedGenerationSettings(for: providerID)
        // The turn core, driven by the graph's own ORDER: `tools` and `session` are what
        // the turn node declares, so tool-free-ness is the debug pack's `"tools": []`
        // rather than a scope branch here.
        func runDeliveredTurn(_ order: SZTurnOrder, prompt: String) async throws -> SZAgentRunResult {
            let request = SZAgentRunRequest(
                prompt: prompt,
                workingDirectory: workingDirectory,
                packageDirectory: projectURL,
                cacheDirectory: cacheDirectory,
                mcpServerPort: order.tools?.isEmpty == true ? nil : mcpPort,
                allowedMCPTools: order.tools ?? SZHostBridge.agentCallableToolNames,
                resumeSessionID: order.session == .resume ? existing?.sessionID : nil,
                model: generation.model,
                reasoningEffort: generation.reasoningEffort,
                fastMode: generation.fastMode ?? false,
                timeout: 300)
            return try await deliver(scope: scope, request: request, provider: provider,
                                     existingAssistantID: assistantID, claim: claim).result
        }
        do {
            // EVERY delivery flows through its agent's graph: the door decides what the
            // message is, the pack decides which brief a turn gets, and the turn streams
            // through `runDeliveredTurn` unchanged (recap + attachments wrap the brief
            // HERE — delivery context that never enters the pack render).
            let expanded = SZMentionExpansion.agentText(
                text, nodes: (store.project?.graph.nodes ?? []).map { (id: $0.id, title: $0.title) })
            let messageAttachments = envelope.message.attachments
            // A node chat's cold seed needs the node's current files. Read only when there
            // is no session to resume: the resumed brief mentions neither token, and the
            // renderer computes only what a brief actually mentions.
            var extras = SZBriefExtras()
            if case .node(let nodeID) = scope, existing == nil {
                let nodeDir = projectURL.appending(path: "nodes/\(nodeID.uuidString)")
                extras.nodeContract =
                    (try? String(contentsOf: nodeDir.appending(path: "node-contract.json"), encoding: .utf8))
                    ?? "(no contract yet)"
                extras.nodeSource =
                    (try? String(contentsOf: nodeDir.appending(path: "Node.swift"), encoding: .utf8))
                    ?? "(this node has no Node.swift yet)"
            }
            let (result, ack) = try await runProseDelivery(
                scope: scope, message: expanded, existing: existing, providerID: providerID,
                extras: extras) { order in
                    var prompt = order.brief
                    if let recap { prompt = recap + "\n\n" + prompt }
                    if !messageAttachments.isEmpty { prompt += Self.attachmentManifest(messageAttachments) }
                    return try await runDeliveredTurn(order, prompt: prompt)
                }
            // A turn-less ruling's one line — the door's `requestBuild` ack, in the bubble
            // the delivery already opened.
            if let ack { reply(ack) }
            if Task.isCancelled {
                // The per-turn Stop: a user choice, not a failure — the killed resume is still
                // resumable, and the message WAS delivered (its turn ran).
                let empty = store.messages(for: scope).first(where: { $0.id == assistantID })?.text.isEmpty == true
                reply(empty ? "(stopped)" : "\n(stopped)")
                status = "chat turn stopped"
                // Only the DIRECTOR turn's Stop discards its own minted run.
                if scope == .director { pendingRun = nil }
                mailbox.markProcessed(envelopeID)
                return
            }
            if result.outcome.failed, dropSessionIfStale(scope) {
                // The probation self-heal just fired: ONE cold-start redelivery — bounded
                // structurally: with the session gone, a second failure lands in markFailed.
                reply("(session expired — retrying with a fresh session)")
                status = "chat turn failed — retrying with a fresh session"
                mailbox.requeue(envelopeID)
                return   // the defer's release re-fires the pump → redelivery
            }
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
            // A deliver that bowed out before its turn-end path ran left the queue-wait row
            // parked under this turn — drop it rather than leak it.
            SZTrace.discard(turnID: assistantID)
            if dropSessionIfStale(scope) {
                reply("(session expired — retrying with a fresh session)")
                status = "chat turn failed — retrying with a fresh session"
                mailbox.requeue(envelopeID)
                return
            }
            reply("(chat failed: \(error))")
            status = "chat failed"
            mailbox.markFailed(envelopeID, reason: "\(error)")
        }
        // A run this turn minted (the door's `requestBuild`, or a mid-turn `ui_run`) fires
        // from the pump: the defer's release triggers `admitPendingRunIfPossible` at the
        // head of the very next pump pass — after our claim is gone, and BEFORE the next
        // queued Director message is considered.
    }

    // MARK: - The prose delivery

    /// Which agent answers a scope's prose. A map over the SEAT vocabulary, not per-agent
    /// branching: replace the folder holding `coding` and node chats follow it. A seatless
    /// scope addresses an agent by id, which is what its key already is.
    nonisolated static func chatAgentID(for scope: SZChatScope,
                                        seats: SZSeatAssignment) -> String? {
        switch scope {
        case .director: seats.director
        case .node: seats.coding
        case .debug: SZChatScope.debugKey
        }
    }

    /// One prose message, delivered THROUGH its agent's graph: the door decides what it is
    /// (its triage may spend a model call), the graph's own turn streams through `turn`
    /// (all delivery machinery rides inside that closure), and a `requestBuild` effect
    /// mints the run with the user's words as its instruction.
    ///
    /// Returns the turn's own run result so `performChatTurn`'s post-processing stays as
    /// it was. A traversal that never reached its turn throws instead — except the honest
    /// turn-less ending after `requestBuild` fired, which returns the ack line.
    private func runProseDelivery(
        scope: SZChatScope, message: String, existing: SZAgentSession?, providerID: String,
        extras: SZBriefExtras,
        turn: @escaping @MainActor (SZTurnOrder) async throws -> SZAgentRunResult
    ) async throws -> (result: SZAgentRunResult, ack: String?) {
        guard let packsRoot = Self.graphAgentPacksRoot() else {
            throw SZChatTraversalFailure(detail: "no agent packs — the bundled packs did not "
                + "materialize and no valid SZ_AGENT_PACKS override is set")
        }
        let loaded = SZAgentPackLoader.load(root: packsRoot)
        guard let agentID = Self.chatAgentID(for: scope, seats: loaded.seats),
              let pack = loaded.packs.first(where: { $0.id == agentID }),
              let graph = pack.graph else {
            throw SZChatTraversalFailure(
                detail: "no agent answers \(turnLabel(for: scope)) — its pack is missing or broken")
        }
        // Attach the graph's step declarations (compiled once; the host's step runtime
        // caches across turns). A step that will not compile refuses HERE, loudly.
        let steps = SZHostStepRunning(packsRoot: packsRoot, runtime: stepRuntime)
        var attachments: [String: SZStepAttachment] = [:]
        for node in graph.nodes {
            guard case .step(let name) = node.form else { continue }
            if let info = try await steps.declaration(agent: pack.id, step: name) {
                attachments[node.id] = SZStepAttachment(outcomes: Set(info.outcomes))
            }
        }
        let renderer = SZBriefRenderer(packRoot: packsRoot)
        let generation = resolvedGenerationSettings(for: providerID)
        let router = SZIdentityRouter(choice: SZModelChoice(
            providerID: providerID, model: generation.model,
            reasoningEffort: generation.reasoningEffort))
        // One query service per delivery (the door's triage ask); production executor.
        let queries = SZQueryService(
            renderer: renderer, router: router,
            cacheDirectory: FileManager.default.temporaryDirectory.appending(path: "sz-agent-cache"))
        // The turn's result crosses the seam in a box: the graph speaks SZTurnReport
        // (process truth only), while performChatTurn needs the full run result back.
        final class Capture { var result: SZAgentRunResult?; var error: Error?; var minted = false }
        let capture = Capture()
        // A prose reply is a traversal like any other: it gets its record, thread-less (a
        // conversation is never part of a build thread).
        let sighting = SZTraversalSighting(id: UUID(), agent: pack.id)
        beginAgentGraphRun(sighting, thread: nil)
        let delivery = SZDelivery(
            agent: pack.id, message: message, extras: extras,
            renderer: renderer, queries: queries,
            world: { [weak self] in
                guard let self else { return SZWorld() }
                return SZWorld(graph: self.store.project?.graph,
                               statuses: self.nodeStatusLines,
                               node: scope.nodeID,
                               resuming: existing != nil)
            },
            turn: { order in
                do {
                    let result = try await turn(order)
                    capture.result = result
                    return SZTurnReport(failed: result.outcome.failed,
                                        detail: result.outcome.message)
                } catch {
                    capture.error = error
                    return SZTurnReport(failed: true, detail: String(describing: error))
                }
            },
            effect: { [weak self] effect in
                guard let self else { return }
                switch effect {
                case .requestBuild:
                    // The door ruled the prose a build: mint the run with the user's words
                    // as its standing instruction. The pump admits it the moment this
                    // delivery's claim frees.
                    capture.minted = true
                    self.mintRun(instruction: message)
                }
            },
            onNote: { [weak self] note in self?.noteAgentGraphRun(sighting.id, note) })
        let outcome = await SZGraphEngine(
            agent: pack.id, graph: graph, attachments: attachments,
            host: delivery, steps: steps, router: router).run()
        concludeAgentGraphRun(sighting.id, SZTraversalEnding(outcome.conclusion))
        // The turn's own throw (Stop, zombie claim, stale session) resumes performChatTurn's
        // existing catch handling untouched.
        if let error = capture.error { throw error }
        guard let result = capture.result else {
            switch outcome.conclusion {
            case .cancelled:
                throw CancellationError()
            case .failed(let node, let detail), .defect(let node, let detail):
                throw SZChatTraversalFailure(detail: "graph '\(node)': \(detail)")
            case .ended(let node, let endOutcome):
                // A turn-LESS ending is honest exactly when this delivery minted a run —
                // the run is the reply. The delivery performed the effect, so it KNOWS.
                if capture.minted {
                    return (SZAgentRunResult(
                        process: SZProcessResult(exitCode: 0, output: ""),
                        outcome: SZAgentOutcome(sessionID: nil, failed: false)),
                        ack: "(build requested — starting a run)")
                }
                throw SZChatTraversalFailure(detail:
                    "the graph ended at '\(node)' (\(endOutcome)) without running a turn")
            case .declined(let node, let reason):
                throw SZChatTraversalFailure(detail: "the graph declined at '\(node)'"
                    + (reason.map { ": \($0)" } ?? ""))
            }
        }
        if case .defect(let node, let detail) = outcome.conclusion {
            // On the DELIVERING scope's transcript — a node chat's routing defect belongs
            // in that node's conversation.
            store.appendChatMessage(
                SZChatMessage(role: .assistant,
                              text: "(reply routing failed at '\(node)': \(detail))",
                              transient: true),
                to: scope)
            flushTranscript(scope)
        }
        return (result, ack: nil)
    }
}

/// A prose delivery that could not do its job before (or instead of) running its turn.
struct SZChatTraversalFailure: Error, CustomStringConvertible {
    let detail: String
    var description: String { detail }
}
