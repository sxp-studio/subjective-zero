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

    /// Deliver every free recipient's next fold — synchronous scan, spawn per delivery. Steers
    /// are never pumped (their consumer drains them).
    func pumpMailboxes() {
        guard !pumpSuspended else { return }
        admitPendingTasks()
        for key in mailbox.recipientsWithPending {
            guard activeDeliveries < Self.deliveryCap else { break }
            guard let scope = SZChatScope(key: key) else { continue }
            let fold = mailbox.fold(for: key)
            guard !fold.isEmpty else { continue }
            guard inFlightAssistantIDs[key] == nil else { continue }   // zombie still streaming
            let claim = SZClaimToken(label: "delivery to \(turnLabel(for: scope))")
            guard ledger.tryAcquire(Self.turnResources(for: scope), as: claim) else { continue }
            // The whole fold moves together: one turn, one record, and every id reaches its
            // terminal state at the same moment.
            let envelopeIDs = fold.map(\.id)
            for id in envelopeIDs { mailbox.markDelivering(id) }
            activeDeliveries += 1
            chatTurnTasks[scope.key] = Task { @MainActor in
                await performChatTurn(envelopeIDs, scope: scope, claim: claim)
            }
        }
    }

    /// Deliver one envelope as a real agent turn on its scope, THROUGH its agent's graph.
    /// Prompt, recap, and mention expansion are built HERE, at delivery time, against the
    /// live graph. Never touches the active tab. Ends with `markProcessed` → release →
    /// the pump's next pass, whose head admits any minted run before queued prose.
    func performChatTurn(_ envelopeIDs: [UUID], scope: SZChatScope, claim: SZClaimToken) async {
        // The fold delivers as ONE turn, so every id in it reaches the same terminal state at the
        // same moment. The head is the envelope the delivery is "about" (its bubble, its session).
        guard let envelopeID = envelopeIDs.first else { return }
        func markProcessed() { for id in envelopeIDs { mailbox.markProcessed(id) } }
        func markFailed(_ reason: String) { for id in envelopeIDs { mailbox.markFailed(id, reason: reason) } }
        func requeue() { for id in envelopeIDs { mailbox.requeue(id) } }
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
        // Every folded part, in order — the same "\n\n" join the steer lane uses.
        let folded = envelopeIDs.compactMap { mailbox.envelope(for: $0) }
        let text = folded.map(\.message.text).joined(separator: "\n\n")

        // A transient note under the already-shown bubble — the delivery-time counterpart of
        // sendChat's pre-flight rejects (the enqueue-time checks passed; the world moved since).
        func fail(_ note: String) {
            store.appendChatMessage(SZChatMessage(role: .assistant, text: note, transient: true), to: scope)
            markFailed(note)
        }

        guard store.project != nil,
              scope.nodeID == nil || store.project?.graph.node(id: scope.nodeID!) != nil else {
            markFailed("the recipient no longer exists")
            return
        }
        guard let mcpPort = agentMCPServer?.port, loadedProjectURL != nil else {
            return fail("(host not ready — message not delivered)")
        }
        let provider: any SZProvider
        let existing: SZAgentSession?
        switch providerForTurn(scope, heal: true) {
        case .refused(let note):
            return fail(note)
        case .ready(let ready, let session, let note):
            provider = ready
            existing = session
            if let note {
                store.appendChatMessage(SZChatMessage(role: .assistant, text: note, transient: true), to: scope)
            }
        }
        let providerID = provider.id

        // Redelivery after a restart whose transcript lost the bubble (queue survived, sidecar
        // older): re-append it so the conversation shows what is being delivered.
        for part in folded {
            guard let bubbleID = part.transcriptMessageID,
                  !store.messages(for: scope).contains(where: { $0.id == bubbleID }) else { continue }
            store.appendChatMessage(part.message, to: scope)
            flushTranscript(scope)
        }

        // This envelope's own bubbles and every still-queued bubble behind it are NOT prior
        // conversation; they are what is being delivered (or is still to be).
        var ownBubbles = Set(folded.compactMap(\.transcriptMessageID))
        let queuedBubbles = Set(mailbox.pending(for: scope.key).compactMap(\.transcriptMessageID))

        let cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "sz-agent-cache")
        let workingDirectory = cacheDirectory.appending(path: "agent/\(scope.key)")
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        status = "chatting (\(scope.key.prefix(8))…)"
        let workingNodeID = scope.nodeID
        if let workingNodeID { setNodeChatting(workingNodeID, true) }
        defer { if let workingNodeID { setNodeChatting(workingNodeID, false) } }

        let assistantID = store.appendChatMessage(SZChatMessage(role: .assistant, text: ""), to: scope)
        ownBubbles.insert(assistantID)
        deliveringBubbles[scope.key] = ownBubbles
        // Mark the turn in-flight the moment its bubble exists, not only when `deliver` opens it:
        // the door's triage runs in between, and without this the header sits with no working dots
        // for that whole gap. `deliver` re-sets the same id; the clears are ownership-checked, so a
        // later turn that repins the scope keeps its own marker.
        inFlightAssistantIDs[scope.key] = assistantID
        defer {
            deliveringBubbles[scope.key] = nil
            if inFlightAssistantIDs[scope.key] == assistantID { inFlightAssistantIDs[scope.key] = nil }
        }
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

        var resumedThisTurn = false
        // The turn core, driven by the graph's own ORDER: `tools` and `session` are what
        // the turn node declares (so tool-free-ness is the debug pack's `"tools": []`
        // rather than a scope branch here), and `choice` is the router's verdict.
        func runDeliveredTurn(_ order: SZTurnOrder, prompt: String) async throws
            -> (result: SZAgentRunResult, generation: String, turnID: UUID) {
            let turn = order.resolved(against: existing)
            guard let turnProvider = SZProviderRegistry.shared.provider(id: turn.choice.providerID) else {
                throw SZMCPError.message("unknown provider: \(turn.choice.providerID)")
            }
            let request = SZAgentRunRequest(
                // Live, never captured at the top of the delivery: a Save As can relocate the
                // project while this turn awaits its CLI.
                turn, prompt: prompt, workingDirectory: workingDirectory, packageDirectory: loadedProjectURL,
                cacheDirectory: cacheDirectory, mcpPort: mcpPort,
                defaultTools: SZHostBridge.agentCallableToolNames)
            resumedThisTurn = request.resumeSessionID != nil
            // A scope keeps ONE session, and every lane of the node shares it. A resume turn owns
            // it; a spawn turn may only ESTABLISH it, never replace it — otherwise a side lane
            // (an edit, routed to its own slot) would repin the scope to its model and drag the
            // chat and reconcile lanes onto that model for good.
            let result = try await deliver(scope: scope, request: request, provider: turnProvider,
                                           pinSession: order.session == .resume || existing == nil,
                                           existingAssistantID: assistantID, claim: claim,
                                           via: turn.choice.via).result
            // A spawn on a pinned scope (an edit) moved the files on without the thread; retire
            // it so the next chat cold-starts on the recap and the current files.
            if order.session == .spawn, existing != nil, !result.outcome.failed {
                agentSessions[scope.key] = nil
                persistAgentSessions()
            }
            return (result, SZTurnGeneration(
                providerID: turnProvider.id, model: request.model,
                reasoningEffort: request.reasoningEffort, fastMode: request.fastMode).label,
                assistantID)
        }
        do {
            // EVERY delivery flows through its agent's graph: the door decides what the
            // message is, the pack decides which brief a turn gets (and whether the
            // conversation rides above it), and the turn streams through `runDeliveredTurn`
            // unchanged. Only THIS message's attachments are appended here.
            let expanded = SZMentionExpansion.agentText(
                text, nodes: (store.project?.graph.nodes ?? []).map { (id: $0.id, title: $0.title) })
            // Every folded part's attachments ride along — one turn sees all of them.
            let messageAttachments = folded.flatMap(\.message.attachments)
            // A node delivery carries the node's current files on EVERY message — the cold
            // chat seed needs them once, and the edit lane re-grounds on them each turn
            // (after an edit, a session's memory of the files is stale by construction).
            // The renderer computes only what a brief mentions, so lanes that don't ask
            // (the bare resumed chat) cost nothing beyond these two reads.
            var extras = SZBriefExtras(target: projectTarget)
            if case .node(let nodeID) = scope, let projectURL = loadedProjectURL {
                let nodeDir = projectURL.appending(path: "nodes/\(nodeID.uuidString)")
                extras.nodeContract =
                    (try? String(contentsOf: nodeDir.appending(path: "node-contract.json"), encoding: .utf8))
                    ?? "(no contract yet)"
                extras.nodeSource =
                    (try? String(contentsOf: nodeDir.appending(path: nodeSourceFileName), encoding: .utf8))
                    ?? "(this node has no \(nodeSourceFileName) yet)"
                // The node's custom card rides along: an edit that renames a port must re-stage the
                // card that reads it (the brief's card section says so).
                if let card = try? String(contentsOf: SZProjectIO.cardSourceURL(projectURL: projectURL, nodeID: nodeID),
                                          encoding: .utf8) {
                    extras.nodeSource! += "\n\n// ===== Card.swift (this node's custom card) =====\n" + card
                }
            }
            let (result, turnless, mintedTaskIDs) = try await runProseDelivery(
                scope: scope, message: expanded, existing: existing, providerID: providerID,
                extras: extras, priorConversationExcluding: ownBubbles.union(queuedBubbles)) { order, opened in
                    var prompt = order.brief
                    if !messageAttachments.isEmpty { prompt += Self.attachmentManifest(messageAttachments) }
                    // This lane opened its message before the traversal began, so the card can
                    // read along from the first chunk. The envelope rides `deliver`'s own call.
                    opened(assistantID, nil)
                    return try await runDeliveredTurn(order, prompt: prompt)
                }
            if Task.isCancelled {
                // The per-turn Stop: a user choice, not a failure — the killed resume is still
                // resumable, and the message WAS delivered (its turn ran).
                let empty = store.messages(for: scope).first(where: { $0.id == assistantID })?.text.isEmpty == true
                reply(empty ? "(stopped)" : "\n(stopped)")
                status = "chat turn stopped"
                // Only the DIRECTOR turn's Stop discards the tasks IT scheduled — never a task
                // someone else queued while this turn was streaming.
                for id in mintedTaskIDs { withdrawTask(id) }
                markProcessed()
                return
            }
            if turnless {
                // The door ruled the prose a build and no turn ran: the RUN is the reply (its
                // lanes in the strip now, its receipt in this transcript when it settles), so the
                // bubble the delivery opened has nothing to say. Drop it rather than leave an
                // empty speaker row, and drop its queue-wait row with it.
                store.removeChatMessage(assistantID, in: scope)
                flushTranscript(scope)
                SZTrace.discard(turnID: assistantID)
                status = "build requested"
                markProcessed()
                return
            }
            let empty = store.messages(for: scope).first(where: { $0.id == assistantID })?.text.isEmpty == true
            status = result.outcome.failed ? "chat turn failed" : "chat reply ready"
            // The shared ladder, with this lane's pre-emption first: a failed resume claims the
            // failure before the provider probe opens a setup sheet at a session that expired.
            switch await turnFailure(result, provider: provider,
                                     preempt: { resumedThisTurn && self.dropSessionAfterFailedResume(scope) }) {
            case .timedOut(let detail):
                // A timeout is its own outcome and no evidence the session is dead (the cold
                // retry would only run down the same clock again).
                reply((empty ? "" : "\n") + "⚠️ \(detail)")
                status = "chat turn timed out"
                markFailed(detail)
                return
            case .preempted:
                // ONE cold-start redelivery; with the pin gone a second failure lands in markFailed.
                reply((empty ? "" : "\n") + "(could not continue the previous session, starting a fresh one)")
                store.setChatTransient(assistantID, in: scope)   // a notice, not conversation
                status = "chat turn failed, retrying with a fresh session"
                requeue()
                return   // the defer's release re-fires the pump → redelivery
            case .provider(let detail):
                reply((empty ? "" : "\n") + "⚠️ Provider error: \(detail)")
            case .agent, nil:
                if empty { reply(result.outcome.failed ? "(agent run failed)" : "(no text response)") }
            }
            if result.outcome.failed {
                markFailed(result.outcome.message ?? "the turn failed")
            } else {
                markProcessed()
            }
        } catch {
            // A deliver that bowed out before its turn-end path ran left the queue-wait row
            // parked under this turn — drop it rather than leak it.
            SZTrace.discard(turnID: assistantID)
            if resumedThisTurn, dropSessionAfterFailedResume(scope) {
                reply("(could not continue the previous session, starting a fresh one)")
                store.setChatTransient(assistantID, in: scope)
                status = "chat turn failed, retrying with a fresh session"
                requeue()
                return
            }
            reply("(chat failed: \(error))")
            status = "chat failed"
            markFailed("\(error)")
        }
        // A run this turn minted (the door's `requestBuild`, or a mid-turn `ui_run`) fires
        // from the pump: the defer's release triggers `admitPendingTasks` at the
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
    /// `priorConversationExcluding` keeps the projected conversation strictly prior: this
    /// delivery's own bubbles and the ones still queued behind it are not history.
    /// Returns the turn's own run result so `performChatTurn`'s post-processing stays as
    /// it was. A traversal that never reached its turn throws instead — except the honest
    /// turn-less ending after `requestBuild` fired, which returns `turnless: true` (the run
    /// is the reply, so the caller drops the bubble instead of writing one).
    func runProseDelivery(
        scope: SZChatScope, message: String, existing: SZAgentSession?, providerID: String,
        extras: SZBriefExtras, priorConversationExcluding: Set<UUID> = [],
        turn: @escaping @MainActor (SZTurnOrder, @escaping @MainActor @Sendable (UUID, String?) -> Void)
            async throws -> (result: SZAgentRunResult, generation: String, turnID: UUID)
    ) async throws -> (result: SZAgentRunResult, turnless: Bool, scheduled: [UUID]) {
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
        // The same gate the build lane holds: a graph only traverses out of a library that
        // validates. Chat is where an EDITED pack first runs, and shape defects (an
        // unleashed cycle, a dangling edge) exist only in `validate` — skipping it here
        // would let a broken graph traverse unbounded. Compiles are cached, so this costs
        // once per edit, not per message.
        var defects = loaded.defects
        defects += await SZAgentPackLoader.validate(packs: loaded.packs, steps: steps)
        guard defects.isEmpty else {
            throw SZChatTraversalFailure(detail: "the agent-pack library does not validate "
                + "(\(defects.count) defect\(defects.count == 1 ? "" : "s")):\n"
                + defects.map { "  · \($0)" }.sorted().joined(separator: "\n"))
        }
        var attachments: [String: SZStepAttachment] = [:]
        for node in graph.nodes {
            guard case .step(let name) = node.form else { continue }
            if let info = try await steps.declaration(agent: pack.id, step: name) {
                attachments[node.id] = SZStepAttachment(outcomes: Set(info.outcomes))
            }
        }
        let renderer = SZBriefRenderer(packRoot: packsRoot)
        // This delivery's routing table. Dropped routes narrate on the delivering scope (once
        // per profile state, not per message); an unknown launch-pin profile refuses the delivery.
        let routing: (router: any SZModelRouting, notes: [String])
        do {
            routing = try makeRouter(providerID: providerID)
        } catch let refusal as SZRoutingRefusal {
            throw SZChatTraversalFailure(detail: refusal.detail)
        }
        let router = routing.router
        for note in routing.notes {
            store.appendChatMessage(
                SZChatMessage(role: .assistant, text: "⚠️ \(note)", transient: true), to: scope)
            flushTranscript(scope)
        }
        // (No grading teaching in this lane — the chat/amend briefs carry no {{grading}} token.)
        // One query service per delivery (the door's triage ask); production executor.
        let queries = SZQueryService(
            renderer: renderer, router: router,
            cacheDirectory: FileManager.default.temporaryDirectory.appending(path: "sz-agent-cache"))
        // The turn's result crosses the seam in a box: the graph speaks SZTurnReport
        // (process truth only), while performChatTurn needs the full run result back.
        final class Capture { var result: SZAgentRunResult?; var error: Error?; var mintedTasks: [UUID] = [] }
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
                               resuming: graph.resumes(existing, agent: pack.id, router: router),
                               pendingTasks: self.pendingTasks,
                               runningTasks: self.runningTasks,
                               conversation: self.conversation(for: scope,
                                                               excluding: priorConversationExcluding))
            },
            turn: { order, opened in
                do {
                    let (result, generation, turnID) = try await turn(order, opened)
                    capture.result = result
                    return SZTurnReport(failed: result.outcome.failed,
                                        detail: result.outcome.message,
                                        generation: generation, turnID: turnID)
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
                    // as its standing instruction (and this delivery's bubbles as its origin).
                    // The pump admits it the moment this delivery's claim frees.
                    capture.mintedTasks.append(self.mintRun(instruction: message))
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
                if !capture.mintedTasks.isEmpty {
                    return (SZAgentRunResult(
                        process: SZProcessResult(exitCode: 0, output: ""),
                        outcome: SZAgentOutcome(sessionID: nil, failed: false)),
                        turnless: true, scheduled: capture.mintedTasks)
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
        return (result, turnless: false, scheduled: capture.mintedTasks)
    }
}

/// A prose delivery that could not do its job before (or instead of) running its turn.
struct SZChatTraversalFailure: Error, CustomStringConvertible {
    let detail: String
    var description: String { detail }
}
