// SPDX-License-Identifier: AGPL-3.0-only
// Director-run orchestration — the `ui_run` entry point and the host capabilities a strategy
// sequences: contract drafting/pinning, the shared agent-turn substrate (`deliver`), per-node coding
// turns + the Director turn streamed into their tabs, the orchestration context that bundles them, and
// the post-run reconcile/surfacing.
import Foundation
import SZAI
import SZCore

extension SZHost {
    /// Contract-first authorship: before a run, give every contract-less DRAWN prompt node a texture
    /// contract derived from its flow edges + lay the companion data wiring (`SZGraph.draftContractsFromFlow`),
    /// so the cards show their typed I/O UPFRONT and the textures bind as the fleet implements — the graph
    /// "comes to life". Persists + reloads so the new boundary is live; `pinDirtyContracts` (called next)
    /// then pins these freshly-drafted contracts. No-op when nothing needs drafting (every dirty node already
    /// ships a contract — a re-run, split/merge pieces), so it adds no cost to those paths.
    private func draftFlowContracts() {
        guard let graph = store.project?.graph else { return }
        let (drafted, ids) = graph.draftContractsFromFlow()
        guard !ids.isEmpty else { return }
        store.mutate { $0.graph = drafted }
        persistGraphEditAndReload(action: "drafted \(ids.count) node contract\(ids.count == 1 ? "" : "s") from flow")
    }

    /// Snapshot the declared typed boundary of every dirty node that already SHIPS a contract, so
    /// `promoteStagedNode` re-pins its ports' type/ui/default + permissions over whatever the agent
    /// authors. Covers a normal node re-implemented by its Coding Agent, split/merge pieces (their
    /// host-drafted boundary), AND contract-first drawn nodes (just drafted by `draftFlowContracts`).
    /// Called at `startRun`; cleared at run end.
    private func pinDirtyContracts() {
        for node in store.project?.graph.nodes ?? [] where node.needsImplementation {
            if let contract = node.contract { pinnedContracts[node.id] = contract }
        }
    }

    /// The shared agent-turn substrate. Every agent turn — a coding dispatch, a Director turn,
    /// a user chat — funnels through here: append an empty assistant message to `scope`, mark the turn in
    /// flight (the chat panel's working dots), stream the provider's turn into that scope's tab, record its
    /// duration, and (by default) remember the resulting session for chat-resume. Returns the result plus
    /// the assistant message id so a caller can post-process the reply (e.g. the chat empty-text fallback).
    ///
    /// One substrate for `streamCodingAgent`, `runDirectorTurn`, and `sendChat`.
    /// NOTE (deferred — seams earned, not scheduled): the per-scope *async queue / mailbox* (`post`/`drain`
    /// for arbitrary mid-run interjection) is intentionally NOT built yet — its only consumer would be
    /// mid-run user messaging. Per-scope serialization today is the `chatInFlight` gate; TODO: add the
    /// mailbox when mid-run user messaging lands. See docs/AGENT_ORCHESTRATION.md "Cross-agent messaging".
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
            // turns in one transcript and clobber its in-flight marker. Bow out; the strategy
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
        let started = Date()
        defer {
            if let selfClaim { ledger.releaseAll(of: selfClaim) }
            // Ownership-checked: if a later turn overwrote this scope's marker (a race this guard
            // is the last line of defense against), leave THEIRS in place — nilling it would let a
            // flush persist their half-streamed reply.
            if inFlightAssistantIDs[scope.key] == assistantID { inFlightAssistantIDs[scope.key] = nil }
            store.setChatDuration(Date().timeIntervalSince(started), assistantID, in: scope)
            // A turn finishing off-screen marks its tab unread (static dot until visited).
            if scope.key != activeChatScope.key { unreadScopes.insert(scope.key) }
            // Turn end = flush point: the just-completed message (no longer in-flight) lands on disk,
            // and whatever this turn did to the session map is persisted machine-locally.
            flushTranscript(scope)
            persistAgentSessions()
        }
        let result = try await streamAgentTurn(provider: provider, request: request, into: scope, message: assistantID)
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
        return (result, assistantID)
    }

    /// Run one coding agent's turn during a Director run and stream it into that node's Coding Agent tab
    /// — the `SZCodingTurnRunner` injected via `SZOrchestrationContext`. Opens the node's tab (without
    /// stealing the active tab — a run watches the Director tab), marks the turn in flight (the chat
    /// panel's working dots), then streams the agent's activity+reply via `streamAgentTurn`. The node's
    /// editor pill/lock is already covered by the per-node run rule (`isRunning` + still `.prompt` —
    /// see `isLocked` in `SZNodeEditorPanel`), so this doesn't touch `isChatting`.
    @MainActor
    func streamCodingAgent(
        node: SZNodeID, request: SZAgentRunRequest, provider: any SZProvider,
        claim: SZClaimToken? = nil
    ) async throws -> SZAgentRunResult {
        let scope = SZChatScope.node(node)
        // Debug test affordance: force this node to fail its first dispatch once — report `needsInput`
        // and throw WITHOUT running an agent (the strategy's `code` catches a throwing turn and leaves the
        // node unresolved) — so the reconcile loop fires live & repeatably (`debug_fail_node_once`).
        if let blocker = forcedFailNodes.removeValue(forKey: node) {
            openChatTab(scope)
            store.appendChatMessage(SZChatMessage(role: .assistant,
                text: "(debug) forced needsInput — skipping implementation this attempt to exercise the reconcile loop."), to: scope)
            recordNodeStatus(node: node, phase: .needsInput, message: blocker)
            throw SZMCPError.message("(debug) forced needsInput: \(blocker)")
        }
        openChatTab(scope)
        // Under the run's CAPTURED claim (it holds every work-set node + transcript while live).
        // A cancelled run's zombie dispatch presents its released token; deliver detects that and
        // bows out instead of double-streaming into a scope someone else now owns.
        let result = try await deliver(scope: scope, request: request, provider: provider,
                                       claim: claim ?? runClaim).result
        // Land the provider's actual failure in this node's transcript — otherwise the real reason
        // (timeout, CLI error) is invisible and the node reads as a silent Draft. `deliver` already
        // streamed the turn into `scope`; this adds the terminal error line beneath it.
        if result.outcome.failed {
            let detail: String
            if result.process.timedOut {
                // A timeout (exit 124) carries no provider message — name it explicitly instead of the
                // generic "failure with no message", and surface the budget so the cause is legible.
                let budget = request.timeout.map { $0 >= 60 ? " after \(Int($0 / 60))m" : " after \(Int($0))s" } ?? ""
                detail = "the agent timed out\(budget) without finishing — the task may be too large for one turn (try splitting it up or allowing a longer budget)"
            } else if let providerDetail = await providerFailureDetail(result: result, provider: provider) {
                // A mid-turn provider death: the red pill carries the same actionable detail —
                // set BEFORE the run's end so `surfaceUnresolvedNodes` (still-`.prompt` only)
                // doesn't overwrite it with its generic never-compiled line.
                detail = providerDetail
                recordNodeStatus(node: node, phase: .error, message: detail)
            } else {
                detail = result.outcome.message ?? "the provider reported a failure with no message"
            }
            appendProviderErrorLine(detail, to: scope)
        }
        return result
    }

    /// The terminal "⚠️ Provider error:" line beneath a streamed turn — one composer for the
    /// run-path scopes; the flush lands it after `deliver`'s turn-end flush. (The chat path
    /// appends into its existing assistant bubble instead of a fresh message, so it composes
    /// its own copy of the prefix.)
    @MainActor
    func appendProviderErrorLine(_ detail: String, to scope: SZChatScope) {
        store.appendChatMessage(SZChatMessage(role: .assistant, text: "⚠️ Provider error: \(detail)"), to: scope)
        flushTranscript(scope)
    }

    /// Run one Director Agent turn — spawn the active provider with the MCP server attached and the
    /// rendered Director prompt, streamed live into the Director tab, so the user watches it establish each
    /// node's typed contract + wiring via `ui_*`. Remembers the Director session so the user can chat-resume
    /// it. Injected into the orchestration context as `directorTurn`; the agentic strategy calls it
    /// before dispatch, then re-reads the graph it shaped.
    @MainActor
    func runDirectorTurn(
        prompt: String, providerID: String, mcpPort: UInt16, projectURL: URL, cacheDirectory: URL
    ) async throws -> SZAgentRunResult {
        guard let provider = SZProviderRegistry.shared.provider(id: providerID) else {
            throw SZOrchestratorError.unknownProvider(providerID)
        }
        let scope = SZChatScope.director
        let workingDirectory = cacheDirectory.appending(path: "agent/director")
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let generation = resolvedGenerationSettings(for: providerID)
        let request = SZAgentRunRequest(
            prompt: prompt, workingDirectory: workingDirectory, packageDirectory: projectURL,
            cacheDirectory: cacheDirectory, mcpServerPort: mcpPort,
            model: generation.model, reasoningEffort: generation.reasoningEffort,
            fastMode: generation.fastMode ?? false, timeout: 300)
        let result = try await deliver(scope: scope, request: request, provider: provider,
                                       claim: runClaim).result
        // The agentic strategy discards the Director result (it re-reads the graph instead), so a
        // mid-turn provider death would otherwise vanish — land it in the Director tab like a
        // coding turn's terminal error line.
        if result.outcome.failed, let detail = await providerFailureDetail(result: result, provider: provider) {
            appendProviderErrorLine(detail, to: scope)
        }
        ensureRenderEndpointFromDisplay()   // safety net: a Director that declared a displayed output but
        return result                       // forgot ui_toggle_display still renders (mirrors the draft path)
    }

    /// Point the viewport at what this run just built. You asked for a node; you should see it — the
    /// endpoint staying on an unrelated node it happened to already hold is the wrong default.
    ///
    /// The Director's own `ui_toggle_display` wins: if it already aimed the viewport at one of this run's
    /// nodes, it knows the graph's shape better than this does. Otherwise take the run's terminal node —
    /// furthest downstream, tie-broken by newest.
    ///
    /// "Terminal" means it feeds NOTHING, not merely nothing else in the run. A node built upstream of an
    /// existing composite (a blur spliced into a live chain) is the run's last node but not the graph's
    /// output, and stealing the viewport for it would hide the very result it feeds. Such a run adopts
    /// nothing and leaves the endpoint where the user put it.
    private func adoptRunRenderEndpoint() {
        guard let graph = store.project?.graph else { return }
        if let endpoint = graph.renderEndpoint, runWorkSet.contains(endpoint.node) { return }
        // Never adopt a STAGED piece: `promoteStagedNode` marks it `.generated` while it is still hidden, so
        // a run that staged a graph op mid-flight would otherwise point the viewport at a card the user
        // cannot see. Its commit moves the endpoint, once the piece is revealed.
        guard let ref = graph.runRenderEndpoint(workSet: runWorkSet.subtracting(hiddenPieces)),
              graph.renderEndpoint != ref,
              store.setRenderEndpoint(ref) else { return }
        runtime?.setRenderEndpoint(ref)
        persistProject()
    }

    /// If no viewport endpoint is set but a node declared a `texture` output as `display`, point the
    /// viewport at it — so a Director-decomposed graph renders without a manual toggle (the agentic
    /// counterpart of `draftContractsFromFlow`'s endpoint inference). Pushes the change live + persists.
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

    /// Build the orchestration context for a run — bundles the host capabilities a strategy sequences:
    /// stream each coding turn into its node's tab, draft/pin contracts, run a Director turn (agentic),
    /// read node status + drain Director messages (reconcile). Each is captured weakly so a torn-down
    /// host degrades gracefully. Kept separate from `startRun` so its run body reads as build-context → run.
    private func makeOrchestrationContext(
        providerID: String, mcpPort: UInt16, projectURL: URL, cacheDirectory: URL,
        instruction: String, directorAlreadyBriefed: Bool, claim: SZClaimToken
    ) -> SZOrchestrationContext {
        SZOrchestrationContext(
            providerID: providerID,
            // Resolved once here — every coding agent this run launches with the user's selection
            // (the Director turn resolves its own inside runDirectorTurn).
            generationSettings: resolvedGenerationSettings(for: providerID),
            store: store, mcpPort: mcpPort,
            projectURL: projectURL, cacheDirectory: cacheDirectory,
            // Stream each coding agent's output into its node's Coding Agent tab, under THIS run's
            // claim (captured, not read live: after a cancel, a zombie dispatch must present its
            // own released token — which deliver detects — never a NEWER run's live claim).
            turnRunner: { [weak self] node, request, provider in
                guard let self else { return try await provider.run(request) }
                return try await self.streamCodingAgent(node: node, request: request,
                                                        provider: provider, claim: claim)
            },
            // A chat-triggered run carries the user's words into the decompose prompt — unless the
            // Director's own chat turn requested it, in which case that turn WAS the decompose.
            instruction: instruction, directorAlreadyBriefed: directorAlreadyBriefed,
            // Host capabilities the strategy sequences: contract-first drafting (procedural),
            // pinning (both), and one Director Agent turn (agentic), each streamed/persisted by the host.
            draftContracts: { [weak self] in self?.draftFlowContracts() },
            pinContracts: { [weak self] in self?.pinDirtyContracts() },
            // Grant any entitlement the live graph now declares before the fleet runs — covers a
            // permission the Director introduced mid-run (only those at initial load were pre-granted in
            // `start`), so a node's `setup()` sees it authorized on the promote-reload (e.g. microphone).
            grantPermissions: { [weak self] in
                guard let self, let project = self.store.project else { return }
                await self.runtime?.requestDeclaredPermissions(for: project)
            },
            directorTurn: { [weak self] prompt in
                guard let self else { throw SZOrchestratorError.noProject }
                return try await self.runDirectorTurn(
                    prompt: prompt, providerID: providerID, mcpPort: mcpPort,
                    projectURL: projectURL, cacheDirectory: cacheDirectory)
            },
            // The coding agents' reported status, so the agentic strategy can assess unresolved
            // nodes and reconcile after dispatch.
            nodeStatus: { [weak self] in self?.nodeStatusLines ?? [:] },
            // The Director's during-run messages to nodes (its `ui_send_chat`-to-a-node calls),
            // drained by the reconcile loop and folded into each node's retry.
            takeDirectorMessages: { [weak self] in self?.takeDirectorMessages() ?? [:] },
            // The coding agents' during-run messages TO the Director, rendered into the next
            // reconcile turn's prompt.
            takeDirectorInbox: { [weak self] in self?.takeDirectorInboxMessages() ?? [] },
            // This run's captured work set — read LIVE (each dispatch/reconcile round) so Director- and
            // split/merge-added nodes join it; a user's mid-run draft never does. Host alive ⇒ non-nil
            // authoritative scope (even empty); nil only with no host (tests) ⇒ strategy sees all prompt nodes.
            workSet: { [weak self] in self?.runWorkSet },
            // Read live: the Director can stage a split/merge mid-run, and those pieces' coding agents must
            // be told to preserve the original's behavior rather than browse the library.
            stagedPieces: { [weak self] in self?.hiddenPieces ?? [] })
    }

    /// Start a Director run over the current graph with the active provider (the `ui_run` entry point).
    /// The orchestrator processes dirty (prompt) nodes; agents write+compile back through the MCP server,
    /// so this await keeps the MainActor free to service their callbacks. `onComplete` (if given) runs on
    /// the MainActor after the run finishes — split/merge use it to commit the structural swap.
    /// `instruction` steers the run's decompose turn; `directorAlreadyBriefed` marks a run the
    /// Director Agent's own chat turn requested (`ui_run` mid-turn → fired at turn end), which
    /// skips the decompose turn — that chat turn already did the job (see SZOrchestrationContext).
    func startRun(instruction: String = "", directorAlreadyBriefed: Bool = false) {
        // One run at a time — the single choke point every entry shares (Build button, `ui_run`,
        // split/merge, a Director turn's queued run). Without this a second UI-driven start would
        // orphan the first `runTask` and let two orchestrators mutate the graph concurrently.
        guard !isRunning else { return }
        // Was this run STARTED FOR a staged split/merge? Then it narrates at commit and owns the
        // hidden-piece UX. A plain run that a Director later stages an op inside still narrates itself.
        let ownsGraphOp = hasStagedGraphOp
        guard let mcpPort = agentMCPServer?.port, let projectURL = loadedProjectURL else {   // agents dial the debug-free bus
            print("[SZHost] cannot run — MCP server or project not ready"); return
        }
        // This run's WORK SET candidates: the nodes dirty right now (never built, or built against a
        // contract/intent that has since moved). Computed before the run flips live so an empty one can
        // answer without an orchestrator.
        let dirty = Set((store.project?.graph.nodes ?? []).filter(\.needsImplementation).map(\.id))
        // Nothing to implement, nothing asked → skip the strategy entirely: a full run here would still
        // burn a Director decompose turn (latency + tokens) to conclude "no work". A run WITH an
        // `instruction` or a Director-briefed one still goes through — the Director may CREATE work
        // mid-run (contracts, nodes) — and a staged split/merge always runs: its pieces are the work and
        // its commit rides the run task's drain.
        if dirty.isEmpty, instruction.isEmpty, !directorAlreadyBriefed, !ownsGraphOp {
            showChat(.director)
            narrateDirector("Nothing to implement — every node is built and current.")
            status = "nothing to implement"
            return
        }
        // Pre-flight: a missing/logged-out CLI refuses with the setup sheet + remedy instead of
        // the old silent generic run failure (roadmap Task 2). Unknown health stays permissive.
        guard isProviderReadyForNewWork(activeProviderID) else {
            surfaceProviderNotReady(); return
        }
        let providerID = activeProviderID
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "sz-agent-cache")
        // This run's WORK SET: the prompt nodes dirty at start (`dirty`, computed above for the
        // no-op fast-path). It grows as the run's own tooling creates work (`noteRunCreatedWork`),
        // and drives dispatch, the editor lock/pill, and the `ui_connect` guard. A node the user
        // adds mid-run is never noted, so it stays out of the fleet.
        let workSet = dirty
        // Claim ONLY what this run touches — atomically, refuse on contention (today's refuse-a-
        // second-run semantics; an awaited acquire would let a second Build queue behind the first
        // while `isRunning` still reads false). The claim also closes a latent race: previously
        // nothing stopped a run while a chat turn streamed into a work-set node's transcript.
        var claimSet: Set<SZResourceID> = [.run, .transcript(.director)]
        for id in workSet {
            claimSet.insert(.node(id))
            claimSet.insert(.transcript(.node(id)))
        }
        let claim = SZClaimToken(label: "run (\(providerID))")
        guard ledger.tryAcquire(claimSet, as: claim) else {
            let holders = ledger.blockers(of: claimSet).map(\.label).joined(separator: ", ")
            status = "cannot start run — \(holders) in flight"
            narrateDirector("Run not started — \(holders) is still working. Wait for it to finish (or stop it), then build again.")
            return
        }
        runClaim = claim   // `.steer` ack waits derive their consumer from the `.run` holder
        runWorkSet = workSet
        status = "running \(providerID)…"
        showChat(.director)                                  // a run narrates into the Director Agent tab
        let dirtyCount = runWorkSet.count
        narrateDirector(dirtyCount == 0
            ? "Run started (\(providerID)) — no nodes need implementing."
            : "Run started (\(providerID)) — implementing \(dirtyCount) node\(dirtyCount == 1 ? "" : "s")…")
        runTask = Task { @MainActor in
            // pins last one run (promotes already consumed them by here) — anything still owned by
            // an in-flight graph op is cleared by its commit/rollback.
            defer {
                // Release the CAPTURED claim, not `runClaim` — after an eager `cancelRun` this is
                // the zombie task's idempotent second settle, and `runClaim` may already belong to
                // a newer run (guarded so we never clobber it — including the sweep: an unguarded
                // sweep here would fail a NEW run's queued steers when the zombie finally exits).
                if runClaim == claim { sweepUnconsumedSteers() }
                ledger.releaseAll(of: claim)
                if runClaim == claim { runClaim = nil }
                runTask = nil
                runWorkSet = []            // run over → the work set is cleared (a node chat runs with it empty)
                pinnedContracts = pinnedContracts.filter { hiddenPieces.contains($0.key) }
                flushAllTranscripts()      // run end = flush point (success, throw, or cancel)
                persistAgentSessions()
            }
            do {
                let sessions = try await orchestrator.run(makeOrchestrationContext(
                    providerID: providerID, mcpPort: mcpPort,
                    projectURL: projectURL, cacheDirectory: cacheDirectory,
                    instruction: instruction, directorAlreadyBriefed: directorAlreadyBriefed,
                    claim: claim))
                // Remember each node's coding-agent session so a chat turn can resume it. A
                // freshly-minted session replaces any disk-restored one → off probation.
                for (node, sessionID) in sessions {
                    agentSessions[node.uuidString] = SZAgentSession(providerID: providerID, sessionID: sessionID)
                    restoredSessions[node.uuidString] = nil
                }
                status = "agent run complete"
                // A plain run narrates its own completion (with a generated-vs-failed summary + per-node
                // error pills); a split/merge run narrates at commit and owns its hidden-piece UX.
                if !ownsGraphOp {
                    adoptRunRenderEndpoint()   // show what this run just built
                    let (done, failed) = surfaceUnresolvedNodes()
                    narrateDirector(
                        failed == 0
                            ? (done == 0 ? "Run complete." : "Run complete — \(done) node\(done == 1 ? "" : "s") implemented.")
                            : "Run finished — \(done) implemented, \(failed) failed. See the flagged node\(failed == 1 ? "" : "s").")
                }
            } catch {
                status = "agent run failed: \(error)"
                // Still surface the unfinished nodes so a thrown/cancelled run also flags them.
                if !ownsGraphOp {
                    let (done, failed) = surfaceUnresolvedNodes()
                    narrateDirector("Run failed: \(error). \(done) implemented, \(failed) unfinished.")
                }
                print("[SZHost] agent run failed: \(error)")
            }
            // Settle a staged split/merge — the one this run was started for, or one the Director staged
            // mid-run. Runs on success, throw AND cancel (Stop cancels cooperatively, so the task still
            // arrives here via the `catch`), which is what makes a cancelled op roll back instead of leak.
            // Before the `defer`, which drops `pinnedContracts` for anything no longer in `hiddenPieces`.
            drainPendingGraphOp()
        }
    }

    /// Cancel the in-flight Director run (the `Stop` HUD action). Task cancellation propagates into the
    /// orchestrator's TaskGroup; nodes already promoted stay promoted.
    func cancelRun() {
        runTask?.cancel()
        runTask = nil
        // Eager release: composers and project ops unlock NOW, not when the cancelled task's CLI
        // agents finally die (they can outlive cancellation by a long way). The zombie task's
        // deferred releaseAll of the same token is an idempotent no-op; its still-streaming turns
        // stay safe because the pump's delivery precondition also checks the scope's in-flight
        // marker, so nothing new streams into a transcript a zombie is still writing.
        if let claim = runClaim {
            sweepUnconsumedSteers()
            ledger.releaseAll(of: claim)
            runClaim = nil
        }
        status = "run cancelled"
        narrateDirector("Run cancelled.")
        // Settle a staged split/merge NOW rather than waiting on the cancelled task. Cancellation is
        // cooperative and an agent's CLI can outlive it by a long way, so the task's own drain may be
        // minutes off — while `isRunning` already reads false. Leaving the op staged strands the pieces,
        // keeps the "Splitting" pill (which locks the node's composer via `activeScopeLocked`), and makes
        // every later split refuse against a ghost. The drain is idempotent: whenever the zombie task
        // finally reaches its own `drainPendingGraphOp()`, there is nothing left to settle.
        drainPendingGraphOp()
        flushAllTranscripts()   // the cancelled task's defer also flushes, but don't rely on timing
        persistAgentSessions()
    }

    /// After a run, surface nodes that never finished. Node success is signalled ONLY by voluntary
    /// agent MCP calls (`agent_compile_node` → promote, `agent_report_status`) — without this sweep,
    /// a node the agent neither compiled nor reported a blocker for would stay `kind == .prompt` with
    /// its pill silently falling through to Draft while the run claimed "Run complete."
    /// Any node dirty at run start that's STILL `.prompt` here gets an error pill (an `.error` phase via
    /// `recordNodeStatus`, which also fills the copyable-popover detail) + a Director-tab line. Won't
    /// clobber a status the agent already reported (error / needsInput). Returns (implemented, failed)
    /// for the run summary.
    @discardableResult
    private func surfaceUnresolvedNodes() -> (implemented: Int, failed: Int) {
        var implemented = 0, failed = 0
        for id in runWorkSet {                                                     // this run's captured work (grown)
            guard let node = store.project?.graph.node(id: id) else { continue }   // removed mid-run (merge)
            guard node.needsImplementation else { implemented += 1; continue }      // promoted → built & current
            failed += 1
            let phase = nodeAgentState[id]?.phase ?? .idle
            if phase == .error || phase == .needsInput { continue }                 // agent already explained it
            let reason = "the agent never compiled this node or reported a blocker"
            recordNodeStatus(node: id, phase: .error, message: reason)
            narrateDirector("\(node.title) didn't finish — \(reason).")
        }
        return (implemented, failed)
    }

    /// The ledger resources one agent turn on `scope` occupies: the transcript (one turn per scope),
    /// and for a node scope the node itself — so a mid-chat node reads as HELD to the mutation fence
    /// and to other claimants, not just to the view layer's `isChatting` affordance.
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

    /// Drain the Director's queued `.steer` envelopes to nodes (mark processed) — called by the
    /// reconcile loop after each reconcile turn so the next round starts fresh. Multiple steers to
    /// one node fold in FIFO order, joined by a blank line, so `CodingReconcile.directorMessage`
    /// stays one string and the strategy is untouched.
    func takeDirectorMessages() -> [SZNodeID: String] {
        var taken: [SZNodeID: [String]] = [:]
        for envelope in mailbox.envelopes where envelope.intent == .steer && envelope.state == .queued {
            guard let node = SZChatScope(key: envelope.recipient)?.nodeID else { continue }
            taken[node, default: []].append(envelope.message.text)
            mailbox.markProcessed(envelope.id)
        }
        return taken.mapValues { $0.joined(separator: "\n\n") }
    }

    /// Drain the coding agents' queued `.steer` envelopes TO the Director — rendered into the next
    /// reconcile Director turn's prompt (the reverse lane of `takeDirectorMessages`). FIFO.
    func takeDirectorInboxMessages() -> [String] {
        var taken: [String] = []
        for envelope in mailbox.envelopes where envelope.intent == .steer && envelope.state == .queued
            && envelope.recipient == SZChatScope.directorKey {
            taken.append(envelope.message.text)
            mailbox.markProcessed(envelope.id)
        }
        return taken
    }

    /// Fail every `.steer` still queued when its run ends (run-task defer AND eager cancel) — a steer
    /// is run-scoped: leaving it queued would leak a dead run's steering into an unrelated next run
    /// (the old dict's exact bug), and any `awaitProcessed` waiter must resume, not park forever.
    func sweepUnconsumedSteers() {
        for envelope in mailbox.envelopes where envelope.intent == .steer && envelope.state == .queued {
            mailbox.markFailed(envelope.id, reason: "run ended before the steer was consumed")
        }
    }
}
