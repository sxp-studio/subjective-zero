// SPDX-License-Identifier: AGPL-3.0-only
// The orchestration strategies' DISPATCH logic, proven without a live CLI via a stub runner: the
// procedural strategy is DIRTY-FIRST (only kind==.prompt nodes get an agent) and each coding command
// carries the node's prompt + ports; the agentic strategy runs a (stubbed) Director turn THEN dispatches.
// The Director prompt builder is checked here too. (The full write→compile→render loop + the live LLM
// Director are covered by the demos, not unit tests.)
import Foundation
import Synchronization
import Testing
@testable import SZAI
@testable import SZCore

private final class RecordingRunner: SZProcessRunning {
    private let calls = Mutex<[[String]]>([])   // argv per invocation
    var argvs: [[String]] { calls.withLock { $0 } }

    func run(
        _ launchPath: String, _ arguments: [String],
        environment: [String: String], currentDirectoryURL: URL?,
        timeout: TimeInterval?, onOutput: (@Sendable (String) -> Void)?
    ) async throws -> SZProcessResult {
        calls.withLock { $0.append(arguments) }
        return SZProcessResult(exitCode: 0, output: "")
    }
}

@MainActor
private func dirtyStore() -> SZStore {
    let camera = SZNodeID(), gray = SZNodeID()
    let graph = SZGraph(
        nodes: [
            SZNode(id: camera, kind: .generated, title: "Camera", position: SZPoint(x: 0, y: 0)),
            SZNode(id: gray, kind: .prompt, title: "Gray", prompt: "make it grayscale", position: SZPoint(x: 1, y: 0)),
        ],
        connections: [
            SZConnection(from: SZPortRef(node: camera, port: "texture"),
                         to: SZPortRef(node: gray, port: "input"), kind: .data),
        ],
        renderEndpoint: SZPortRef(node: gray, port: "output"))
    let store = SZStore()
    store.setProject(SZProject(name: "t", graph: graph))
    return store
}

@MainActor
@Test func orchestratorIsDirtyFirstAndBuildsCodingCommand() async throws {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "orch-test-\(UUID().uuidString)")
    let runner = RecordingRunner()

    try await SZProceduralDirectorStrategy().run(SZOrchestrationContext(
        providerID: "claude", store: dirtyStore(), mcpPort: 42100,
        projectURL: tmp, cacheDirectory: tmp, runner: runner))

    // Exactly one agent spawned — the dirty (prompt) node only; the generated camera is skipped.
    #expect(runner.argvs.count == 1)
    let argv = runner.argvs[0].joined(separator: " ")
    #expect(argv.contains("make it grayscale"))   // the node's prompt is in the coding command
    #expect(argv.contains("input"))               // input port derived from the camera→gray edge
    #expect(argv.contains("output"))              // output port derived from the render endpoint
    // The {{abi}} token embedded the node-abi doc (single ABI prose source) — spot-check two accessors.
    #expect(argv.contains("inputFloatArray"))
    #expect(argv.contains("SZNodeMain"))
    #expect(!argv.contains("{{abi}}"))            // the token itself must not survive rendering
}

@MainActor
@Test func generationSettingsReachCodingAgentArgv() async throws {
    // Closed loop: a context carrying model/effort/fast produces a coding command whose argv
    // carries the matching CLI flags — the whole selection→dispatch→argv chain in one assertion.
    let tmp = FileManager.default.temporaryDirectory.appending(path: "orch-gen-test-\(UUID().uuidString)")
    let runner = RecordingRunner()

    try await SZProceduralDirectorStrategy().run(SZOrchestrationContext(
        providerID: "codex",
        generationSettings: SZProviderGenerationSettings(model: "gpt-5.6-terra", reasoningEffort: "max", fastMode: true),
        store: dirtyStore(), mcpPort: 42100,
        projectURL: tmp, cacheDirectory: tmp, runner: runner))

    #expect(runner.argvs.count == 1)
    let argv = runner.argvs[0]
    #expect(argv.contains("gpt-5.6-terra"))
    #expect(argv.contains(#"model_reasoning_effort="max""#))
    #expect(argv.contains(#"service_tier="fast""#))
}

@Test func portDerivationFollowsWiring() {
    let camera = SZNodeID(), gray = SZNodeID()
    let graph = SZGraph(
        nodes: [],
        connections: [SZConnection(from: SZPortRef(node: camera, port: "texture"),
                                   to: SZPortRef(node: gray, port: "input"), kind: .data)],
        renderEndpoint: SZPortRef(node: gray, port: "output"))
    #expect(SZProceduralDirectorStrategy.dataInputs(of: gray, graph) == ["input"])
    #expect(SZProceduralDirectorStrategy.outputs(of: gray, graph) == ["output"])
    #expect(SZProceduralDirectorStrategy.dataInputs(of: camera, graph) == [])
    #expect(SZProceduralDirectorStrategy.outputs(of: camera, graph) == ["texture"])
}

/// `plans` scopes coding to the run's captured work set: an authoritative set selects only its members
/// (a prompt node the user added mid-run is never in it, so it's never dispatched); `nil` (no host /
/// tests) falls back to every prompt node.
@MainActor
@Test func plansScopesToWorkSet() {
    let work = SZNodeID(), userDraft = SZNodeID()
    let graph = SZGraph(nodes: [
        SZNode(id: work, kind: .prompt, title: "Work", prompt: "do the work", position: SZPoint(x: 0, y: 0)),
        SZNode(id: userDraft, kind: .prompt, title: "Draft", prompt: "", position: SZPoint(x: 1, y: 0)),
    ])
    // Authoritative set → only its members.
    #expect(SZProceduralDirectorStrategy.plans(for: graph, workSet: [work]).map(\.node) == [work])
    // Empty authoritative set → nothing (an empty real run codes nothing).
    #expect(SZProceduralDirectorStrategy.plans(for: graph, workSet: []).isEmpty)
    // nil (no host) → all prompt nodes.
    #expect(Set(SZProceduralDirectorStrategy.plans(for: graph, workSet: nil).map(\.node)) == [work, userDraft])
}

/// A split/merge piece must DIVIDE the source its seed prompt quotes, not shop the library for something
/// that looks similar. The seed prompt cannot enforce that on its own: `{{prompt}}` sits near the top of
/// `node-compile`, and the "look for a reference → agent_library_index" section below it wins on recency.
/// Observed live — a stage told "do NOT reach for the node library" in its seed called it anyway.
@MainActor @Test func stagedSplitMergePiecesGetThePreserveBehaviourFramingNotTheLibraryTiers() {
    let piece = SZNodeID(), normal = SZNodeID()
    let graph = SZGraph(nodes: [
        SZNode(id: piece, kind: .prompt, title: "Gradient (1/2)", prompt: "stage 1", position: SZPoint(x: 0, y: 0)),
        SZNode(id: normal, kind: .prompt, title: "Blur", prompt: "blur it", position: SZPoint(x: 1, y: 0)),
    ])
    let plans = SZProceduralDirectorStrategy.plans(for: graph, workSet: nil, stagedPieces: [piece])
    let stagedPlan = try! #require(plans.first { $0.node == piece })
    let normalPlan = try! #require(plans.first { $0.node == normal })
    #expect(stagedPlan.preserveBehavior)
    #expect(!normalPlan.preserveBehavior)

    let staged = SZProceduralDirectorStrategy.compilePrompt(stagedPlan, boundary: "Inputs:\n- (none)")
    let ordinary = SZProceduralDirectorStrategy.compilePrompt(normalPlan, boundary: "Inputs:\n- (none)")

    // The staged piece is told, in the section that wins, not to go to the library at all. (It still NAMES
    // the tools — to forbid them — so assert on the section, not on the token.)
    #expect(staged.contains("Do NOT look for a reference"))
    #expect(staged.contains("PRESERVE ITS BEHAVIOR"))
    #expect(!staged.contains("Spend tokens in tiers"))
    #expect(!staged.contains("reference, not a template"))

    // A normal node still gets the cheap-first library tiers — this must not regress C1's whole-catalog read.
    #expect(ordinary.contains("agent_library_index"))
    #expect(ordinary.contains("Spend tokens in tiers"))
    #expect(!ordinary.contains("Do NOT look for a reference"))

    // Both still carry the ABI + the node's own seed prompt, and leave no unrendered token behind.
    for p in [staged, ordinary] {
        #expect(p.contains("SZNode"))          // the embedded ABI doc
        #expect(!p.contains("{{"))
    }
    #expect(staged.contains("stage 1"))
    #expect(ordinary.contains("blur it"))
}

/// Neither `{{reference}}` variant may itself contain a live token. `SZPromptTemplate.render` walks an
/// UNORDERED dictionary, so a `{{…}}` inside a substituted VALUE would be expanded — or not — depending on
/// the hash seed, rendering two different coding prompts on two runs.
@Test func neitherReferenceSectionCanCollideWithAnotherToken() {
    #expect(!SZPrompts.referenceLibrary.contains("{{"))
    #expect(!SZPrompts.referencePreserve.contains("{{"))
}

/// Default = library tiers: nothing outside a staged split/merge may lose its reference step.
@MainActor @Test func plansDefaultToTheLibraryFramingWhenNothingIsStaged() {
    let n = SZNodeID()
    let graph = SZGraph(nodes: [SZNode(id: n, kind: .prompt, title: "N", prompt: "p", position: SZPoint(x: 0, y: 0))])
    #expect(SZProceduralDirectorStrategy.plans(for: graph, workSet: nil).allSatisfy { !$0.preserveBehavior })
}

/// The coding prompt's boundary names each port's TYPE and the exact live-read call, so the agent
/// preserves the typed contract AND reads scalar inputs instead of hardcoding them (the silent-no-op).
@Test func renderBoundaryDescribesTypesAndLiveReads() {
    let inputs = [
        SZPort(name: "input", type: .texture),
        SZPort(name: "mirror", type: .bool, ui: SZPortUI(kind: .toggle), def: .bool(true)),
        SZPort(name: "amount", type: .float, ui: SZPortUI(kind: .slider), def: .float(0.5)),
        SZPort(name: "camera", type: .enumeration, ui: SZPortUI(kind: .dropdown), def: .enumeration("default")),
    ]
    let outputs = [SZPort(name: "output", type: .texture, display: true)]
    let b = SZBoundaryPrompt.render(inputs: inputs, outputs: outputs, permissions: [.camera])

    #expect(b.contains("`mirror` — bool"))                 // type preserved, not flattened to texture
    #expect(b.contains(#"ctx.inputFloat("mirror")"#))      // bool read live
    #expect(b.contains(#"ctx.inputFloat("amount")"#))      // float read live
    #expect(b.contains(#"ctx.inputTexture("input")"#))     // texture read
    #expect(b.contains(#"ctx.outputTexture("output")"#))   // output fill
    #expect(b.contains("default true"))                    // ui/default surfaced
    #expect(b.contains(#"ctx.inputString("camera")"#))     // enum delivered live via the v4 string ABI
    #expect(b.contains("camera"))                          // declared permission surfaced

    // A contract-less node derives texture-only ports → texture read guidance, no scalar reads.
    let textureOnly = SZBoundaryPrompt.render(
        inputs: [SZPort(name: "input", type: .texture)],
        outputs: [SZPort(name: "output", type: .texture, display: true)], permissions: [])
    #expect(textureOnly.contains(#"ctx.inputTexture("input")"#))
    #expect(!textureOnly.contains("inputFloat"))
}

// MARK: - Agentic Director strategy

/// The agentic strategy runs ONE Director turn (here stubbed — no live CLI), then dispatches the dirty
/// nodes the Director left behind. We assert both: the Director's SETUP turn was invoked with the rendered
/// prompt, and a coding agent fired afterward. (The stub never promotes the node, so the reconcile loop
/// then retries it — exercised precisely in `agenticReconcilesUnresolvedNodes`.)
@MainActor
@Test func agenticRunsTheDirectorThenDispatches() async throws {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "agentic-\(UUID().uuidString)")
    let runner = RecordingRunner()
    let prompts = Mutex<[String]>([])

    let context = SZOrchestrationContext(
        providerID: "claude", store: dirtyStore(), mcpPort: 42100,
        projectURL: tmp, cacheDirectory: tmp, runner: runner,
        directorTurn: { prompt in
            prompts.withLock { $0.append(prompt) }
            return SZAgentRunResult(
                process: SZProcessResult(exitCode: 0, output: ""),
                outcome: SZAgentOutcome(sessionID: "director-1", failed: false))
        })
    try await SZAgenticDirectorStrategy().run(context)

    let setup = prompts.withLock { $0.first }
    #expect(setup?.contains("Director Agent") == true)   // the SETUP Director prompt was rendered + passed
    #expect(setup?.contains("Gray") == true)             // …with the live graph as context
    #expect(runner.argvs.count >= 1)                     // then the dirty node's coding agent fired
}

/// With no Director available (tests / a provider that can't run one), the agentic strategy degrades to
/// dispatching the graph as-is — a flaky Director never blocks the run.
@MainActor
@Test func agenticWithoutADirectorDispatchesAsIs() async throws {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "agentic-nodir-\(UUID().uuidString)")
    let runner = RecordingRunner()
    try await SZAgenticDirectorStrategy().run(SZOrchestrationContext(
        providerID: "claude", store: dirtyStore(), mcpPort: 42100,
        projectURL: tmp, cacheDirectory: tmp, runner: runner))   // directorTurn defaults to nil

    // `count >= 1` would hold for a run that dispatched once and gave up, or that dispatched the
    // *generated* Camera node too. Assert the SAME dispatch shape the Director-backed run produces
    // (agenticReconcilesUnresolvedNodes) — that is what "degrades to dispatching as-is" actually means:
    // the fleet loses its planner, not its retry loop.
    #expect(runner.argvs.count == 1 + SZAgenticDirectorStrategy.reconcileCap)
    #expect(runner.argvs.first?.contains { $0.contains("implementing ONE node") } == true)
    #expect(runner.argvs.dropFirst().allSatisfy { argv in argv.contains { $0.contains("What blocked it last time") } })
    // Only the dirty prompt node ("Gray") is ever handed to an agent; the generated Camera is not.
    #expect(runner.argvs.allSatisfy { argv in argv.contains { $0.contains("make it grayscale") } })
}

/// Reconcile loop: a node that never promotes (the stub does no real compile → stays `.prompt`) is
/// retried up to `reconcileCap` times after the initial dispatch, each round preceded by a Director
/// reconcile turn, and each retry uses the re-grounding (reconcile) coding prompt — not a fresh compile.
@MainActor
@Test func agenticReconcilesUnresolvedNodes() async throws {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "agentic-reconcile-\(UUID().uuidString)")
    let runner = RecordingRunner()
    let prompts = Mutex<[String]>([])

    let context = SZOrchestrationContext(
        providerID: "claude", store: dirtyStore(), mcpPort: 42100,
        projectURL: tmp, cacheDirectory: tmp, runner: runner,
        directorTurn: { prompt in
            prompts.withLock { $0.append(prompt) }
            return SZAgentRunResult(
                process: SZProcessResult(exitCode: 0, output: ""),
                outcome: SZAgentOutcome(sessionID: "director-1", failed: false))
        })
    try await SZAgenticDirectorStrategy().run(context)

    // One setup turn + `reconcileCap` reconcile turns; the reconcile turns render the reconcile prompt.
    let all = prompts.withLock { $0 }
    #expect(all.count == 1 + SZAgenticDirectorStrategy.reconcileCap)
    #expect(all.first?.contains("Director Agent") == true)
    #expect(all.dropFirst().allSatisfy { $0.contains("Reconcile round") })

    // The fleet retried the single unresolved node each round (1 initial + reconcileCap re-dispatches),
    // and the retries used the re-grounding reconcile prompt rather than the from-scratch compile prompt.
    #expect(runner.argvs.count == 1 + SZAgenticDirectorStrategy.reconcileCap)
    #expect(runner.argvs.first?.contains { $0.contains("implementing ONE node") } == true)
    #expect(runner.argvs.dropFirst().allSatisfy { argv in argv.contains { $0.contains("What blocked it last time") } })
}

/// Director→coding message: a message the Director authored (via `ui_send_chat` during the run,
/// surfaced here by the `takeDirectorMessages` closure) is folded into the matching node's retry prompt —
/// so the Coding Agent reads the Director's actual words on resume.
@MainActor
@Test func agenticFoldsDirectorMessageIntoRetry() async throws {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "agentic-message-\(UUID().uuidString)")
    let runner = RecordingRunner()
    let store = dirtyStore()
    let grayID = store.project!.graph.nodes.first { $0.kind == .prompt }!.id
    // Hand the strategy one message on the first reconcile round, then none (so it isn't repeated).
    let rounds = Mutex<Int>(0)

    try await SZAgenticDirectorStrategy().run(SZOrchestrationContext(
        providerID: "claude", store: store, mcpPort: 42100,
        projectURL: tmp, cacheDirectory: tmp, runner: runner,
        directorTurn: { _ in
            SZAgentRunResult(process: SZProcessResult(exitCode: 0, output: ""),
                             outcome: SZAgentOutcome(sessionID: "director-1", failed: false))
        },
        takeDirectorMessages: {
            let n = rounds.withLock { $0 += 1; return $0 }
            return n == 1 ? [grayID: "use luminance weights, not a flat average"] : [:]
        }))

    // The first retry (argvs[1]) carries the Director's message; the second (argvs[2]) does not.
    #expect(runner.argvs[1].contains { $0.contains("A message from the Director") && $0.contains("luminance weights") })
    #expect(runner.argvs[2].contains { $0.contains("luminance weights") } == false)
}

/// The Director prompt embeds the live graph (node ids + titles + flow edges) so the agent can target its
/// `ui_*` calls, and falls back to "implement the current graph" when no instruction is given.
@Test func directorPromptEmbedsGraphAndInstructionFallback() {
    let camera = SZNodeID(), gray = SZNodeID()
    let graph = SZGraph(
        nodes: [
            SZNode(id: camera, kind: .prompt, title: "Camera", position: SZPoint(x: 0, y: 0)),
            SZNode(id: gray, kind: .prompt, title: "Gray", prompt: "make it grayscale", position: SZPoint(x: 1, y: 0)),
        ],
        connections: [SZConnection(from: SZPortRef(node: camera, port: "flow"),
                                   to: SZPortRef(node: gray, port: "flow"), kind: .flow)])
    let prompt = SZDirectorPrompt.render(graph: graph, instruction: "  ")

    #expect(prompt.contains(camera.uuidString) && prompt.contains(gray.uuidString))   // ids to target ui_*
    #expect(prompt.contains("Camera") && prompt.contains("make it grayscale"))
    #expect(prompt.contains("Flow edges"))
    #expect(prompt.contains("make the current graph as drawn ready"))   // blank instruction → fallback
    #expect(prompt.contains("ui_add_prompt_node"))
    #expect(prompt.contains("ui_add_source_node"))
    #expect(prompt.contains("MCP tools may be revealed lazily"))
}
