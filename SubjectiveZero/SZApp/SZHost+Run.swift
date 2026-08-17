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
        let runTurn = claim != nil && claim == runClaim
        // The run identity is CAPTURED here: finalize re-checks it against the live run, so a
        // zombie turn settling after cancel-and-restart can't log itself into the new run.
        let turnRunID = runTurn ? runID : nil
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
            // A turn finishing off-screen marks its tab unread (static dot until visited).
            if scope.key != activeChatScope.key { unreadScopes.insert(scope.key) }
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
            openChatTab(scope)
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
        // Without this a second agent that dies silently still counts as implemented.
        promotedThisRun.remove(node)
        openChatTab(scope)
        // Under the run's CAPTURED claim (it holds every work-set node + transcript while live).
        // A cancelled run's zombie dispatch presents its released token; deliver detects that and
        // bows out instead of double-streaming into a scope someone else now owns.
        let result = try await deliver(scope: scope, request: request, provider: provider,
                                       claim: claim ?? runClaim).result
        // Land the provider's actual failure in this node's transcript — otherwise the real reason
        // (timeout, CLI error) is invisible and the node reads as a silent Draft.
        // A user Stop kills the CLI mid-turn: that is a choice, not a provider failure — no error
        // line for it (mirrors `providerFailureDetail`'s own guard).
        if result.outcome.failed, !Task.isCancelled {
            if result.process.timedOut {
                // Our budget ran out, not the provider's fault — a plain warning line.
                appendWarningLine(Self.turnFailureDetail(result), to: scope)
            } else if let providerDetail = await providerFailureDetail(result: result, provider: provider) {
                // A mid-turn provider death: the red pill carries the same actionable detail —
                // set BEFORE the run's end so `surfaceUnresolvedNodes` doesn't overwrite it.
                recordNodeStatus(node: node, phase: .error, message: providerDetail)
                appendProviderErrorLine(providerDetail, to: scope)
            } else {
                appendProviderErrorLine(Self.turnFailureDetail(result), to: scope)
            }
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
            resumeSessionID: session == .resume ? agentSessions[scope.key]?.sessionID : nil,
            model: generation.model, reasoningEffort: generation.reasoningEffort,
            fastMode: generation.fastMode ?? false,
            timeout: SZAgentTurnBudgets.codingTimeout,
            inactivityTimeout: SZAgentTurnBudgets.codingInactivityTimeout)
        // Under the CAPTURED claim like the fleet path — never the live `runClaim`: a zombie
        // director turn resuming after cancel-and-restart would otherwise adopt the NEW run's
        // claim, pass deliver's holder guard, and stream into a transcript someone else owns.
        let result = try await deliver(scope: scope, request: request, provider: provider,
                                       claim: claim ?? runClaim).result
        // The run re-reads the graph rather than the reply, so a mid-turn provider death
        // would otherwise vanish — land it in the Director tab like a coding turn's error line.
        if result.outcome.failed {
            if result.process.timedOut {
                appendWarningLine(Self.turnFailureDetail(result), to: scope)
            } else if let detail = await providerFailureDetail(result: result, provider: provider) {
                appendProviderErrorLine(detail, to: scope)
            }
        }
        ensureRenderEndpointFromDisplay()   // safety net: a Director that declared a displayed output but
        return result                       // forgot ui_toggle_display still renders (mirrors the draft path)
    }

    /// Point the viewport at what this run just built — unless the Director's own
    /// `ui_toggle_display` already aimed it at one of this run's nodes. "Terminal" means it
    /// feeds NOTHING; a node built upstream of a live chain adopts nothing.
    private func adoptRunRenderEndpoint() {
        guard let graph = store.project?.graph else { return }
        if let endpoint = graph.renderEndpoint, runWorkSet.contains(endpoint.node) { return }
        // Never adopt a STAGED piece — it is still hidden; its commit moves the endpoint.
        guard let ref = graph.runRenderEndpoint(workSet: runWorkSet.subtracting(hiddenPieces)),
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

    /// The door's `requestBuild` effect and the mid-turn `ui_run` land here: mint the run
    /// (the pending slot — a newer mint supersedes a queued one) and knock. The pump admits
    /// it the moment the director transcript frees — ahead of any queued prose, because
    /// admission runs at the head of every pump pass.
    func mintRun(instruction: String) {
        guard !isRunning else {
            narrateDirector("Build request skipped — a run is already active.")
            return
        }
        pendingRun = instruction
        pumpMailboxes()   // fires now if the transcript is free; else the next release re-fires
    }

    /// How a `startRun` attempt ended: `started` (the run is live), `waiting` (a transient
    /// claim holds the resources — retry on the next release), or `refused` (terminal — the
    /// reason was narrated once; retrying cannot help).
    enum RunStart { case started, waiting, refused }

    /// Pump head: admit the minted run the moment it can claim what it needs. Structural
    /// ordering: the run always beats the next queued Director message to the freed
    /// transcript. A `waiting` start keeps the slot and retries QUIETLY on the next
    /// release; a terminal refusal narrated once and clears the slot — without this,
    /// every pump pass would replay the refusal ("nothing to implement" forever, the
    /// provider sheet re-presenting per pass).
    func admitPendingRunIfPossible() {
        guard let instruction = pendingRun, !isRunning,
              ledger.holder(of: .transcript(.director)) == nil else { return }
        switch startRun(instruction: instruction, narrateContention: false) {
        case .started, .refused: pendingRun = nil
        case .waiting: break
        }
    }

    /// Start a run over the current graph with the active provider (the Build press and
    /// `ui_run`'s direct entry). One run at a time — the single choke point every entry
    /// shares; a second Build while one is live is refused by the claim.
    /// `narrateContention` quiets ONLY the transient claim-contention line — the admission
    /// path auto-retries that case, so per-attempt narration would be advice to a user who
    /// has nothing to do.
    @discardableResult
    func startRun(instruction: String = "", narrateContention: Bool = true) -> RunStart {
        guard !isRunning else { return .waiting }
        // Land any prompt the user is mid-typing before we read the graph or claim a node.
        flushPendingPromptEdit()
        // Was this run STARTED FOR a staged split/merge? Then it narrates at commit and owns the
        // hidden-piece UX. A plain run that a Director later stages an op inside still narrates itself.
        let ownsGraphOp = hasStagedGraphOp
        guard let mcpPort = agentMCPServer?.port, let projectURL = loadedProjectURL else {
            // NOT-READY, not refused: print-only, and the slot survives — a mint that
            // raced project load fires when the pump next wakes with a project there.
            print("[SZHost] cannot run — MCP server or project not ready"); return .waiting
        }
        // This run's WORK SET candidates: the nodes dirty right now. An undescribed prompt
        // node is NOT handed to the fleet — an empty prompt is "undecided", not "build
        // something"; only the coding work set excludes them.
        let nodes = store.project?.graph.nodes ?? []
        let dirty = Set(nodes.filter(\.needsImplementation).map(\.id))
        let isBlank: (SZNode) -> Bool = {
            $0.kind == .prompt && ($0.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        let blankIDs = Set(nodes.filter { $0.needsImplementation && isBlank($0) }.map(\.id))
        let implementable = dirty.subtracting(blankIDs)
        // Nothing to implement, nothing asked → skip the run entirely (a full run would burn
        // a decompose turn to conclude "no work"). A run WITH an instruction still goes
        // through — the Director may CREATE work mid-run — and a staged split/merge always
        // runs: its pieces are the work.
        if implementable.isEmpty, instruction.isEmpty, !ownsGraphOp {
            showChat(.director)
            if blankIDs.isEmpty {
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
        var claimSet: Set<SZResourceID> = [.run, .transcript(.director)]
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
        runClaim = claim   // `.steer` ack waits derive their consumer from the `.run` holder
        runWorkSet = workSet
        promotedThisRun = []    // evidence starts fresh — an off-run promote vouches for nothing here
        runStartedAt = Date()   // the rollup's wall-clock anchor
        runStartedMono = ContinuousClock.now
        runTurnLog = []
        runID = UUID()          // the run's trace identity (stamped into run-owned turns' events)
        status = "running \(providerID)…"
        showChat(.director)                                  // a run narrates into the Director Agent tab
        let dirtyCount = runWorkSet.count
        narrateDirector(dirtyCount == 0
            ? "Run started (\(providerID)) — no nodes need implementing."
            : "Run started (\(providerID)) — implementing \(dirtyCount) node\(dirtyCount == 1 ? "" : "s")…")
        // The RUNS thread id = the build traversal's own record id (its children share it).
        let thread = UUID()
        runTask = Task { @MainActor in
            defer {
                // Release the CAPTURED claim, not `runClaim` — after an eager `cancelRun` this is
                // the zombie task's idempotent second settle, and `runClaim` may already belong to
                // a newer run (guarded so we never clobber it).
                if runClaim == claim { sweepUnconsumedSteers() }
                ledger.releaseAll(of: claim)
                if runClaim == claim {
                    runClaim = nil
                    runTask = nil
                    runWorkSet = []        // run over → the work set is cleared
                    runStartedAt = nil
                    runStartedMono = nil
                    runTurnLog = []
                    runID = nil
                    dispatchPrompts = dispatchPrompts.filter { hiddenPieces.contains($0.key) }
                    promotedThisRun = []
                }
                // Every traversal seals itself as its engine returns; this sweep is the belt
                // for an abnormal unwind, thread-scoped so a zombie can't touch a newer run's.
                sealLeakedAgentGraphRuns(thread: thread)
                flushAllTranscripts()      // run end = flush point (success, throw, or cancel)
                persistAgentSessions()
            }
            do {
                try await runBuildDelivery(
                    instruction: instruction, thread: thread, claim: claim,
                    packsRoot: packsRoot, providerID: providerID, mcpPort: mcpPort,
                    projectURL: projectURL, cacheDirectory: cacheDirectory)
                status = "agent run complete"
                if !ownsGraphOp {
                    adoptRunRenderEndpoint()   // show what this run just built
                    let (done, failed) = surfaceUnresolvedNodes()
                    let narrationID = narrateDirector(
                        failed == 0
                            ? (done == 0 ? "Run complete." : "Run complete — \(done) node\(done == 1 ? "" : "s") implemented.")
                            : "Run finished — \(done) implemented, \(failed) failed. See the flagged node\(failed == 1 ? "" : "s").")
                    // Claim-guarded like the per-run state: a zombie narrating after cancel-and-
                    // restart must not fold the NEW run's live log onto its own narration.
                    if runClaim == claim { attachRunRollup(to: narrationID) }
                }
            } catch is CancellationError {
                // A user Stop is not a failure: no red pills, no per-node "didn't finish" lines. This branch
                // runs SECONDS after `cancelRun` (the CLIs have to die first) and is therefore a zombie —
                // `runWorkSet` and `status` may already belong to a NEWER run. `cancelRun` narrates and
                // counts synchronously, while the set is still ours; here we stay silent unless the claim
                // is somehow still held (a cancellation that did not come through `cancelRun`).
                if runClaim == claim { status = "run cancelled" }
                print("[SZHost] agent run cancelled")
            } catch {
                status = "agent run failed: \(error)"
                if !ownsGraphOp {
                    let (done, failed) = surfaceUnresolvedNodes()
                    let narrationID = narrateDirector("Run failed: \(error). \(done) implemented, \(failed) unfinished.")
                    if runClaim == claim { attachRunRollup(to: narrationID) }
                }
                print("[SZHost] agent run failed: \(error)")
            }
            // Settle a staged split/merge — runs on success, throw AND cancel, which is what
            // makes a cancelled op roll back instead of leak.
            drainPendingGraphOp()
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
        instruction: String, thread: UUID, claim: SZClaimToken, packsRoot: URL,
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
                let scoped = candidates.filter(self.runWorkSet.contains)
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
        for (node, text) in takeDirectorMessages() {
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

    /// Cancel the in-flight run (the `Stop` HUD action). Task cancellation propagates into
    /// the fleet's task group; nodes already promoted stay promoted.
    func cancelRun() {
        runTask?.cancel()
        runTask = nil
        // Eager release: composers and project ops unlock NOW, not when the cancelled task's
        // CLI agents finally die. The zombie task's deferred releaseAll of the same token is
        // an idempotent no-op; its still-streaming turns stay safe because the pump's
        // delivery precondition also checks the scope's in-flight marker.
        if let claim = runClaim {
            sweepUnconsumedSteers()
            ledger.releaseAll(of: claim)
            runClaim = nil
        }
        status = "run cancelled"
        // Count and narrate HERE, once: the cancelled task's own catch fires seconds later (the CLIs
        // must die first), by which time `runWorkSet` can already be a newer run's — its narration
        // would land under that run's start line. Everything this needs is live right now.
        let unfinished = unfinishedRunNodeCount()
        narrateDirector(unfinished == 0
            ? "Run cancelled."
            : "Run cancelled — \(unfinished) node\(unfinished == 1 ? "" : "s") unfinished.")
        clearInFlightPhasesAfterCancel()
        // Settle a staged split/merge NOW rather than waiting on the cancelled task —
        // leaving the op staged strands the pieces. The drain is idempotent.
        drainPendingGraphOp()
        flushAllTranscripts()
        persistAgentSessions()
    }

    /// After a run, account for every work-set node from EVIDENCE — a promote that landed during the
    /// run plus the node's derived state now (`SZRunNodeVerdict`). Implemented nodes are silent unless
    /// they moved after their build; a node its agent already explained keeps the agent's words; only a
    /// silent, unpromoted node gets the generic line. Returns (implemented, failed) for the run summary.
    @discardableResult
    func surfaceUnresolvedNodes() -> (implemented: Int, failed: Int) {
        var implemented = 0, failed = 0
        for id in runWorkSet {                                                     // this run's captured work (grown)
            guard let node = store.project?.graph.node(id: id) else { continue }   // removed mid-run (merge)
            let verdict = SZRunNodeVerdict.classify(
                promoted: promotedThisRun.contains(id), stillDirty: node.needsImplementation,
                derivedReason: node.rebuildReason, phase: nodeAgentState[id]?.phase ?? .idle)
            if verdict.isImplemented { implemented += 1 } else { failed += 1 }
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
                // The live audit is the detail (a cached one stands in if the source is unreadable).
                if let audit = liveAuditErrors(id) { nodeAgentState[id, default: SZNodeAgentState()].errorDetail = audit }
                let reason = "its source reads ports the contract doesn't declare"
                recordRunFailure(node: id, fallback: reason)
                narrateDirector("\(node.title) was built, but \(reason) — see the flagged node.")
            case .failedSilently:
                let reason = "the agent never compiled this node or reported a blocker"
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
    func clearInFlightPhasesAfterCancel() {
        for id in runWorkSet {
            guard let phase = nodeAgentState[id]?.phase,
                  phase == .queued || phase == .planning || phase == .coding else { continue }
            nodeAgentState[id]?.phase = .idle
            nodeAgentState[id]?.message = ""
        }
    }

    /// The work-set nodes a cancelled run left dirty — for the cancel narration only; touches nothing.
    private func unfinishedRunNodeCount() -> Int {
        runWorkSet.reduce(0) { n, id in
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

    /// Drain the Director's queued `.steer` envelopes to nodes (mark processed) — folded
    /// into each node's retry order. Multiple steers to one node fold in FIFO order.
    func takeDirectorMessages() -> [SZNodeID: String] {
        var taken: [SZNodeID: [String]] = [:]
        for envelope in mailbox.envelopes where envelope.intent == .steer && envelope.state == .queued {
            guard let node = SZChatScope(key: envelope.recipient)?.nodeID else { continue }
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

    /// Fail every `.steer` still queued when its run ends (run-task defer AND eager cancel) —
    /// a steer is run-scoped: leaving it queued would leak a dead run's steering into an
    /// unrelated next run, and any `awaitProcessed` waiter must resume, not park forever.
    func sweepUnconsumedSteers() {
        for envelope in mailbox.envelopes where envelope.intent == .steer && envelope.state == .queued {
            mailbox.markFailed(envelope.id, reason: "run ended before the steer was consumed")
        }
    }
}

/// A run that could not do its job — the library refused, the seats did not resolve, or
/// the graph concluded on something other than `.ended`.
struct SZBuildRefused: Error, CustomStringConvertible {
    let detail: String
    var description: String { detail }
}
