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
        fireQueuedDirectorRunIfPossible()
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

    /// Start the run a Director turn queued (`ui_run` mid-turn → `pendingDirectorRun`) the moment
    /// it can actually claim what it needs. Runs at the head of every pump pass — i.e. on every
    /// ledger release — so the ORDERING is structural: the promised run always beats the next
    /// queued Director message to the freed transcript, and a start refused by a transient claim
    /// (a concurrent delivery holding a work-set node) retries on the next release instead of
    /// being dropped. Cleared only on a SUCCESSFUL start (or by stopping the Director's turn).
    private func fireQueuedDirectorRunIfPossible() {
        guard let instruction = pendingDirectorRun, !isRunning,
              ledger.holder(of: .transcript(.director)) == nil else { return }
        startRun(instruction: instruction, directorAlreadyBriefed: true)
        if isRunning { pendingDirectorRun = nil }
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
        // older): re-append it so the conversation shows what is being delivered. The common case —
        // bubble restored with the transcript — appends nothing (`transcriptMessageID` matches).
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

        // Queue wait, keyed to THIS turn's own message id — misattribution is impossible by
        // construction (v1 stashed per-scope and had to guard zombies). Recorded via the explicit-
        // turnID escape hatch: the turn's context binding doesn't exist until deliver.
        if SZTrace.isEnabled {
            SZTrace.record(SZTurnEvent(stage: SZTurnStage.queueWait, start: envelope.enqueuedAt,
                                       duration: waitEnded.timeIntervalSince(envelope.enqueuedAt)),
                           turnID: assistantID)
        }

        let generation = resolvedGenerationSettings(for: providerID)
        // The turn core BOTH delivery paths below share: one assembled prompt, streamed
        // through `deliver` under this delivery's claim into the already-open bubble.
        func runDeliveredTurn(_ prompt: String) async throws -> SZAgentRunResult {
            let request = SZAgentRunRequest(
                prompt: prompt,
                workingDirectory: workingDirectory,
                packageDirectory: projectURL,
                cacheDirectory: cacheDirectory,
                mcpServerPort: scope == .debug ? nil : mcpPort,   // the debug chat agent is tool-free
                allowedMCPTools: scope == .debug ? [] : SZHostBridge.agentCallableToolNames,
                resumeSessionID: existing?.sessionID,
                model: generation.model,
                reasoningEffort: generation.reasoningEffort,
                fastMode: generation.fastMode ?? false,
                timeout: 300)
            return try await deliver(scope: scope, request: request, provider: provider,
                                     existingAssistantID: assistantID, claim: claim).result
        }
        do {
            let result: SZAgentRunResult
            if scope == .director {
                // The DIRECTOR turn flows through its CHAT GRAPH: the resuming fork picks
                // the brief, the turn streams through `runDeliveredTurn` exactly as before
                // (recap + attachments wrap the brief HERE, delivery context that never
                // enters the pack render), and the route-reply ruling decides what the turn
                // WAS — firing `requestBuild` when the answer is a build.
                let expanded = SZMentionExpansion.agentText(
                    text, nodes: (store.project?.graph.nodes ?? []).map { (id: $0.id, title: $0.title) })
                let messageAttachments = envelope.message.attachments
                result = try await runDirectorChatTraversal(
                    message: expanded, existing: existing, providerID: providerID) { brief in
                        var prompt = brief
                        if let recap { prompt = recap + "\n\n" + prompt }
                        if !messageAttachments.isEmpty { prompt += Self.attachmentManifest(messageAttachments) }
                        return try await runDeliveredTurn(prompt)
                    }
            } else {
                result = try await runDeliveredTurn(buildChatPrompt(
                    scope: scope, message: text, existing: existing, recap: recap,
                    projectURL: projectURL, attachments: envelope.message.attachments))
            }
            if Task.isCancelled {
                // The per-turn Stop: a user choice, not a failure — the killed resume is still
                // resumable, and the message WAS delivered (its turn ran).
                let empty = store.messages(for: scope).first(where: { $0.id == assistantID })?.text.isEmpty == true
                reply(empty ? "(stopped)" : "\n(stopped)")
                status = "chat turn stopped"
                // Only the DIRECTOR turn's Stop kills its own queued run — stopping some other
                // scope's concurrent delivery must not discard a run the Director promised.
                if scope == .director { pendingDirectorRun = nil }
                mailbox.markProcessed(envelopeID)
                return
            }
            if result.outcome.failed, dropSessionIfStale(scope) {
                // The probation self-heal just fired: the failure was (very likely) the stale
                // disk-restored session, and the machinery healed at the exact moment this message
                // died. ONE cold-start redelivery — bounded structurally: with the session gone, a
                // second failure can't drop anything, so it lands in markFailed below.
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
            // A deliver that bowed out before its turn-end path ran (claim refusal, zombie) left
            // the queue-wait row parked under this turn — drop it rather than leak it. Harmless
            // no-op when finalizeTurn already took the events.
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
        // A ui_run recorded during THIS Director turn fires from the pump: the defer's release
        // triggers `fireQueuedDirectorRunIfPossible` at the head of the very next pump pass —
        // after our claim is gone (so startRun can take the transcript) and BEFORE the next queued
        // Director message is considered (so the promised run wins the freed transcript).
    }

    /// The per-scope prompt framing — cold-start seeds, debug framing, recap prepend, attachment
    /// manifest. Factored from `sendChat` verbatim; runs at DELIVERY time so mention expansion and
    /// graph context reflect the world when the agent actually reads it. The DIRECTOR scope no
    /// longer passes through here — its framing is the chat graph's briefs, rendered inside
    /// `runDirectorChatTraversal` (byte-identical to the retired direct render calls; the
    /// equivalence gate pins them).
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

    // MARK: - The Director chat traversal

    /// One DIRECTOR chat turn, delivered THROUGH the director's chat graph: the `resuming`
    /// fork picks the cold or resumed brief, the turn streams through `turn` (all the
    /// delivery machinery — recap, attachments, session resume, claims, streaming — rides
    /// inside that closure unchanged), and the `route-reply` ruling decides what the turn
    /// WAS, firing the `requestBuild` effect when the answer is a build.
    ///
    /// Runs the engine DIRECTLY, without the thread machine — a deliberate scope call: a
    /// chat is ONE traversal, and the machine's whole business (dispatch sets, one settled
    /// reply, rounds, absorbing termination) has no counterpart here; putting it in the
    /// middle would wrap a single `startTraversal` in commands nothing consumes.
    ///
    /// Returns the turn's own run result, so `performChatTurn`'s post-processing (Stop,
    /// stale-session retry, provider failure detail, queue settle) stays exactly as it was.
    /// A traversal that never reached its turn throws instead; a POST-turn routing defect
    /// never eats the streamed reply — it lands as one honest Director line beside it.
    private func runDirectorChatTraversal(
        message: String, existing: SZAgentSession?, providerID: String,
        turn: @escaping @MainActor (String) async throws -> SZAgentRunResult
    ) async throws -> SZAgentRunResult {
        guard let packsRoot = Self.graphAgentPacksRoot() else {
            throw SZChatTraversalFailure(detail: "no agent packs — the bundled packs did not "
                + "materialize and no valid SZ_AGENT_PACKS override is set")
        }
        let loaded = SZAgentPackLoader.load(root: packsRoot)
        guard let directorID = loaded.seats.director,
              let pack = loaded.packs.first(where: { $0.id == directorID }),
              let graph = pack.graph(handling: .chat) else {
            throw SZChatTraversalFailure(detail: "the director pack declares no chat graph")
        }
        // Attach the chat graph's step declarations (compiled once; the host's step runtime
        // caches across turns). A step that will not compile refuses HERE, loudly — the same
        // policy as a run's full-library gate, scoped to the one graph a chat turn traverses.
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
        // One query service per turn (route-reply's ask); production executor — the routed
        // provider runs one stateless completion.
        let queries = SZQueryService(
            renderer: renderer, router: router,
            cacheDirectory: FileManager.default.temporaryDirectory.appending(path: "sz-agent-cache"))
        // The turn's result crosses the seam in a box: the graph speaks SZTurnReport
        // (process truth only), while performChatTurn needs the full run result back.
        final class TurnCapture { var result: SZAgentRunResult?; var error: Error? }
        let capture = TurnCapture()
        let host = SZChatTraversalHost(
            message: message, resuming: existing != nil,
            renderer: renderer, graphName: graph.name, queries: queries,
            liveGraph: { [weak self] in self?.store.project?.graph },
            turn: { order in
                do {
                    let result = try await turn(order.brief)
                    capture.result = result
                    return SZTurnReport(failed: result.outcome.failed,
                                        detail: result.outcome.message)
                } catch {
                    capture.error = error
                    return SZTurnReport(failed: true, detail: String(describing: error))
                }
            },
            effect: { [weak self] effect, kind in
                guard let self else { return }
                if effect == SZChatEffect.requestBuild.rawValue {
                    // The graph's way to start a run — the SAME queued lane a mid-turn
                    // `ui_run` uses, with the user's message riding as the run's
                    // instruction (the turn that ruled `build` did the shaping).
                    self.queueChatRequestedBuild(instruction: message)
                } else {
                    await self.perform(effect: effect, kind: kind)
                }
            })
        let outcome = await SZGraphEngine(
            agent: pack.id, graph: graph, attachments: attachments,
            host: host, steps: steps, router: router).run(kind: .chat)
        // The turn's own throw (Stop, zombie claim, stale session) resumes performChatTurn's
        // existing catch handling untouched.
        if let error = capture.error { throw error }
        guard let result = capture.result else {
            switch outcome.conclusion {
            case .cancelled:
                throw CancellationError()
            case .failed(let node, let detail), .defect(let node, let detail):
                throw SZChatTraversalFailure(detail: "chat graph '\(node)': \(detail)")
            case .ended(let node, let outcome):
                throw SZChatTraversalFailure(detail:
                    "the chat graph ended at '\(node)' (\(outcome)) without running a turn")
            case .declined(let node, let reason):
                throw SZChatTraversalFailure(detail: "the chat graph declined at '\(node)'"
                    + (reason.map { ": \($0)" } ?? ""))
            }
        }
        if case .defect(let node, let detail) = outcome.conclusion {
            narrateDirector("(reply routing failed at '\(node)': \(detail))")
        }
        return result
    }

    /// The `requestBuild` chat effect's landing: queue the run on the SAME `pendingDirectorRun`
    /// lane a mid-turn `ui_run` uses — the delivering chat turn still holds the Director
    /// transcript, so a direct `startRun` here would refuse against our own claim. The pump
    /// fires it the moment the transcript frees (normally this very delivery's release), with
    /// `directorAlreadyBriefed` — the turn that ruled `build` did the shaping. A run the turn
    /// already queued itself (`ui_run` mid-turn) wins: one request is enough.
    func queueChatRequestedBuild(instruction: String) {
        guard !isRunning else {
            narrateDirector("Effect 'requestBuild' skipped — a run is already active.")
            return
        }
        if pendingDirectorRun == nil { pendingDirectorRun = instruction }
        pumpMailboxes()   // fires now if the transcript is free; else the delivery's release re-fires
    }
}

/// A chat traversal that could not do its job before (or instead of) running its turn.
struct SZChatTraversalFailure: Error, CustomStringConvertible {
    let detail: String
    var description: String { detail }
}
