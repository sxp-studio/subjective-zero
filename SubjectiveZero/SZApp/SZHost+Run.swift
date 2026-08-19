// SPDX-License-Identifier: AGPL-3.0-only
// The build lane: minting a run (the Build press, `ui_run`, the door's `requestBuild`
// effect), admitting it when its claims free, and driving it as ONE delivery — the
// director's engine traversal, with the fleet served through the dispatch supervisor.
// There is no orchestrator layer: the engine runs the graph, this file is transport.
import Foundation
import SZAI
import SZCore

extension SZHost {
    /// The shared agent-turn substrate. Every agent turn — a coding dispatch, a Director turn,
    /// a user chat — funnels through here: append an empty assistant message to `scope`, mark the turn in
    /// flight (the chat panel's working dots), stream the provider's turn into that scope's tab, record its
    /// duration, and (by default) remember the resulting session for chat-resume. Returns the result plus
    /// the assistant message id so a caller can post-process the reply (e.g. the chat empty-text fallback).
    ///
    /// One substrate for `streamCodingAgent`, `runDirectorTurn`, and the mailbox's deliveries.
    /// `existingAssistantID` lets a caller (the chat path) reuse an assistant message it already opened for
    /// its synchronous guard replies; nil → `deliver` opens its own.
    /// `claim` is the ledger token that already holds this scope's resources (a run's coding/Director
    /// turns pass the run's claim); nil → the turn claims them itself for the stream's duration, a
    /// real hold so `isBusyForProjectOps`' `anyHeld` covers chat turns and the fence sees mid-chat
    /// nodes as held.
    @MainActor
    @discardableResult
    func deliver(
        scope: SZChatScope, request: SZAgentRunRequest, provider: any SZProvider,
        persistSession: Bool = true, existingAssistantID: UUID? = nil,
        claim: SZClaimToken? = nil
    ) async throws -> (result: SZAgentRunResult, assistantID: UUID) {
        let turnResources = Self.turnResources(for: scope)
        var selfClaim: SZClaimToken?
        if let claim {
            // A cancelled run's zombie dispatch presents its RELEASED token while someone else (a
            // pump delivery, a new run) may already own the scope — streaming would interleave two
            // turns in one transcript and clobber its in-flight marker. Bow out; the caller
            // treats it like any cancelled turn. A holder mismatch WITHOUT cancellation is a real
            // claim-model divergence and stays a debug tripwire.
            guard ledger.holder(of: .transcript(scope)) == claim else {
                assert(Task.isCancelled,
                       "deliver: caller claim '\(claim.label)' does not hold transcript/\(scope.key)")
                throw CancellationError()
            }
        } else {
            let token = SZClaimToken(label: turnLabel(for: scope))
            if ledger.tryAcquire(turnResources, as: token) {
                selfClaim = token
            } else if Task.isCancelled {
                // Zombie path post-cancel: the scope has a new owner — do not stream into it.
                throw CancellationError()
            } else {
                // Tripwire: the admission paths (pump claim / run claim) should make contention
                // here impossible. A firing assertion means the claim model and reality disagree —
                // fix the model, don't ship the divergence.
                assertionFailure("deliver: could not claim \(scope.key) — blocked by "
                    + ledger.blockers(of: turnResources).map(\.label).joined(separator: ", "))
            }
        }
        let assistantID = existingAssistantID ?? store.appendChatMessage(SZChatMessage(role: .assistant, text: ""), to: scope)
        inFlightAssistantIDs[scope.key] = assistantID   // also flips chatInFlight (derived)
        // A turn a RUN dispatched belongs to that run: the stamp is what the chat feed reads to
        // tell the fleet's implementation work from a conversation, and what its task's drill-in
        // collects by. A turn the user started carries none.
        if let run = activeRun(for: claim) { store.setChatGraphRun(run.thread, assistantID, in: scope) }
        // The run identity is CAPTURED here: finalize re-checks it against the live runs, so a
        // zombie turn settling after cancel-and-restart can't log itself into the new run.
        let turnRunID = activeRun(for: claim)?.traceID
        let started = Date()
        let startedMono = ContinuousClock.now
        defer {
            if let selfClaim { ledger.releaseAll(of: selfClaim) }
            // Ownership-checked: if a later turn overwrote this scope's marker (a race this guard
            // is the last line of defense against), leave THEIRS in place — nilling it would let a
            // flush persist their half-streamed reply.
            if inFlightAssistantIDs[scope.key] == assistantID { inFlightAssistantIDs[scope.key] = nil }
            let wall = (ContinuousClock.now - startedMono).szSeconds
            store.setChatDuration(wall, assistantID, in: scope)
            // Breakdown lands before the flush below so it persists with the turn. Run-owned turns
            // (dispatched under the run's claim) also log themselves for the run-complete rollup.
            // (Runs OUTSIDE the context binding below — finalizeTurn keys by explicit turnID.)
            finalizeTurn(assistantID: assistantID, scope: scope, started: started,
                         ended: started.addingTimeInterval(wall), runID: turnRunID,
                         generation: [request.model ?? provider.id,
                                      request.reasoningEffort,
                                      request.fastMode ? "fast" : nil]
                            .compactMap(\.self).joined(separator: " · "))
            // Turn end = flush point: the just-completed message (no longer in-flight) lands on disk,
            // and whatever this turn did to the session map is persisted machine-locally.
            flushTranscript(scope)
            persistAgentSessions()
        }
        // The turn's trace identity, bound task-locally around the streaming stack: every fence
        // downstream (first output, tool sightings, anything a provider ever measures) attributes
        // to this turn with no parameters — see SZTrace.swift.
        let traceContext = SZTrace.isEnabled
            ? SZTraceContext(turnID: assistantID, scopeKey: scope.key, runID: turnRunID)
            : nil
        recordTurnPrompt(request.prompt, for: assistantID)
        // And the turn's OWN agent listener: a raw TCP connection carries no caller identity, so
        // the per-turn port IS the identity — it carries the turn's trace context (parallel coding
        // agents' node-less tool calls attribute exactly) AND the turn's claim token (the mutation
        // fence lets a turn edit the node it holds, and only a carried token proves whose turn is
        // calling). Falls back to the shared agent bus (heuristic attribution, no fence identity)
        // if no port is free; torn down with the turn.
        var request = request
        var turnListener: SZMCPServer?
        if request.mcpServerPort != nil, let bridge = hostBridge {
            turnListener = try? SZMCPServer.start(bridge: bridge, surface: .agent,
                                                  from: (agentMCPServer?.port ?? 42100) + 1,
                                                  traceContext: traceContext,
                                                  caller: claim ?? selfClaim, callerScope: scope)
            if let turnListener { request.mcpServerPort = turnListener.port }
        }
        defer { turnListener?.stop() }
        var result = try await SZTrace.$context.withValue(traceContext) { [request] in
            try await streamAgentTurn(provider: provider, request: request, into: scope, message: assistantID)
        }
        // A spent budget is OUR outcome — no provider ever words it — so the turn carries the
        // sentence from here. Everything downstream reads `outcome.message`: the transcript line,
        // the graph's turn report (RUNS record reason, run narration) and a node's failure pill.
        if let timeout = result.process.timeout {
            result.outcome.message = Self.timeoutDetail(timeout, request: request)
        }
        if let stats = result.outcome.reportedStats {
            SZTrace.record(stats.turnEvent(started: started), turnID: assistantID)
        }
        // A FAILED turn leaves no session behind. codex emits `thread.started` — a real, resumable
        // thread_id — before the backend rejects the request, so persisting it would let the next
        // turn `resume` a thread whose only content is that error, and replay it. A failed *resume*
        // is unaffected: `SZProvider.run` backfills the id it came with, this skips the identical
        // rewrite, and `sendChat`'s `dropSessionIfStale` owns that probation.
        if persistSession, !result.outcome.failed, let sessionID = result.outcome.sessionID {
            agentSessions[scope.key] = SZAgentSession(providerID: provider.id, sessionID: sessionID)
        }
        // A successful turn takes the scope's disk-restored session off probation (self-heal — see
        // SZHost+Transcripts.swift header); a failed resume is handled by `sendChat`.
        if !result.outcome.failed { restoredSessions[scope.key] = nil }
        trackTurnEndedTelemetry(scope: scope, providerID: provider.id, failed: result.outcome.failed,
                                timedOut: result.process.timedOut, cancelled: Task.isCancelled)
        return (result, assistantID)
    }

    /// Run one coding agent's turn during a run and stream it into that node's Coding Agent tab.
    /// Opens the node's tab (without stealing the active tab — a run watches the Director tab),
    /// marks the turn in flight, then streams the agent's activity+reply via `streamAgentTurn`.
    @MainActor
    func streamCodingAgent(
        node: SZNodeID, request: SZAgentRunRequest, provider: any SZProvider,
        claim: SZClaimToken? = nil
    ) async throws -> SZAgentRunResult {
        let scope = SZChatScope.node(node)
        // Debug test affordance: force this node to fail its first dispatch once — report `needsInput`
        // and throw WITHOUT running an agent — so the reconcile loop fires live & repeatably
        // (`debug_fail_node_once`).
        if let blocker = forcedFailNodes.removeValue(forKey: node) {
            store.appendChatMessage(SZChatMessage(role: .assistant,
                text: "(debug) forced needsInput — skipping implementation this attempt to exercise the reconcile loop."), to: scope)
            recordNodeStatus(node: node, phase: .needsInput, message: blocker)
            throw SZMCPError.message("(debug) forced needsInput: \(blocker)")
        }
        // THE dispatch moment for this node, and so the prompt `promoteStagedNode` holds the agent to.
        // Recorded here because the brief is composed from the live graph after the Director decomposes.
        // Each turn re-records, so the reconcile rounds are held to their own latest brief.
        dispatchPrompts[node] = store.project?.graph.node(id: node)?.prompt
        // The promote evidence is per-DISPATCH, not per-run: a reconcile round redispatching this node
        // says the last build did not settle it, so an earlier promote no longer vouches for THIS turn.
        // Without this a second agent that dies silently still counts as implemented. Claim-guarded like
        // every other run-state write here: a cancelled run's zombie dispatch must not erase the promote
        // evidence the NEW run just recorded for this node.
        activeRun(for: claim)?.promoted.remove(node)
        // Under the run's CAPTURED claim (it holds every work-set node + transcript while live).
        // A cancelled run's zombie dispatch presents its released token; deliver detects that and
        // bows out instead of double-streaming into a scope someone else now owns.
        let result = try await deliver(scope: scope, request: request, provider: provider,
                                       claim: claim).result
        // Land the provider's actual failure in this node's transcript — otherwise the real reason
        // (timeout, CLI error) is invisible and the node reads as a silent Draft.
        switch await turnFailure(result, provider: provider) {
        case .timedOut(let detail):
            // Our budget ran out, not the provider's fault — a plain warning line.
            appendWarningLine(detail, to: scope)
        case .provider(let detail):
            // A mid-turn provider death: the red pill carries the same actionable detail —
            // set BEFORE the run's end so `surfaceUnresolvedNodes` doesn't overwrite it. The HOST's
            // line, not the agent's: it never overrules a build this node already promoted.
            recordHostFailure(node: node, message: detail)
            appendProviderErrorLine(detail, to: scope)
        case .agent(let detail):
            appendProviderErrorLine(detail, to: scope)
        case .preempted, nil:
            break
        }
        return result
    }

    /// The one timeout sentence every lane reports — `deliver` stamps it onto the turn's outcome so
    /// the transcript line, the RUNS record, the node pill and the run narration all read the same.
    /// Wall clock and silence are different stories, so they get different words.
    nonisolated static func timeoutDetail(_ timeout: SZProcessTimeout, request: SZAgentRunRequest) -> String {
        switch timeout {
        case .wallClock:
            let after = span(request.timeout).map { " after \($0)" } ?? ""
            return "the agent timed out\(after) without finishing — the task may be too large for one turn (try splitting it up or allowing a longer budget)"
        case .silence:
            let quiet = span(request.inactivityTimeout).map { " for \($0)" } ?? ""
            return "the agent went silent\(quiet) and was stopped — it may have wedged mid-turn (try again, or allow a longer silence budget)"
        }
    }

    /// A failed turn's reason, in the words it already carries (`deliver` stamps timeouts).
    nonisolated static func turnFailureDetail(_ result: SZAgentRunResult) -> String {
        result.outcome.message ?? "the provider reported a failure with no message"
    }

    /// WHY a turn failed — the one ladder every lane asks (a coding dispatch, a Director turn, a chat
    /// delivery), so their guards and their words cannot drift apart. A user Stop is a choice, not a
    /// failure: nothing to report. `preempt` runs between the timeout ruling and the provider probe —
    /// the chat lane's stale-session retry must claim the failure before the probe (and its setup
    /// sheet) does; no other lane has one. Each lane still decides what to DO with the answer.
    func turnFailure(_ result: SZAgentRunResult, provider: any SZProvider,
                     preempt: () -> Bool = { false }) async -> SZTurnFailure? {
        guard result.outcome.failed, !Task.isCancelled else { return nil }
        if result.process.timedOut { return .timedOut(Self.turnFailureDetail(result)) }
        if preempt() { return .preempted }
        if let detail = await providerFailureDetail(result: result, provider: provider) {
            return .provider(detail)
        }
        return .agent(Self.turnFailureDetail(result))
    }

    /// A budget as "15m" / "45s" — nil budget, no figure.
    private nonisolated static func span(_ seconds: TimeInterval?) -> String? {
        seconds.map { $0 >= 60 ? "\(Int($0 / 60))m" : "\(Int($0))s" }
    }

    /// The terminal "⚠️ Provider error:" line beneath a streamed turn — one composer for the
    /// run-path scopes; the flush lands it after `deliver`'s turn-end flush. Reserved for genuine
    /// provider failures: anything of ours (a spent budget) uses `appendWarningLine`.
    @MainActor
    func appendProviderErrorLine(_ detail: String, to scope: SZChatScope) {
        appendWarningLine("Provider error: \(detail)", to: scope)
    }

    /// The terminal "⚠️ …" line beneath a streamed turn, in whatever words the caller has.
    @MainActor
    func appendWarningLine(_ text: String, to scope: SZChatScope) {
        store.appendChatMessage(SZChatMessage(role: .assistant, text: "⚠️ \(text)"), to: scope)
        flushTranscript(scope)
    }

    /// Run one Director Agent turn — the active provider with the MCP server attached and the
    /// rendered brief, streamed live into the Director tab. `session: .resume` continues the
    /// director's own session (the graph's reconcile turn declares it); `.spawn` cold-starts.
    @MainActor
    func runDirectorTurn(
        prompt: String, session: SZAgentGraph.Turn.Session, providerID: String,
        mcpPort: UInt16, projectURL: URL, cacheDirectory: URL,
        claim: SZClaimToken? = nil
    ) async throws -> SZAgentRunResult {
        let run = activeRun(for: claim)
        guard let provider = SZProviderRegistry.shared.provider(id: providerID) else {
            throw SZMCPError.message("unknown provider: \(providerID)")
        }
        let scope = SZChatScope.director
        let workingDirectory = cacheDirectory.appending(path: "agent/director")
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let generation = resolvedGenerationSettings(for: providerID)
        let request = SZAgentRunRequest(
            prompt: prompt, workingDirectory: workingDirectory, packageDirectory: projectURL,
            cacheDirectory: cacheDirectory, mcpServerPort: mcpPort,
            allowedMCPTools: SZHostBridge.agentCallableToolNames,
            // A RUN resumes its OWN Director thread. The host's slot is keyed by scope, so two
            // concurrent runs sharing it would interleave in one CLI conversation. Off a run
            // (the chat lane) the scope slot is still the right one.
            resumeSessionID: session == .resume
                ? (run.map { $0.directorSession?.sessionID } ?? agentSessions[scope.key]?.sessionID)
                : nil,
            model: generation.model, reasoningEffort: generation.reasoningEffort,
            fastMode: generation.fastMode ?? false,
            timeout: SZAgentTurnBudgets.codingTimeout,
            inactivityTimeout: SZAgentTurnBudgets.codingInactivityTimeout)
        // The Director transcript is claimed for THIS TURN, not for the run's life — that is what
        // lets two runs' fleets work at once while their Director turns take the transcript in
        // turn. Under the run's CAPTURED claim (reentrant per token), never a live lookup: a
        // zombie director turn resuming after cancel-and-restart would otherwise adopt another
        // run's claim, pass deliver's holder guard, and stream into a transcript someone owns.
        if let claim {
            try await ledger.acquire([.transcript(scope)], as: claim)
            // The wait can outlive the run: a cancelled run's parked waiter is still in the grant
            // queue, and taking the transcript now would stream into one it no longer owns.
            if let run, !isLive(run) {
                ledger.release([.transcript(scope)], by: claim)
                throw CancellationError()
            }
        }
        defer { if let claim { ledger.release([.transcript(scope)], by: claim) } }
        let result = try await deliver(scope: scope, request: request, provider: provider,
                                       persistSession: run == nil, claim: claim).result
        // A run keeps its Director thread on ITS OWN state, not the host's scope slot.
        if let run, !result.outcome.failed, let sessionID = result.outcome.sessionID {
            run.directorSession = SZAgentSession(providerID: provider.id, sessionID: sessionID)
        }
        // The run re-reads the graph rather than the reply, so a mid-turn provider death
        // would otherwise vanish — land it in the Director tab like a coding turn's error line.
        switch await turnFailure(result, provider: provider) {
        case .timedOut(let detail): appendWarningLine(detail, to: scope)
        case .provider(let detail): appendProviderErrorLine(detail, to: scope)
        // An ordinary failure needs no line here: the graph's turn report carries it into the
        // run's own narration, and the Director's next brief states it.
        case .agent, .preempted, nil: break
        }
        ensureRenderEndpointFromDisplay()   // safety net: a Director that declared a displayed output but
        return result                       // forgot ui_toggle_display still renders (mirrors the draft path)
    }

    /// Point the viewport at what this run just built — unless the Director's own
    /// `ui_toggle_display` already aimed it at one of this run's nodes. "Terminal" means it
    /// feeds NOTHING; a node built upstream of a live chain adopts nothing.
    private func adoptRunRenderEndpoint(_ run: SZRunState) {
        guard let graph = store.project?.graph else { return }
        if let endpoint = graph.renderEndpoint, run.workSet.contains(endpoint.node) { return }
        // Never adopt a STAGED piece — it is still hidden; its commit moves the endpoint.
        guard let ref = graph.runRenderEndpoint(workSet: run.workSet.subtracting(hiddenPieces)),
              graph.renderEndpoint != ref,
              store.setRenderEndpoint(ref) else { return }
        runtime?.setRenderEndpoint(ref)
        persistProject()
    }

    /// If no viewport endpoint is set but a node declared a `texture` output as `display`,
    /// point the viewport at it — so a Director-decomposed graph renders without a manual
    /// toggle. Pushes the change live + persists.
    private func ensureRenderEndpointFromDisplay() {
        guard let graph = store.project?.graph, graph.renderEndpoint == nil else { return }
        for node in graph.nodes {
            guard let port = node.contract?.outputs.first(where: { $0.display == true && $0.type == .texture }) else { continue }
            let ref = SZPortRef(node: node.id, port: port.name)
            guard store.setRenderEndpoint(ref) else { continue }
            runtime?.setRenderEndpoint(ref)
            persistProject()
            return
        }
    }

    // MARK: - Minting and admitting a run

    /// The door's scheduling effect and the mid-turn `ui_run` land here: SCHEDULE a task and
    /// knock. A task is never dropped for being second — it queues, and the pump admits it the
    /// moment its work set is free, ahead of any queued prose. Returns the task's id so the
    /// caller that minted it can withdraw it again (a stopped Director turn discards its own).
    @discardableResult
    func mintRun(instruction: String, title: String? = nil, nodes: Set<SZNodeID> = []) -> UUID {
        let task = SZTask(title: title ?? SZTask.title(fromInstruction: instruction, nodeCount: 0),
                          instruction: instruction, workSet: nodes)
        pendingTasks.append(task)
        admissionSuspended = false   // a new ask is the user acting again
        flushTaskQueue()
        pumpMailboxes()   // fires now if the work is free; else the next release re-fires
        // Narrate AFTER the pump, and only if the task is actually still waiting. Announcing
        // "queued" because something ELSE was running said the opposite of what this whole layer
        // does: with disjoint work sets the pump admits it in the same breath, and the "Run
        // started" line right below then contradicted it.
        if let ahead = pendingTasks.firstIndex(where: { $0.id == task.id }) {
            narrateDirector(ahead == 0
                ? "Queued — it starts when the work it needs is free."
                : "Queued behind \(ahead) other task\(ahead == 1 ? "" : "s").")
        }
        return task.id
    }

    /// Withdraw a scheduled task that has not been admitted. Returns false if it already started
    /// (or never existed) — a live task is stopped, not withdrawn.
    @discardableResult
    func withdrawTask(_ id: UUID) -> Bool {
        guard let index = pendingTasks.firstIndex(where: { $0.id == id }) else { return false }
        pendingTasks.remove(at: index)
        flushTaskQueue()
        return true
    }

    /// Fold more words into a task that has not started — what "I meant blue, not red" does to an
    /// ask still waiting its turn. The parts are kept whole and in order rather than replaced: the
    /// later words usually REFINE the earlier ones, and only the reader can tell which won.
    /// Refuses a task that is already running (that is a steer) or gone.
    @discardableResult
    func amendTask(_ id: UUID, with words: String) -> Bool {
        guard let index = pendingTasks.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if pendingTasks[index].instruction.isEmpty {
            pendingTasks[index].instruction = trimmed
        } else {
            pendingTasks[index].instruction += "\n\n" + trimmed
        }
        flushTaskQueue()
        return true
    }

    /// How a `startRun` attempt ended: `started` (the run is live), `waiting` (a transient
    /// claim holds the resources — retry on the next release), or `refused` (terminal — the
    /// reason was narrated once; retrying cannot help).
    enum RunStart { case started, waiting, refused }

    /// Pump head: admit every scheduled task that can claim what it needs. Structural ordering:
    /// admission runs before the prose scan, so a task always beats the next queued message to a
    /// freed resource. A `waiting` task keeps its place and retries QUIETLY on the next release;
    /// a terminal refusal is narrated once and leaves the queue — without that, every pump pass
    /// would replay it ("nothing to implement" forever, the provider sheet re-presenting per pass).
    func admitPendingTasks() {
        // Held after a Stop until the user acts again (see `cancelRun`).
        guard !admissionSuspended else { return }
        // Oldest first, and a task that must wait does NOT block the ones behind it: two asks over
        // disjoint nodes both start, overlapping ones queue behind the holder. A task that must
        // wait keeps its place quietly; a terminal refusal leaves the queue (retrying cannot help).
        var index = 0
        while index < pendingTasks.count {
            switch startRun(task: pendingTasks[index], narrateContention: false) {
            case .started, .refused: pendingTasks.remove(at: index)
            case .waiting: index += 1
            }
        }
        flushTaskQueue()
    }

    /// What a NEW run would take: the nodes dirty right now, minus the undescribed ones (an empty
    /// prompt is "undecided", not "build something"), minus the ones a run already holds — without
    /// that last subtraction every run computes the same set and only the first can ever claim it.
    /// `taken` is reported separately so a refusal can say "already being built" instead of
    /// "nothing to implement", which would be a lie.
    static func workSetCandidates(
        in nodes: [SZNode], excluding claimed: Set<SZNodeID>
    ) -> (work: Set<SZNodeID>, blank: Set<SZNodeID>, taken: Set<SZNodeID>) {
        let isBlank: (SZNode) -> Bool = {
            $0.kind == .prompt && ($0.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        let dirty = nodes.filter(\.needsImplementation)
        let blank = Set(dirty.filter(isBlank).map(\.id))
        let described = Set(dirty.map(\.id)).subtracting(blank)
        return (described.subtracting(claimed), blank, described.intersection(claimed))
    }

    /// Start a run over the current graph with the active provider (the Build press and
    /// `ui_run`'s direct entry). Runs are scoped by their WORK SET, not serialized: a second
    /// build over disjoint nodes starts alongside; one that overlaps waits for the holder.
    /// `narrateContention` quiets ONLY the transient claim-contention line — the admission
    /// path auto-retries that case, so per-attempt narration would be advice to a user who
    /// has nothing to do.
    @discardableResult
    func startRun(instruction: String = "", nodes: Set<SZNodeID> = [],
                  narrateContention: Bool = true,
                  adoptStagedGraphOp: Bool = false) -> RunStart {
        startRun(task: SZTask(title: SZTask.title(fromInstruction: instruction, nodeCount: 0),
                              instruction: instruction, workSet: nodes),
                 narrateContention: narrateContention,
                 adoptStagedGraphOp: adoptStagedGraphOp)
    }

    /// The HUD Build press. It goes through here rather than straight to `startRun` because a
    /// press is the user asking again, which releases a Stop's hold on the queue — otherwise a
    /// Build after a Stop leaves every standing task frozen for the rest of the session.
    func buildPressed() {
        admissionSuspended = false   // a press is the user asking again
        // SCHEDULED, not started directly: the pump admits it at once when the work is free, and
        // keeps it when it is not — a press whose nodes are momentarily held used to vanish.
        mintRun(instruction: "", title: SZTask.title(fromInstruction: "", nodeCount: pendingNodeCount))
    }

    /// Admit a SCHEDULED task: claim its work set and run it. The task carries the identity every
    /// per-run write is keyed by.
    @discardableResult
    func startRun(task: SZTask, narrateContention: Bool = true,
                  adoptStagedGraphOp: Bool = false) -> RunStart {
        let taskID = task.id
        let instruction = task.instruction
        // Land any prompt the user is mid-typing before we read the graph or claim a node.
        flushPendingPromptEdit()
        // Ownership of a staged op is ASKED FOR, never inferred. A run admitted from the queue
        // while someone else's op is staged must not adopt it (it would then suppress all of its
        // own run-end accounting) — so only `startOrJoinRun`, which stages, passes true. The old
        // test for this was `!isRunning`, host-wide: with concurrent builds ANY live run denied
        // ownership to the run actually implementing the pieces, and since nothing else drains,
        // the split stayed staged forever — pieces hidden, node pill stuck, every later
        // split/merge refused by the ghost.
        let startedForGraphOp = adoptStagedGraphOp && hasStagedGraphOp && graphOpClaim != nil
        guard let mcpPort = agentMCPServer?.port, let projectURL = loadedProjectURL else {
            // NOT-READY, not refused: print-only, and the slot survives — a mint that
            // raced project load fires when the pump next wakes with a project there.
            print("[SZHost] cannot run — MCP server or project not ready"); return .waiting
        }
        // This run's WORK SET candidates — the rule lives in `workSetCandidates`.
        let taken = runWorkSet
        var candidates = Self.workSetCandidates(in: store.project?.graph.nodes ?? [], excluding: taken)
        // A task that NAMES its nodes takes only those. This is what lets two asks about different
        // parts of the graph run at once: without it every run computes "everything dirty", the
        // first takes the lot, and the second has nothing left to be concurrent with.
        if !task.workSet.isEmpty {
            candidates = (work: candidates.work.intersection(task.workSet),
                          blank: candidates.blank.intersection(task.workSet),
                          taken: candidates.taken.intersection(task.workSet))
        }
        let implementable = candidates.work
        let blankIDs = candidates.blank
        // A task that NAMED its nodes and has none of them available must not run: an empty run
        // spends a Director turn to conclude there is nothing to do, and drops the ask on the
        // floor. Two different situations, two different answers.
        if !task.workSet.isEmpty, implementable.isEmpty {
            if !candidates.taken.isEmpty {
                // The work exists and is being built right now — WAIT for the holder. The task
                // stays queued and the holder's release re-fires the pump.
                status = "waiting for \(candidates.taken.count) node(s) another task is building"
                return .waiting
            }
            showChat()
            narrateDirector(blankIDs.isEmpty
                ? "Nothing to build there — that node is already built and current. Say what should change and I'll take it to its agent."
                : "That node has no prompt yet — describe what it should do, then build.")
            status = "nothing to build for that ask"
            return .refused
        }
        let dirty = candidates.work.union(candidates.blank).union(candidates.taken)
        // Nothing to implement, nothing asked → skip the run entirely (a full run would burn
        // a decompose turn to conclude "no work"). A run WITH an instruction still goes
        // through — the Director may CREATE work mid-run — and a staged split/merge always
        // runs: its pieces are the work.
        if implementable.isEmpty, instruction.isEmpty, !startedForGraphOp {
            showChat()
            if !candidates.taken.isEmpty {
                // Every dirty node belongs to a run already — say THAT, not "nothing to implement".
                status = "already building"
                narrateDirector("Everything that needs implementing is already being built.")
            } else if blankIDs.isEmpty {
                narrateDirector("Nothing to implement — every node is built and current.")
                status = "nothing to implement"
            } else {
                let n = blankIDs.count
                narrateDirector("\(n) node\(n == 1 ? " has" : "s have") no prompt yet — describe what \(n == 1 ? "it" : "each one") should do, then build. An empty node is left as-is, never guessed.")
                status = "describe the empty node\(n == 1 ? "" : "s")"
            }
            return .refused
        }
        // Pre-flight: a missing/logged-out CLI refuses with the setup sheet + remedy instead
        // of a silent generic run failure. Unknown health stays permissive.
        // Terminal for the admission path above all others: this "narration" is a SHEET.
        guard isProviderReadyForNewWork(activeProviderID) else {
            trackPromptSentTelemetry(scope: "build", providerID: activeProviderID, rejected: true)
            surfaceProviderNotReady(); return .refused
        }
        // The packs root: the materialized bundled packs, or the SZ_AGENT_PACKS override —
        // without a valid root the run refuses up front with one honest line.
        guard let packsRoot = Self.graphAgentPacksRoot() else {
            status = "no agent packs — materialization failed and no SZ_AGENT_PACKS override"
            narrateDirector("Run not started — no agent packs: the bundled packs did not "
                + "materialize and no valid SZ_AGENT_PACKS override is set.")
            return .refused
        }
        // The run loads the packs fresh from disk; the Plan panel's cache follows suit.
        agentGraphPlanCache = nil
        let providerID = activeProviderID
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "sz-agent-cache")
        // This run's WORK SET: the implementable nodes dirty at start. It grows as the run's
        // own tooling creates work (`noteRunCreatedWork`); a node the user adds mid-run never joins.
        let workSet = implementable
        // Claim ONLY what this run touches — atomically, refuse on contention.
        var claimSet: Set<SZResourceID> = []
        for id in workSet {
            claimSet.insert(.node(id))
            claimSet.insert(.transcript(.node(id)))
        }
        let claim = SZClaimToken(label: "run (\(providerID))")
        guard ledger.tryAcquire(claimSet, as: claim) else {
            let holders = ledger.blockers(of: claimSet).map(\.label).joined(separator: ", ")
            status = "cannot start run — \(holders) in flight"
            if narrateContention {
                narrateDirector("Run not started — \(holders) is still working. Wait for it to finish (or stop it), then build again.")
            }
            return .waiting
        }
        // The run's own state object — the claim IS its identity, and every write below goes to
        // THIS object, so a zombie can never touch a sibling's. The RUNS thread id is the build
        // traversal's own record id (its children share it), minted here so the opening narration
        // can carry it — that stamp is the transcript's durable way back once it scrolls away.
        let run = SZRunState(taskID: taskID, claim: claim, instruction: instruction,
                             ownsGraphOp: startedForGraphOp, workSet: workSet)
        activeRuns[taskID] = run
        let thread = run.thread
        status = "running \(providerID)…"
        showChat()                                           // a run narrates into the conversation
        let dirtyCount = run.workSet.count
        let startedID = narrateDirector(dirtyCount == 0
            ? "Run started (\(providerID)) — no nodes need implementing."
            : "Run started (\(providerID)) — implementing \(dirtyCount) node\(dirtyCount == 1 ? "" : "s")…")
        linkNarrationToRun(startedID, thread: thread)
        run.task = Task { @MainActor in
            defer {
                // The CAPTURED run, never a live lookup — after an eager `cancelRun` this is the
                // zombie task's idempotent second settle, and the slot may hold a newer run.
                if isLive(run) { sweepUnconsumedSteers(for: run) }
                ledger.releaseAll(of: claim)
                if isLive(run) {
                    activeRuns[taskID] = nil
                    // Only THIS run's dispatch prompts — a sibling run's are still live evidence.
                    dispatchPrompts = dispatchPrompts.filter {
                        !run.workSet.contains($0.key) || hiddenPieces.contains($0.key)
                    }
                }
                // Every traversal seals itself as its engine returns; this sweep is the belt
                // for an abnormal unwind, thread-scoped so a zombie can't touch a newer run's.
                sealLeakedAgentGraphRuns(thread: thread)
                flushAllTranscripts()      // run end = flush point (success, throw, or cancel)
                persistAgentSessions()
            }
            do {
                try await runBuildDelivery(
                    run: run, instruction: instruction, thread: thread, claim: claim,
                    packsRoot: packsRoot, providerID: providerID, mcpPort: mcpPort,
                    projectURL: projectURL, cacheDirectory: cacheDirectory)
                // Liveness-guarded as a whole: after a cancel-and-restart this task is a ZOMBIE,
                // and every line below reads or paints the run's nodes — accounting for, repainting
                // and narrating over work that is no longer this run's.
                if isLive(run) {
                    status = "agent run complete"
                    if !run.ownsGraphOp {
                        adoptRunRenderEndpoint(run)   // show what this run just built
                        let (done, failed) = surfaceUnresolvedNodes(run)
                        let narrationID = narrateDirector(
                            failed == 0
                                ? (done == 0 ? "Run complete." : "Run complete — \(done) node\(done == 1 ? "" : "s") implemented.")
                                : "Run finished — \(done) implemented, \(failed) failed. See the flagged node\(failed == 1 ? "" : "s").")
                        linkNarrationToRun(narrationID, thread: thread)
                        attachRunRollup(to: narrationID, run: run)
                    }
                }
            } catch is CancellationError {
                // A user Stop is not a failure: no red pills, no per-node "didn't finish" lines. This branch
                // runs SECONDS after `cancelRun` (the CLIs have to die first) and is therefore a zombie —
                // the run is already deregistered. `cancelRun` narrates and counts synchronously,
                // while the set is still ours; here we stay silent unless the run is somehow still
                // registered (a cancellation that did not come through `cancelRun`).
                if isLive(run) { status = "run cancelled" }
                print("[SZHost] agent run cancelled")
            } catch {
                // Guarded like the success branch: a zombie unwinding on a non-cancellation error
                // must not paint failure pills onto nodes another run is building.
                if isLive(run) {
                    status = "agent run failed: \(error)"
                    if !run.ownsGraphOp {
                        let (done, failed) = surfaceUnresolvedNodes(run)
                        let narrationID = narrateDirector("Run failed: \(error). \(done) implemented, \(failed) unfinished.")
                        linkNarrationToRun(narrationID, thread: thread)
                        attachRunRollup(to: narrationID, run: run)
                    }
                }
                print("[SZHost] agent run failed: \(error)")
            }
            // Settle a staged split/merge — on success, throw AND cancel, which is what makes a
            // cancelled op roll back instead of leak. ONLY the run that owns it: a sibling run
            // finishing first would settle (and usually roll back) an op whose pieces are still
            // being built, deleting nodes out from under another fleet.
            if run.ownsGraphOp { drainPendingGraphOp() }
        }
        // A Build is an ask without a chat bubble. (Residual: a run minted by a delivery restored
        // from disk after a crash also passes here — rare enough not to thread an origin through.)
        trackPromptSentTelemetry(scope: "build", providerID: providerID, rejected: false)
        return .started
    }

    // MARK: - The build delivery

    /// The run as ONE delivery: load + validate the library, build the director's delivery
    /// (its world minted with the run), and let the engine run the graph — the fleet is
    /// served through `deliverFleet` while the dispatch node waits.
    private func runBuildDelivery(
        run: SZRunState, instruction: String, thread: UUID, claim: SZClaimToken, packsRoot: URL,
        providerID: String, mcpPort: UInt16, projectURL: URL, cacheDirectory: URL
    ) async throws {
        let steps = SZHostStepRunning(packsRoot: packsRoot, runtime: stepRuntime)
        let loaded = SZAgentPackLoader.load(root: packsRoot)
        var defects = loaded.defects
        defects += await SZAgentPackLoader.validate(packs: loaded.packs, steps: steps)
        guard defects.isEmpty else {
            throw SZBuildRefused(detail: "the agent-pack library does not validate "
                + "(\(defects.count) defect\(defects.count == 1 ? "" : "s")):\n"
                + defects.map { "  · \($0)" }.sorted().joined(separator: "\n"))
        }
        guard let directorID = loaded.seats.director, let codingID = loaded.seats.coding,
              let directorPack = loaded.packs.first(where: { $0.id == directorID }),
              let codingPack = loaded.packs.first(where: { $0.id == codingID }),
              let directorGraph = directorPack.graph, let codingGraph = codingPack.graph else {
            throw SZBuildRefused(detail: "the seats did not resolve to graphs")
        }
        let directorAttachments = try await Self.attachments(of: directorPack, graph: directorGraph, steps: steps)
        let codingAttachments = try await Self.attachments(of: codingPack, graph: codingGraph, steps: steps)

        let renderer = SZBriefRenderer(packRoot: packsRoot)
        let generation = resolvedGenerationSettings(for: providerID)
        let router = SZIdentityRouter(choice: SZModelChoice(
            providerID: providerID, model: generation.model,
            reasoningEffort: generation.reasoningEffort))
        // ONE query service per run: every delivery's asks funnel through it.
        let queries = SZQueryService(renderer: renderer, router: router,
                                    cacheDirectory: cacheDirectory)

        // The run's live pieces the world closures and the fleet share.
        let state = BuildState()
        let roundCap = directorGraph.retryCap

        let sighting = SZTraversalSighting(id: thread, agent: directorID)
        beginAgentGraphRun(sighting, thread: thread)
        let delivery = SZDelivery(
            agent: directorID, message: "",
            renderer: renderer, queries: queries,
            world: { [weak self] in
                guard let self else { return SZWorld() }
                let graph = self.store.project?.graph
                let candidates = (graph?.nodes ?? []).filter(\.needsImplementation).map(\.id)
                // THIS run's work set, never the host-wide union: another live run's nodes are
                // not ours to dispatch to, and delivering to one would present a claim we do not
                // hold (deliver's holder guard would trip).
                let scoped = candidates.filter(run.workSet.contains)
                return SZWorld(
                    graph: graph, statuses: self.nodeStatusLines, node: nil,
                    resuming: self.agentSessions[SZChatScope.director.key] != nil,
                    run: SZRun(workSet: scoped, round: state.round, roundCap: roundCap,
                               steers: state.steers, instruction: instruction),
                    mutations: self.mutationJournal.entries(since: state.mutationCursor))
            },
            turn: { [weak self] order in
                guard let self else { return SZTurnReport(failed: true, detail: "the host is gone") }
                // The brief above was rendered against everything before this cursor; the next
                // Director brief lists what lands from here on (this turn's own edits included).
                state.mutationCursor = self.mutationJournal.count
                do {
                    let result = try await self.runDirectorTurn(
                        prompt: order.brief, session: order.session, providerID: providerID,
                        mcpPort: mcpPort, projectURL: projectURL, cacheDirectory: cacheDirectory,
                        claim: claim)
                    return SZTurnReport(failed: result.outcome.failed, detail: result.outcome.message)
                } catch {
                    return SZTurnReport(failed: true, detail: String(describing: error))
                }
            },
            effect: { [weak self] effect in await self?.perform(effect: effect) },
            onNote: { [weak self] note in
                self?.noteAgentGraphRun(thread, note)
                Self.appendGraphTrace([
                    "note": ["traversal": thread.uuidString, "ordinal": note.ordinal,
                             "node": note.node, "phase": "\(note.phase)",
                             "outcome": note.outcome ?? "",
                             "detail": note.detail ?? ""] as [String: Any],
                ])
            })
        delivery.fleet = { [weak self] orders, seat, progress in
            guard let self else { return nil }
            return await self.deliverFleet(
                run: run,
                orders: orders, seat: seat, progress: progress,
                state: state, thread: thread, claim: claim,
                coding: (codingID, codingGraph, codingAttachments),
                renderer: renderer, queries: queries, steps: steps, router: router,
                providerID: providerID, mcpPort: mcpPort,
                projectURL: projectURL, cacheDirectory: cacheDirectory)
        }
        let engine = SZGraphEngine(
            agent: directorID, graph: directorGraph, attachments: directorAttachments,
            host: delivery, steps: steps, router: router)
        let result = await engine.run()
        concludeAgentGraphRun(thread, SZTraversalEnding(result.conclusion))
        switch result.conclusion {
        case .ended: return
        case .cancelled: throw CancellationError()
        case .failed(_, let detail), .defect(_, let detail):
            throw SZBuildRefused(detail: detail)
        case .declined(_, let reason):
            throw SZBuildRefused(detail: "the director graph declined the work"
                + (reason.map { ": \($0)" } ?? ""))
        }
    }

    /// The run's live pieces the world closures and the fleet share: the set supervisor,
    /// the round the last set closed at, the steers drained while a fleet was out, and the
    /// mutation-journal cursor of the last Director turn.
    @MainActor
    final class BuildState {
        var supervisor = SZDispatchSupervisor(bounds: SZHost.dispatchSupervisorBounds())
        var round = 0
        var steers: [String] = []
        var pendingSteers: [String] = []
        /// The journal count at the last Director turn start — the reconcile brief's delta floor.
        var mutationCursor = 0
    }

    /// Declared outcomes per step node, attached at load — what the engine checks a step's
    /// answer against. Validation already proved every wired outcome is declared.
    private static func attachments(of pack: SZAgentPack, graph: SZAgentGraph,
                                    steps: SZHostStepRunning) async throws -> [String: SZStepAttachment] {
        var attached: [String: SZStepAttachment] = [:]
        for node in graph.nodes {
            guard case .step(let name) = node.form else { continue }
            if let info = try await steps.declaration(agent: pack.id, step: name) {
                attached[node.id] = SZStepAttachment(outcomes: Set(info.outcomes))
            }
        }
        return attached
    }

    // MARK: - The fleet (what the waiting dispatch awaits)

    /// One dispatch set, supervised end to end: the supervisor mints it, every order's
    /// child delivery runs concurrently, each landing feeds `workSettled`, and the
    /// watchdog races the group. Returns the set's one summary — or nil on stop, which the
    /// engine's cancellation boundary turns into `.cancelled`.
    private func deliverFleet(
        run: SZRunState,
        orders workOrders: [SZWorkOrder], seat: String,
        progress: @escaping @MainActor @Sendable (SZAgentGraphRun.Tally) -> Void,
        state: BuildState, thread: UUID,
        claim: SZClaimToken,
        coding: (id: String, graph: SZAgentGraph, attachments: [String: SZStepAttachment]),
        renderer: SZBriefRenderer, queries: SZQueryService, steps: SZHostStepRunning,
        router: SZIdentityRouter, providerID: String, mcpPort: UInt16,
        projectURL: URL, cacheDirectory: URL
    ) async -> SZSettledSummary? {
        // The Director's authored notes drained AT THE SEND, so a note authored during
        // the traversal rides the orders it aimed at.
        var notes: [String: String] = [:]
        for (node, text) in takeDirectorMessages(for: run) {
            notes[node.uuidString] = text
        }
        let minted = state.supervisor.handle(.dispatched(SZDispatchIntent(
            target: seat, items: workOrders.map(\.node), notes: notes)))
        var orders: [SZDispatchOrder] = []
        var deadline: Duration?
        var setID: Int?
        for command in minted {
            switch command {
            case .deliverItems(let id, _, let sent): setID = id; orders = sent
            case .armWatchdog(_, let after): deadline = after
            default: break
            }
        }
        guard let setID else {
            // An empty dispatch settles instantly and honestly rather than parking the run.
            return SZSettledSummary(setID: 0, from: seat, outcomes: [:],
                                    round: state.supervisor.round)
        }
        // Before the fleet runs, so a promoted node's setup sees a permission the Director
        // declared mid-run.
        if let project = store.project {
            await runtime?.requestDeclaredPermissions(for: project)
        }

        let generation = resolvedGenerationSettings(for: providerID)
        var deliveries: [(order: SZDispatchOrder, engine: SZGraphEngine?, sighting: UUID)] = []
        for order in orders {
            let sighting = UUID()
            guard let nodeID = SZNodeID(uuidString: order.node) else {
                deliveries.append((order, nil, sighting))
                continue
            }
            let scopeKey = SZChatScope.node(nodeID).key
            let child = SZDelivery(
                agent: coding.id, message: "",
                extras: SZBriefExtras(
                    preserveBehavior: hiddenPieces.contains(nodeID),
                    // Cold-start briefs inline the library index so a first dispatch spends
                    // no tool rounds fetching it; SZ_BRIEF_PREFETCH=0 reverts.
                    libraryIndex: ProcessInfo.processInfo.environment["SZ_BRIEF_PREFETCH"] == "0"
                        ? nil : SZHostBridge.libraryCategoriesBlock()),
                renderer: renderer, queries: queries,
                world: { [weak self] in
                    guard let self else { return SZWorld() }
                    return SZWorld(
                        graph: self.store.project?.graph, statuses: self.nodeStatusLines,
                        node: nodeID, resuming: self.agentSessions[scopeKey] != nil,
                        assignment: SZAssignment(attempt: order.attempt, note: order.senderNote))
                },
                turn: { [weak self] turnOrder in
                    guard let self else { return SZTurnReport(failed: true, detail: "the host is gone") }
                    let workingDirectory = cacheDirectory.appending(path: "agent/\(nodeID.uuidString)")
                    try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
                    let request = SZAgentRunRequest(
                        prompt: turnOrder.brief,
                        workingDirectory: workingDirectory,
                        packageDirectory: projectURL,
                        cacheDirectory: cacheDirectory,
                        mcpServerPort: mcpPort,
                        allowedMCPTools: SZHostBridge.agentCallableToolNames,
                        // `.resume` continues the node's own conversation (the reconcile
                        // resume); `.spawn` starts cold — a fresh run's first dispatch
                        // cold-starts by design.
                        resumeSessionID: turnOrder.session == .resume
                            ? self.agentSessions[scopeKey]?.sessionID : nil,
                        model: turnOrder.choice.model,
                        reasoningEffort: turnOrder.choice.reasoningEffort,
                        fastMode: generation.fastMode ?? false,
                        timeout: SZAgentTurnBudgets.codingTimeout,
                        inactivityTimeout: SZAgentTurnBudgets.codingInactivityTimeout)
                    guard let provider = SZProviderRegistry.shared.provider(id: turnOrder.choice.providerID) else {
                        return SZTurnReport(failed: true,
                                            detail: "unknown provider: \(turnOrder.choice.providerID)")
                    }
                    do {
                        let result = try await self.streamCodingAgent(
                            node: nodeID, request: request, provider: provider, claim: claim)
                        return SZTurnReport(failed: result.outcome.failed, detail: result.outcome.message)
                    } catch {
                        return SZTurnReport(failed: true, detail: String(describing: error))
                    }
                },
                effect: { [weak self] effect in await self?.perform(effect: effect) },
                onNote: { [weak self] note in self?.noteAgentGraphRun(sighting, note) })
            deliveries.append((order, SZGraphEngine(
                agent: coding.id, graph: coding.graph, attachments: coding.attachments,
                host: child, steps: steps, router: router), sighting))
        }
        enum Land: Sendable {
            case settled(node: String, outcome: String)
            case watchdog
        }
        var summary: SZSettledSummary?
        func absorb(_ commands: [SZDispatchSupervisor.Command]) {
            for command in commands {
                switch command {
                case .amendTally(_, let settled, let total, let failed):
                    // Relayed the moment each item lands — the dispatch card counts up
                    // while the fleet works.
                    progress(SZAgentGraphRun.Tally(settled: settled, total: total,
                                                   failed: failed))
                case .settled(let landed):
                    summary = landed
                    Self.appendGraphTrace([
                        "settled": ["set": landed.setID, "round": landed.round,
                                    "outcomes": landed.outcomes] as [String: Any],
                    ])
                case .deliverItems, .armWatchdog, .cancelItems:
                    break   // delivery/timers/cancellation live in this function's group
                }
            }
        }
        // Split the deliveries BEFORE the group: an order naming a non-node settles
        // instantly with the real reason; the rest become the group's children.
        var runnable: [(node: String, sighting: UUID, engine: SZGraphEngine)] = []
        for delivery in deliveries {
            let node = delivery.order.node
            absorb(state.supervisor.handle(.workDelivered(node: node, setID: setID)))
            if let engine = delivery.engine {
                beginAgentGraphRun(
                    SZTraversalSighting(id: delivery.sighting, agent: coding.id, work: node),
                    thread: thread)
                runnable.append((node, delivery.sighting, engine))
            } else {
                absorb(state.supervisor.handle(.workSettled(
                    node: node, setID: setID,
                    outcome: "defect: '\(node)' is not a node id")))
            }
        }
        func finish(_ summary: SZSettledSummary?) -> SZSettledSummary? {
            // The set is over: advance the run's world — the round the reconcile brief
            // states, and the steers its {{inbox}} folds — before the engine moves on.
            state.round = state.supervisor.round
            state.steers = state.pendingSteers
            state.pendingSteers = []
            return summary
        }
        if runnable.isEmpty {
            return finish(summary)
        }
        let children = runnable
        // Engines are MainActor; the group's children hop for each node step and park
        // off-actor for the long awaits (the provider).
        await withTaskGroup(of: Land.self) { group in
            for child in children {
                group.addTask { [weak self] in
                    // The engine is MainActor-isolated; the child hops for each node step
                    // and parks off-actor for the long awaits (the provider).
                    let result = await child.engine.run()
                    await self?.concludeAgentGraphRun(child.sighting, SZTraversalEnding(result.conclusion))
                    return .settled(node: child.node,
                                    outcome: Self.workOutcome(of: result.conclusion))
                }
            }
            if let deadline {
                group.addTask {
                    try? await Task.sleep(for: deadline)
                    // Fed even when cancelled at set closure — a closed set absorbs it.
                    return .watchdog
                }
            }
            for await land in group {
                // A stop: sweep the set and bail — the engine's cancellation boundary
                // owns the traversal's ending; no summary is synthesized.
                if Task.isCancelled {
                    absorb(state.supervisor.handle(.stopRequested))
                    group.cancelAll()
                    continue
                }
                // Steers the fleet raised while out (coding agents' messages to the
                // Director) fold into the run's NEXT brief — drained continuously.
                state.pendingSteers += takeDirectorInboxMessages()
                switch land {
                case .settled(let node, let outcome):
                    absorb(state.supervisor.handle(.workSettled(node: node, setID: setID,
                                                                outcome: outcome)))
                case .watchdog:
                    absorb(state.supervisor.handle(.watchdogFired(setID: setID)))
                }
                // The set closed (collected, synthesized, or stopped): cancel what
                // remains — the stragglers and the sleeping watchdog.
                if case .awaitingFleet = state.supervisor.state {} else { group.cancelAll() }
            }
        }
        return finish(summary)
    }

    /// A work traversal's conclusion as its terminal outcome string — the dispatch card's
    /// rule reads anything not `ok`-prefixed as a failure.
    private nonisolated static func workOutcome(of conclusion: SZTraversalConclusion) -> String {
        switch conclusion {
        case .ended: "ok"
        case .failed(_, let detail): "error: \(detail)"
        case .cancelled: "cancelled"
        case .declined(_, let reason): reason.map { "declined: \($0)" } ?? "declined"
        case .defect(_, let detail): "defect: \(detail)"
        }
    }

    /// One EFFECT a step requested with its outcome, landed on its host lane — after the
    /// step returned, before edge routing, already validated by the engine.
    func perform(effect: SZEffect) async {
        switch effect {
        case .requestBuild:
            // A bare effect carries no instruction; the mailbox's chat adapter passes the
            // user's message through its own effect closure instead.
            mintRun(instruction: "")
        }
    }

    /// The packs root: the `SZ_AGENT_PACKS` env override when set (an existing directory —
    /// set-but-invalid refuses rather than silently falling back), else the bundled packs'
    /// materialized, user-editable copy. nil = no packs anywhere.
    nonisolated static func graphAgentPacksRoot() -> URL? {
        let url: URL
        if let path = ProcessInfo.processInfo.environment["SZ_AGENT_PACKS"], !path.isEmpty {
            url = URL(filePath: path)
        } else {
            url = materializedAgentPacksRoot
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    /// The set supervisor's bounds. The per-set dispatch deadline mirrors the coding-turn
    /// budgets, so the watchdog can never fire before a healthy turn's own budget would
    /// have ended it.
    nonisolated static func dispatchSupervisorBounds() -> SZDispatchSupervisor.Bounds {
        SZDispatchSupervisor.Bounds(
            dispatchDeadline: .seconds(SZAgentTurnBudgets.codingTimeout
                + SZAgentTurnBudgets.codingInactivityTimeout))
    }

    /// One JSON line per graph-run event, under Application Support beside debug-turns —
    /// the RUNS records' debug shadow, off unless SZ_GRAPH_TRACE=1.
    static func appendGraphTrace(_ payload: [String: Any]) {
        guard ProcessInfo.processInfo.environment["SZ_GRAPH_TRACE"] == "1" else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let url = base.appending(path: "SubjectiveZero/graph-trace.jsonl")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }

    /// Cancel EVERY live run (the `Stop` HUD action, and `ui_stop`). Pending tasks stand: Stop
    /// ends what is running, it does not empty the queue.
    func cancelRun() {
        // Suspend FIRST. Each `cancelRun(_:)` releases its claim synchronously, and the ledger's
        // availability hook re-enters the pump — so a flag set afterwards arrives after the queue
        // has already started the next ask. A Stop must not be answered by more work.
        admissionSuspended = true
        // SNAPSHOT: `cancelRun(_:)` deregisters, and mutating the table while iterating its own
        // values leaves runs alive. Live-caught — Stop stopped one of two.
        for run in Array(activeRuns.values) { cancelRun(run) }
    }

    /// Cancel the run leading `thread` — how a single agent graph is interrupted from the strip or
    /// the bus, without touching the others. Returns false if it already ended.
    @discardableResult
    func cancelRun(thread: UUID) -> Bool {
        guard let run = activeRuns.values.first(where: { $0.thread == thread }) else { return false }
        cancelRun(run)
        return true
    }

    /// Cancel ONE run. Task cancellation propagates into the fleet's task group; nodes already
    /// promoted stay promoted.
    func cancelRun(_ run: SZRunState) {
        guard isLive(run) else { return }
        run.task?.cancel()
        // Eager release: composers and project ops unlock NOW, not when the cancelled task's
        // CLI agents finally die. The zombie task's deferred releaseAll of the same token is
        // an idempotent no-op; its still-streaming turns stay safe because the pump's
        // delivery precondition also checks the scope's in-flight marker.
        sweepUnconsumedSteers(for: run)
        // DEREGISTER FIRST. Releasing a claim re-enters the pump synchronously
        // (`onAvailabilityChanged` → `pumpMailboxes` → `admitPendingTasks`), and `startRun` asks
        // `runWorkSet` — the union over `activeRuns` — what is taken. With the dying run still in
        // that map, the one pump a single-run Stop generates answers `.waiting` for the very task
        // that was waiting on THESE nodes, and nothing pumps again afterwards. Deregistering also
        // stops anything else mistaking the zombie task for a live run.
        activeRuns[run.taskID] = nil
        // Settle a staged split/merge BEFORE the release too — leaving the op staged strands the
        // pieces, and settling it after the release would let a task admitted by that very release
        // claim pieces this rollback is about to delete. ONLY this run's: stopping one run must
        // not roll back the op a different, still-building run owns.
        if run.ownsGraphOp { drainPendingGraphOp() }
        ledger.releaseAll(of: run.claim)
        status = "run cancelled"
        // Count and narrate HERE, once: the cancelled task's own catch fires seconds later (the
        // CLIs must die first), and by then this run is gone. Everything this needs is live now.
        let unfinished = unfinishedRunNodeCount(run)
        let cancelledID = narrateDirector(unfinished == 0
            ? "Run cancelled."
            : "Run cancelled — \(unfinished) node\(unfinished == 1 ? "" : "s") unfinished.")
        linkNarrationToRun(cancelledID, thread: run.thread)
        clearInFlightPhasesAfterCancel(run)
        flushAllTranscripts()
        persistAgentSessions()
    }

    /// After a run, account for every work-set node from EVIDENCE — a promote that landed during the
    /// run plus the node's derived state now (`SZRunNodeVerdict`). Implemented nodes are silent unless
    /// they moved after their build, and shed any pill the host painted over them; a node its own AGENT
    /// explained keeps the agent's words; a failure the host recorded (a spent budget, a dead CLI) is the
    /// reason a node that built NOTHING gets, never a verdict on a build that landed. Only a node with no
    /// promote and no reason at all gets the generic line. Returns (implemented, failed) for the summary.
    @discardableResult
    func surfaceUnresolvedNodes(_ run: SZRunState) -> (implemented: Int, failed: Int) {
        var implemented = 0, failed = 0
        for id in run.workSet {                                                    // this run's captured work (grown)
            guard let node = store.project?.graph.node(id: id) else { continue }   // removed mid-run (merge)
            let verdict = SZRunNodeVerdict.classify(node: node, promoted: run.promoted.contains(id),
                                                    state: nodeAgentState[id])
            if verdict.isImplemented {
                implemented += 1
                retireHostFailure(id)   // no red pill on a node this run just counted built
            } else {
                failed += 1
            }
            switch verdict {
            case .implemented, .failedAsReported:
                break
            case .implementedButRebriefed:
                narrateDirector("\(node.title) was built, but its prompt changed mid-run — "
                    + "it needs a rebuild against the new intent.")
            case .implementedButContractMoved:
                narrateDirector("\(node.title) was built, but its ports changed after the build — "
                    + "it needs a rebuild against the current contract.")
            case .failedSourceMismatch:
                // The live audit is the detail (a cached one stands in if the source is unreadable) —
                // and its OWN words are the reason. The audit raises more than one fault (an undeclared
                // port name, an AV resource with no `setPaused`); a fixed sentence names the wrong one.
                if let audit = liveAuditErrors(id) { nodeAgentState[id, default: SZNodeAgentState()].errorDetail = audit }
                let reason = rebuildDetail(node: id).map { "the port audit flags it — \(Self.oneLineDetail($0))" }
                    ?? "it failed the port audit"
                recordRunFailure(node: id, fallback: reason)
                narrateDirector("\(node.title) was built, but \(reason). See the flagged node.")
            case .failedSilently:
                // A line the host already wrote (a dead provider, a spent budget) is a truer reason
                // than the generic one — and it is what the next run reads as this node's blocker.
                let recorded = nodeAgentState[id].flatMap {
                    $0.phase == .error && !$0.message.isEmpty ? $0.message : nil
                }
                let reason = recorded ?? "the agent never compiled this node or reported a blocker"
                recordRunFailure(node: id, fallback: reason)
                narrateDirector("\(node.title) didn't finish — \(reason).")
            }
        }
        return (implemented, failed)
    }

    /// A cancelled run's in-flight pills. `.queued`/`.planning`/`.coding` map to Planning/Building, and
    /// nothing else clears them once the run is gone — the node would wear a working pill forever. Return
    /// those work-set nodes to idle (back to Draft / Outdated); an agent that reported an error or a
    /// question keeps its say, exactly as at run end.
    func clearInFlightPhasesAfterCancel(_ run: SZRunState) {
        for id in run.workSet {
            guard let phase = nodeAgentState[id]?.phase,
                  phase == .queued || phase == .planning || phase == .coding else { continue }
            nodeAgentState[id]?.phase = .idle
            nodeAgentState[id]?.message = ""
        }
    }

    /// The work-set nodes a cancelled run left dirty — for the cancel narration only; touches nothing.
    private func unfinishedRunNodeCount(_ run: SZRunState) -> Int {
        run.workSet.reduce(0) { n, id in
            n + ((store.project?.graph.node(id: id)?.needsImplementation ?? false) ? 1 : 0)
        }
    }

    /// The ledger resources one agent turn on `scope` occupies: the transcript (one turn per
    /// scope), and for a node scope the node itself.
    static func turnResources(for scope: SZChatScope) -> Set<SZResourceID> {
        var resources: Set<SZResourceID> = [.transcript(scope)]
        if let node = scope.nodeID { resources.insert(.node(node)) }
        return resources
    }

    /// Human label for a turn's claim token — what deadlock/deadline/refusal diagnostics print.
    func turnLabel(for scope: SZChatScope) -> String {
        if let id = scope.nodeID {
            let title = store.project?.graph.node(id: id)?.title ?? String(id.uuidString.prefix(8))
            return "chat turn '\(title)'"
        }
        return "chat turn '\(scope.key)'"
    }

    /// Drain the queued `.steer` envelopes aimed at THIS RUN's nodes (mark processed) — folded
    /// into each node's retry order. Multiple steers to one node fold in FIFO order.
    ///
    /// Scoped to the run's work set because the mailbox is host-wide: an unscoped drain let the
    /// first run to dispatch consume and silently discard steers addressed to a concurrent run's
    /// nodes, which then never reached the agent they were written for.
    func takeDirectorMessages(for run: SZRunState) -> [SZNodeID: String] {
        var taken: [SZNodeID: [String]] = [:]
        for envelope in mailbox.envelopes where envelope.intent == .steer && envelope.state == .queued {
            guard let node = SZChatScope(key: envelope.recipient)?.nodeID,
                  run.workSet.contains(node) else { continue }
            taken[node, default: []].append(envelope.message.text)
            mailbox.markProcessed(envelope.id)
        }
        return taken.mapValues { $0.joined(separator: "\n\n") }
    }

    /// Drain the coding agents' queued `.steer` envelopes TO the Director — rendered into
    /// the next reconcile brief's `{{inbox}}`. FIFO.
    func takeDirectorInboxMessages() -> [String] {
        var taken: [String] = []
        for envelope in mailbox.envelopes where envelope.intent == .steer && envelope.state == .queued
            && envelope.recipient == SZChatScope.directorKey {
            taken.append(envelope.message.text)
            mailbox.markProcessed(envelope.id)
        }
        return taken
    }

    /// Fail the `.steer` envelopes still queued for THIS RUN when it ends (run-task defer AND
    /// eager cancel) — a steer is run-scoped: leaving it queued would leak a dead run's steering
    /// into an unrelated next run, and any `awaitProcessed` waiter must resume, not park forever.
    ///
    /// Scoped to the run's own nodes for the same reason the drain is: sweeping the host-wide
    /// mailbox meant one run ending destroyed every concurrent run's pending steering.
    func sweepUnconsumedSteers(for run: SZRunState) {
        for envelope in mailbox.envelopes where envelope.intent == .steer && envelope.state == .queued {
            guard let node = SZChatScope(key: envelope.recipient)?.nodeID,
                  run.workSet.contains(node) else { continue }
            mailbox.markFailed(envelope.id, reason: "run ended before the steer was consumed")
        }
    }
}

/// Why a turn failed, classified once for every lane (`SZHost.turnFailure`).
enum SZTurnFailure {
    /// OUR budget ran out — a plain warning in the turn's own words, never "provider error".
    case timedOut(String)
    /// The CLI died or is no longer ready — the actionable line (the setup sheet may have opened).
    case provider(String)
    /// An ordinary agent failure, in the words the turn already carries.
    case agent(String)
    /// The caller's `preempt` claimed it (the chat lane's stale-session retry) — it acts, no words here.
    case preempted
}

/// A run that could not do its job — the library refused, the seats did not resolve, or
/// the graph concluded on something other than `.ended`.
struct SZBuildRefused: Error, CustomStringConvertible {
    let detail: String
    var description: String { detail }
}
