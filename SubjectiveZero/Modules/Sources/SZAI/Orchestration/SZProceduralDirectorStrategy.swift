// SPDX-License-Identifier: AGPL-3.0-only
// The PROCEDURAL Director strategy — `contract-plan → parallel coding → reconcile` in plain Swift
// (docs/AGENT_ORCHESTRATION.md). "Director" is the orchestration role both strategies fill; this one
// directs WITHOUT an LLM — deterministic / offline / token-free, the baseline + CI path, and the
// first real consumer of flow edges. Its sibling is `SZAgenticDirectorStrategy`. It drives
// agents only through the `SZProvider` protocol, so the same code runs claude and codex (zero literals).
//
// Scope (the single-node happy path):
//  - DIRTY-FIRST: process only dirty nodes (`needsImplementation` — never built, or built against a contract
//    that has since moved); nodes whose build still fits their contract are left alone. The
//    dirty→clean flip happens in the host's promote (a compiled node becomes .generated).
//  - contract-plan: TEMPLATED in Swift (derive each dirty node's required ports from the graph wiring).
//  - parallel coding: one coding agent per dirty node (TaskGroup), each spawned via SZProvider.run with
//    the host's MCP server attached over nc. The agent writes + compiles via MCP (host promotes on ok).
//  - reconcile (minimal): the run completes when all agents finish; the render is verified out-of-band.
import Foundation
import SZCore

public struct SZProceduralDirectorStrategy: SZOrchestrating {
    private let registry: SZProviderRegistry

    public init(registry: SZProviderRegistry = .shared) {
        self.registry = registry
    }

    /// Per-coding-turn budgets, in seconds. The working bound is SILENCE, not wall clock: a turn dies
    /// after `codingInactivityTimeout` with no output (every streamed chunk resets the clock), so a large
    /// node whose agent is still visibly working is never cut off mid-stream — the blind 300s wall that
    /// used to kill streaming agents was the worst observed run friction. `codingTimeout` remains as the
    /// wall-clock hard cap for a CLI that wedges (or loops) while still emitting. Overridable via
    /// `SZ_AGENT_TIMEOUT` / `SZ_AGENT_INACTIVITY_TIMEOUT` (TODO: expose as Settings sliders);
    /// decomposing the work is the structural fix — these are the power-user escape hatches.
    static var codingTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["SZ_AGENT_TIMEOUT"].flatMap(TimeInterval.init) ?? 900
    }

    static var codingInactivityTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["SZ_AGENT_INACTIVITY_TIMEOUT"].flatMap(TimeInterval.init) ?? 120
    }

    /// One coding assignment — Sendable so it can cross into the per-agent child tasks. Carries the
    /// node's DECLARED typed ports (not just names) so the coding prompt can tell the agent each input's
    /// type + how to read it live.
    struct CodingPlan: Sendable {
        let node: SZNodeID
        let prompt: String
        let inputs: [SZPort]
        let outputs: [SZPort]
        let permissions: [SZEntitlement]
        /// This node is a piece STAGED by a split/merge: its seed prompt already quotes the original's
        /// source, so it must divide/fuse that code rather than shop the library for something similar.
        var preserveBehavior: Bool = false
    }

    /// The per-node reconcile context for a RE-dispatch, folded into one value so a node carries its
    /// reconcile state as a unit instead of three parallel `[SZNodeID: String]` dicts threaded in lockstep.
    /// All-nil (`CodingReconcile()`) for a first dispatch. On a reconcile round the agentic strategy fills,
    /// per still-unresolved node: the prior coding session to RESUME (continue THAT conversation), the
    /// blocker that stalled it (switches `code` to the re-grounding prompt), and any message the Director
    /// Agent authored for it this round (its `ui_send_chat` words, the primary steer when present).
    struct CodingReconcile: Sendable {
        var resumeSession: String?
        var blocker: String?
        var directorMessage: String?
    }

    /// Run the procedural strategy over the loaded project. Reads the graph on the MainActor, then spawns
    /// coding agents off-main (so the MainActor stays free to service their MCP callbacks while we `await`).
    @MainActor
    @discardableResult
    public func run(_ context: SZOrchestrationContext) async throws -> [SZNodeID: String] {
        guard let provider = registry.provider(id: context.providerID) else {
            throw SZOrchestratorError.unknownProvider(context.providerID)
        }
        // Contract-first: draft texture contracts + wiring from flow for any contract-less drawn node, then
        // pin every dirty node's boundary — so the cards show their I/O before dispatch (the host no-ops
        // both when there's nothing to do). Read the graph AFTER, so plans see the freshly-drafted contracts.
        context.draftContracts()
        context.pinContracts()
        guard let project = context.store.project else { throw SZOrchestratorError.noProject }

        let plans = Self.plans(for: project.graph, workSet: context.workSet(),
                               stagedPieces: context.stagedPieces())
        return try await dispatch(plans, provider: provider, context: context)
    }

    /// Dispatch one coding agent per plan (shared with the agentic strategy, which decomposes first then
    /// delegates here). Off-main spawns; returns each node's session id. **All-parallel by design** (one
    /// TaskGroup, max speed): once contracts are pinned upfront (contract-first), each agent writes
    /// its node in isolation against its own typed boundary — it does NOT need upstream nodes implemented
    /// first, so flow imposes no execution order here. Flow is consumed by contract-first DRAFTING +
    /// wiring (the host), not by gating the fleet.
    /// `reconcile` is empty for a first dispatch. On a reconcile re-dispatch the agentic strategy
    /// passes, per still-unresolved node, a `CodingReconcile` carrying its prior coding session id (to
    /// continue THAT conversation), the blocker that stalled it (which switches the node to the re-grounding
    /// prompt), and any message the Director Agent authored for it this round (its `ui_send_chat` words). A
    /// node present in `reconcile` is re-prompted against its current (possibly Director-adjusted) boundary;
    /// one absent is dispatched fresh as before.
    @MainActor
    @discardableResult
    func dispatch(
        _ plans: [CodingPlan], provider: any SZProvider, context: SZOrchestrationContext,
        reconcile: [SZNodeID: CodingReconcile] = [:]
    ) async throws -> [SZNodeID: String] {
        guard !plans.isEmpty else {
            print("[SZProceduralDirectorStrategy] no dirty nodes — nothing to do")
            return [:]
        }

        // Grant any entitlement a node now declares (e.g. a Director-authored `microphone` contract) BEFORE
        // the fleet runs — so when a node promotes and reloads, its `setup()` sees the permission granted
        // rather than `.notDetermined` (which would leave the capability silently dark). No-op once granted.
        await context.grantPermissions()

        var sessions: [SZNodeID: String] = [:]
        await withTaskGroup(of: (SZNodeID, String?).self) { group in
            for plan in plans {
                let reconcile = reconcile[plan.node] ?? CodingReconcile()
                group.addTask {
                    await Self.code(plan, provider: provider, mcpPort: context.mcpPort,
                                    allowedMCPTools: context.allowedMCPTools,
                                    projectURL: context.projectURL, cacheDirectory: context.cacheDirectory,
                                    runner: context.runner, turnRunner: context.turnRunner,
                                    generationSettings: context.generationSettings,
                                    reconcile: reconcile)
                }
            }
            for await (node, sessionID) in group {
                if let sessionID { sessions[node] = sessionID }
            }
        }
        print("[SZProceduralDirectorStrategy] run complete (\(plans.count) node(s), provider=\(provider.id))")
        return sessions
    }

    /// contract-plan, dirty-first: one assignment per unimplemented (prompt) node. A node that already
    /// carries a drafted contract (a split/merge piece, or a host-pinned contract-first node)
    /// uses ITS declared ports; a contract-less drawn prompt node derives texture ports from its wiring.
    /// The cold-start coding turn's prompt. The `{{reference}}` section is chosen HERE, not argued for inside
    /// the node's seed prompt: `{{prompt}}` sits near the top of `node-compile`, and the library section
    /// below it wins on recency — a split stage told "don't use the library" in its seed still went and
    /// called `agent_library_index`. A staged piece gets the preserve-behavior section instead; its
    /// reference is the original's source, which its seed already quotes.
    nonisolated static func compilePrompt(_ plan: CodingPlan, boundary: String) -> String {
        SZPromptTemplate.render(SZPrompts.nodeCompile, [
            "node": plan.node.uuidString,
            "prompt": plan.prompt,
            "inputs": plan.inputs.map(\.name).joined(separator: ", "),
            "outputs": plan.outputs.map(\.name).joined(separator: ", "),
            "boundary": boundary,
            "abi": SZAgentDocs.abiReference,   // the node-abi doc, embedded — one ABI prose source
            "reference": plan.preserveBehavior ? SZPrompts.referencePreserve : SZPrompts.referenceLibrary,
        ])
    }

    @MainActor
    static func plans(for graph: SZGraph, workSet: Set<SZNodeID>?,
                      stagedPieces: Set<SZNodeID> = []) -> [CodingPlan] {
        let candidates = graph.nodes.filter(\.needsImplementation)
        // Scope to the run's captured work set: a `nil` set (no host / tests) means "all prompt nodes"
        // (today's behavior); a non-nil set — even empty — is authoritative, so a node the user added
        // mid-run (never in the set) is never dispatched.
        return (workSet.map { ws in candidates.filter { ws.contains($0.id) } } ?? candidates)
            .map { node in
                CodingPlan(
                    node: node.id,
                    prompt: node.prompt ?? node.title,
                    inputs: node.contract?.inputs ?? dataInputs(of: node.id, graph).map { SZPort(name: $0, type: .texture) },
                    outputs: node.contract?.outputs ?? outputs(of: node.id, graph).map { SZPort(name: $0, type: .texture) },
                    permissions: node.contract?.requiredPermissions ?? [],
                    preserveBehavior: stagedPieces.contains(node.id))
            }
    }

    /// Spawn one coding agent for `plan`. Off-main + Sendable inputs only. Returns the node id paired
    /// with the agent's session id (nil if the run failed to produce one). A `reconcile` carrying a blocker
    /// flips this into a re-grounding turn: render the `nodeReconcile` prompt (prior blocker + current
    /// boundary) instead of `nodeCompile`, and resume the prior session so the agent continues its own
    /// conversation rather than starting cold.
    private static func code(
        _ plan: CodingPlan, provider: any SZProvider, mcpPort: UInt16,
        allowedMCPTools: [String] = [],
        projectURL: URL, cacheDirectory: URL, runner: any SZProcessRunning,
        turnRunner: SZCodingTurnRunner?,
        generationSettings: SZProviderGenerationSettings = SZProviderGenerationSettings(),
        reconcile: CodingReconcile = CodingReconcile()
    ) async -> (SZNodeID, String?) {
        let boundary = SZBoundaryPrompt.render(inputs: plan.inputs, outputs: plan.outputs, permissions: plan.permissions)
        let prompt: String
        if let reconcileBlocker = reconcile.blocker {
            // A Director-authored message (its `ui_send_chat` words) is the primary steer when present; the
            // blocker is the agent's own prior report. Render the message as its own section, else "".
            let directorSection = reconcile.directorMessage.map { "\n## A message from the Director — follow this\n\($0)\n" } ?? ""
            prompt = SZPromptTemplate.render(SZPrompts.nodeReconcile, [
                "node": plan.node.uuidString,
                "prompt": plan.prompt,
                "blocker": reconcileBlocker,
                "director_message": directorSection,
                "boundary": boundary,
            ])
        } else {
            prompt = compilePrompt(plan, boundary: boundary)
        }
        let workingDirectory = cacheDirectory.appending(path: "agent/\(plan.node.uuidString)")
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let request = SZAgentRunRequest(
            prompt: prompt,
            workingDirectory: workingDirectory,
            packageDirectory: projectURL,
            cacheDirectory: cacheDirectory,
            mcpServerPort: mcpPort,
            allowedMCPTools: allowedMCPTools,
            resumeSessionID: reconcile.resumeSession,
            model: generationSettings.model,
            reasoningEffort: generationSettings.reasoningEffort,
            fastMode: generationSettings.fastMode ?? false,
            timeout: Self.codingTimeout,
            inactivityTimeout: Self.codingInactivityTimeout)
        print("[SZProceduralDirectorStrategy] spawning coding agent for \(plan.node) (provider=\(provider.id))")
        do {
            // Stream into the node's Coding Agent tab when the host injected a turn runner; else run
            // the provider directly (tests). Both return the same SZAgentRunResult.
            let result: SZAgentRunResult
            if let turnRunner {
                result = try await turnRunner(plan.node, request, provider)
            } else {
                result = try await provider.run(request, runner: runner)   // agent writes + compiles via MCP
            }
            // Persist the agent's transcript for inspection (the agent's MCP calls hit the host separately).
            let log = workingDirectory.appending(path: "agent-output.log")
            try? result.process.output.write(to: log, atomically: true, encoding: .utf8)
            print("[SZProceduralDirectorStrategy] agent \(plan.node) exit=\(result.process.exitCode) timedOut=\(result.process.timedOut) session=\(result.outcome.sessionID ?? "nil") output=\(result.process.output.count)B → \(log.path)")
            return (plan.node, result.outcome.sessionID)
        } catch {
            print("[SZProceduralDirectorStrategy] coding agent for \(plan.node) failed: \(error)")
            return (plan.node, nil)
        }
    }

    // MARK: contract-plan helpers (derive a node's declared ports from the graph wiring)

    static func dataInputs(of node: SZNodeID, _ graph: SZGraph) -> [String] {
        ordered(graph.connections.filter { $0.kind == .data && $0.to.node == node }.map(\.to.port))
    }

    static func outputs(of node: SZNodeID, _ graph: SZGraph) -> [String] {
        var ports = graph.connections.filter { $0.kind == .data && $0.from.node == node }.map(\.from.port)
        if let endpoint = graph.renderEndpoint, endpoint.node == node { ports.append(endpoint.port) }
        return ordered(ports)
    }

    private static func ordered(_ ports: [String]) -> [String] {
        var seen = Set<String>()
        return ports.filter { seen.insert($0).inserted }
    }
}
