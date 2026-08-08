// SPDX-License-Identifier: AGPL-3.0-only
// P1 EQUIVALENCE BASELINE for the agent-orchestration rebuild: every prompt the CURRENT orchestrator
// renders, recorded as committed byte-pinned fixtures BEFORE any new engine exists. In P3 the new
// engine must reproduce these byte-for-byte — the pins are the gate, so they must never be "fixed"
// to make a refactor pass; that is the one way to silently change what every agent in the fleet is
// told. A deliberate prompt edit regenerates them (SZ_WRITE_FIXTURES) and the diff is reviewed like
// code.
//
// WHAT IS PINNED (name → shape):
//  - director-decompose[-noinstruction]   — the Director Agent's run-setup turn (with/without a user
//                                           instruction), captured through a real SZAgenticDirectorStrategy run
//  - director-reconcile-r1/-r2/-r1-bare   — reconcile rounds 1+2 (statuses + fleet inbox rendered;
//                                           inbox drains to "(none)" on r2) and the no-status fallback
//  - director-graph-summary-variants      — graphSummary's fallback branches (empty prompt node,
//                                           NEEDS REBUILD, no edges, no endpoint)
//  - coding-compile-cold/-inline/-preserve/-contracted — the node-compile family across its
//                                           {{reference}}/{{schema}} variants + a full typed boundary
//  - coding-compile-inline-opencode       — the same inline brief after opencode's subz_ tool namespacing
//  - coding-reconcile-with-note/-plain/-bare — the retry re-grounding prompt with a Director note,
//                                           without one, and with the fallback blocker
//  - chat-director-cold/-resumed, chat-node-cold — the chat framings SZAI renders
//  - graphop-split-stage[-bare], graphop-merge — the split/merge seed prompts
//  - library-index                        — the agent_library_index framing
//  - dispatch-*.txt / argv-claude-*.txt   — the dispatch event shape of both strategies and the
//                                           (normalized) claude argv assembly, cold + resume
//
// DETERMINISM: node ids, titles, prompts and the camera contract come from
// Samples/grayscale-prompt.subz (read from disk, never launched). The one divergence from the
// sample: the camera node is `.generated` here (the sample ships it `.prompt`) so exactly ONE node
// is dirty — a single-agent dispatch has a deterministic argv order, a two-agent TaskGroup does
// not. Project/cache paths are the fixed literals /sz-equivalence/{project,cache} (never created —
// the stub runner touches no disk). Session ids are minted per process and appear only in argv,
// where they are normalized to placeholders before pinning; no dates, no environment reads.
//
// REGENERATING: SZ_WRITE_FIXTURES=Modules/Tests/SZAITests/Fixtures/Equivalence \
//                   swift test --filter SZPromptEquivalence
import Foundation
import Synchronization
import Testing
@testable import SZAI
@testable import SZCore

// MARK: - Fixed world (ids + prompts mirror Samples/grayscale-prompt.subz)

private let cameraID = SZNodeID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let grayID = SZNodeID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let cameraPrompt =
    "Live Mac camera feed delivered as a texture output — the canonical macOS camera source node."
private let grayPrompt = "Convert the incoming camera texture to grayscale (per-pixel luminance)."

/// Fixed fake paths — never created, never written (the stub runner spawns nothing); they exist so
/// the argv fixtures carry stable bytes instead of per-run temp dirs.
private let fixtureProjectURL = URL(filePath: "/sz-equivalence/project")
private let fixtureCacheURL = URL(filePath: "/sz-equivalence/cache")

/// A fixed MCP allowlist so the claude `--allowedTools` assembly (native + `mcp__subz__` prefixing)
/// is pinned. Real runs pass the host's full `agentCallableToolNames`; the assembly rule is the
/// durable fact, not the roster.
private let fixtureMCPTools = ["agent_write_node_staged", "agent_compile_node", "agent_report_status"]

/// The sample's camera contract, read from the .subz on disk so the pin is anchored to the
/// committed sample bytes rather than a re-typed copy.
private let cameraContract: SZNodeContract = {
    let url = URL(filePath: #filePath)
        .deletingLastPathComponent()   // SZAITests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // SubjectiveZero
        .appending(path: "Samples/grayscale-prompt.subz/nodes/\(cameraID.uuidString)/node-contract.json")
    guard let data = try? Data(contentsOf: url),
          let contract = try? JSONDecoder().decode(SZNodeContract.self, from: data) else {
        fatalError("equivalence fixtures: cannot read the sample camera contract at \(url.path)")
    }
    return contract
}()

/// A kitchen-sink contract exercising every `SZBoundaryPrompt` branch a port can take — texture,
/// float+slider+default, bool+toggle+default, static enum with options+default, string+default,
/// color (float-family), floatArray, event on the input side; texture/float/bool/floatArray/string
/// on the output side — plus both entitlements.
private let kitchenSinkContract = SZNodeContract(
    title: "Grayscale", sfSymbol: "circle.lefthalf.filled", summary: "Converts to grayscale.",
    inputs: [
        SZPort(name: "input", type: .texture),
        SZPort(name: "strength", type: .float,
               ui: SZPortUI(kind: .slider, min: 0, max: 1), def: .float(0.5)),
        SZPort(name: "mirror", type: .bool, ui: SZPortUI(kind: .toggle), def: .bool(false)),
        SZPort(name: "mode", type: .enumeration, ui: SZPortUI(kind: .dropdown),
               def: .enumeration("luma"),
               options: [SZEnumOption(label: "Luma", value: "luma"),
                         SZEnumOption(label: "Average", value: "average")]),
        SZPort(name: "label", type: .string, ui: SZPortUI(kind: .field), def: .string("mono")),
        SZPort(name: "tint", type: .colorRGB, ui: SZPortUI(kind: .colorWell)),
        SZPort(name: "samples", type: .floatArray),
        SZPort(name: "trigger", type: .event),
    ],
    outputs: [
        SZPort(name: "output", type: .texture, display: true),
        SZPort(name: "level", type: .float),
        SZPort(name: "active", type: .bool),
        SZPort(name: "histogram", type: .floatArray),
        SZPort(name: "note", type: .string),
    ],
    permissions: [.camera, .microphone])

/// The run graph: the sample's two nodes + flow edge + render endpoint, plus a data edge
/// camera.texture→gray.input so the contract-less gray node exercises port derivation (and the
/// summary renders a non-empty "Data edges:" line). `grayContract` non-nil = the contracted
/// variant (plans use its declared ports + permissions instead of deriving).
@MainActor
private func fixtureStore(grayContract: SZNodeContract? = nil) -> SZStore {
    let graph = SZGraph(
        nodes: [
            SZNode(id: cameraID, kind: .generated, title: "MacBook Camera",
                   sfSymbol: "camera", prompt: cameraPrompt,
                   contract: cameraContract, position: SZPoint(x: 120, y: 220)),
            SZNode(id: grayID, kind: .prompt, title: "Grayscale Effect",
                   sfSymbol: "sparkles", prompt: grayPrompt,
                   contract: grayContract, position: SZPoint(x: 420, y: 220)),
        ],
        connections: [
            SZConnection(from: SZPortRef(node: cameraID, port: "texture"),
                         to: SZPortRef(node: grayID, port: "input"), kind: .data),
            SZConnection(from: SZPortRef.flow(node: cameraID),
                         to: SZPortRef.flow(node: grayID), kind: .flow),
        ],
        renderEndpoint: SZPortRef(node: grayID, port: "output"))
    let store = SZStore()
    store.setProject(SZProject(name: "fixture", graph: graph))
    return store
}

// MARK: - Capture harness

/// Records every argv the strategies hand the process runner, and appends a shape event per spawn
/// (cold vs resume — the durable fact; the ids themselves are per-process).
private final class RecordingRunner: SZProcessRunning {
    private let calls = Mutex<[[String]]>([])
    private let onSpawn: @Sendable (String) -> Void
    var argvs: [[String]] { calls.withLock { $0 } }

    init(onSpawn: @escaping @Sendable (String) -> Void = { _ in }) { self.onSpawn = onSpawn }

    func run(
        _ launchPath: String, _ arguments: [String],
        environment: [String: String], currentDirectoryURL: URL?,
        input: Data?, timeout: TimeInterval?, inactivityTimeout: TimeInterval?,
        onOutput: (@Sendable (Data) -> Void)?
    ) async throws -> SZProcessResult {
        calls.withLock { $0.append(arguments) }
        onSpawn(arguments.contains("--resume") ? "coding agent resume" : "coding agent cold")
        return SZProcessResult(exitCode: 0, output: "")
    }
}

/// The prompt is the argv element after `-p` (`SZClaudeProvider.launch` puts it there). Failing to
/// find it is a harness bug worth failing loudly on, not an empty fixture.
private func prompt(in argv: [String]) -> String {
    guard let i = argv.firstIndex(of: "-p"), argv.indices.contains(i + 1) else { return "<no -p in argv>" }
    return argv[i + 1]
}

/// One argv as a pinnable text block: one element per line, with the two per-process values
/// normalized — the prompt (its bytes are pinned by the coding-*.md fixtures) and the session
/// UUID (minted per spawn / carried from the prior spawn).
private func normalizedArgv(_ argv: [String]) -> String {
    var lines: [String] = []
    var i = 0
    while i < argv.count {
        let arg = argv[i]
        lines.append(arg)
        if i + 1 < argv.count {
            switch arg {
            case "-p":           lines.append("<prompt — bytes pinned by the coding-*.md fixtures>"); i += 1
            case "--session-id": lines.append("<session-uuid minted per spawn>"); i += 1
            case "--resume":     lines.append("<the node's prior session id>"); i += 1
            default: break
            }
        }
        i += 1
    }
    return lines.joined(separator: "\n") + "\n"
}

private struct RunCapture {
    var directorPrompts: [String]
    var codingArgvs: [[String]]
    /// One line per event in dispatch order — the strategy's SHAPE.
    var shape: [String]
}

/// Drive a REAL strategy end-to-end with a stub Director turn + stub process runner, capturing
/// every rendered prompt and the dispatch shape. The stub never promotes the node, so the agentic
/// strategy's reconcile loop runs to its cap — exactly the retry shapes we want pinned.
@MainActor
private func captureRun(
    _ strategy: SZOrchestrationStrategy,
    withDirector: Bool,
    directorAlreadyBriefed: Bool = false,
    instruction: String = "",
    libraryIndexText: String? = nil,
    stagedPieces: Set<SZNodeID> = [],
    grayContract: SZNodeContract? = nil,
    statuses: [SZNodeID: String] = [:],
    inboxOnce: [String] = [],
    directorMessagesOnce: [SZNodeID: String] = [:]
) async throws -> RunCapture {
    let events = Mutex<[String]>([])
    let runner = RecordingRunner { label in events.withLock { $0.append(label) } }
    let prompts = Mutex<[String]>([])
    let inboxCalls = Mutex<Int>(0)
    let messageCalls = Mutex<Int>(0)
    var directorStub: (@MainActor @Sendable (String) async throws -> SZAgentRunResult)?
    if withDirector {
        directorStub = { prompt in
            prompts.withLock { $0.append(prompt) }
            events.withLock { $0.append("director turn") }
            return SZAgentRunResult(
                process: SZProcessResult(exitCode: 0, output: ""),
                outcome: SZAgentOutcome(sessionID: "director-fixture", failed: false))
        }
    }

    try await strategy.make().run(SZOrchestrationContext(
        providerID: "claude",
        store: fixtureStore(grayContract: grayContract),
        mcpPort: 42100,
        allowedMCPTools: fixtureMCPTools,
        projectURL: fixtureProjectURL,
        cacheDirectory: fixtureCacheURL,
        runner: runner,
        instruction: instruction,
        directorAlreadyBriefed: directorAlreadyBriefed,
        directorTurn: directorStub,
        nodeStatus: { statuses },
        // Drained once: the Director's per-node notes ride the FIRST reconcile round's retries only.
        takeDirectorMessages: { messageCalls.withLock { $0 += 1; return $0 == 1 ? directorMessagesOnce : [:] } },
        // Drained once: the fleet's inbox renders into reconcile round 1, "(none)" on round 2.
        takeDirectorInbox: { inboxCalls.withLock { $0 += 1; return $0 == 1 ? inboxOnce : [] } },
        stagedPieces: { stagedPieces },
        libraryIndexText: libraryIndexText))

    // Label the raw director events by position: the first (absent a prior chat-turn brief) is the
    // decompose turn, the rest are reconcile rounds.
    var sawDecompose = directorAlreadyBriefed
    var round = 0
    let shape = events.withLock { $0 }.map { event -> String in
        guard event == "director turn" else { return event }
        if !sawDecompose { sawDecompose = true; return "director decompose" }
        round += 1
        return "director reconcile round \(round)"
    }
    return RunCapture(directorPrompts: prompts.withLock { $0 },
                      codingArgvs: runner.argvs, shape: shape)
}

// MARK: - The cases

@MainActor
private func generateFixtures() async throws -> [String: String] {
    var out: [String: String] = [:]
    let graph = fixtureStore().project!.graph

    // — chat framings (the SZAI render paths the host's buildChatPrompt calls) —
    out["chat-director-cold.md"] = SZDirectorPrompt.renderChat(
        graph: graph, message: "make it warmer and add a soft glow")
    out["chat-director-resumed.md"] = SZDirectorPrompt.renderResumedChat(
        graph: graph, message: "now dim the highlights a little")
    out["chat-node-cold.md"] = SZChatPrompts.nodeColdStart(
        node: grayID.uuidString,
        userMessage: "add a strength slider",
        currentContract: "{\n  \"title\": \"Grayscale\"\n}",
        currentSource: "struct Node {\n    // fixture source\n}")

    // — graph-op seed prompts —
    out["graphop-split-stage.md"] = SZGraphPrompts.splitStage(
        original: "Grayscale Effect", intent: grayPrompt,
        stage: 1, count: 2, source: "// original Node.swift\n",
        contract: kitchenSinkContract, instruction: "a blur stage then a sharpen stage")
    out["graphop-split-stage-bare.md"] = SZGraphPrompts.splitStage(
        original: "Grayscale Effect", intent: grayPrompt,
        stage: 2, count: 2, source: nil, contract: kitchenSinkContract)
    out["graphop-merge.md"] = SZGraphPrompts.merge(
        constituents: [(title: "MacBook Camera", intent: cameraPrompt, source: "// camera source\n"),
                       (title: "Grayscale Effect", intent: grayPrompt, source: nil)],
        contract: kitchenSinkContract, instruction: "merge favouring performance")

    // — the agent_library_index framing —
    out["library-index.md"] = SZPrompts.libraryIndex(
        categories: "## Sources\n- `camera.macos` — the live camera\n")

    // — graphSummary's fallback branches, pinned once for every director framing that embeds it:
    //   an empty prompt node, a NEEDS REBUILD node, no edges, no render endpoint —
    out["director-graph-summary-variants.md"] = SZDirectorPrompt.graphSummary(SZGraph(
        nodes: [
            SZNode(id: SZNodeID(uuidString: "44444444-4444-4444-8444-444444444444")!,
                   kind: .prompt, title: "Untitled", prompt: "", position: SZPoint(x: 0, y: 0)),
            SZNode(id: SZNodeID(uuidString: "55555555-5555-4555-8555-555555555555")!,
                   kind: .generated, title: "Levels", prompt: "Adjust levels.",
                   contract: SZNodeContract(
                       title: "Levels", sfSymbol: "slider.horizontal.3", summary: "Adjusts levels.",
                       inputs: [SZPort(name: "input", type: .texture)],
                       outputs: [SZPort(name: "output", type: .texture, display: true)]),
                   position: SZPoint(x: 1, y: 0), rebuildReason: .contractChanged),
        ]))

    // — the node-compile family, through real procedural dispatches —
    let cold = try await captureRun(.procedural, withDirector: false)
    out["coding-compile-cold.md"] = prompt(in: cold.codingArgvs[0])
    out["dispatch-procedural.txt"] = cold.shape.joined(separator: "\n") + "\n"
    out["argv-claude-cold.txt"] = normalizedArgv(cold.codingArgvs[0])

    let inline = try await captureRun(.procedural, withDirector: false,
                                      libraryIndexText: "## Sources\n- `camera.macos` — the live camera\n")
    out["coding-compile-inline.md"] = prompt(in: inline.codingArgvs[0])
    // opencode rewrites the brief's bare subz tool tokens before dispatch — a real byte transform.
    out["coding-compile-inline-opencode.md"] =
        SZOpenCodeProvider.namespacedSubZTools(in: prompt(in: inline.codingArgvs[0]))

    let preserve = try await captureRun(.procedural, withDirector: false, stagedPieces: [grayID])
    out["coding-compile-preserve.md"] = prompt(in: preserve.codingArgvs[0])

    let contracted = try await captureRun(.procedural, withDirector: false,
                                          grayContract: kitchenSinkContract)
    out["coding-compile-contracted.md"] = prompt(in: contracted.codingArgvs[0])

    // — the agentic flow: decompose, two reconcile rounds, retries with/without a Director note —
    let rich = try await captureRun(
        .agentic, withDirector: true,
        instruction: "make the camera feed grayscale",
        statuses: [grayID: "needsInput: the contract's `mode` options are ambiguous — which value is the default?"],
        inboxOnce: ["node \(grayID.uuidString): the boundary declares `mode` but no options were provided"],
        directorMessagesOnce: [grayID: "Use Rec.709 luma weights."])
    out["director-decompose.md"] = rich.directorPrompts[0]
    out["director-reconcile-r1.md"] = rich.directorPrompts[1]
    out["director-reconcile-r2.md"] = rich.directorPrompts[2]
    out["coding-reconcile-with-note.md"] = prompt(in: rich.codingArgvs[1])   // round 1: note folded in
    out["coding-reconcile-plain.md"] = prompt(in: rich.codingArgvs[2])       // round 2: note consumed
    out["dispatch-agentic.txt"] = rich.shape.joined(separator: "\n") + "\n"
    out["argv-claude-resume.txt"] = normalizedArgv(rich.codingArgvs[1])

    // Bare agentic run: blank instruction → the decompose fallback line; no reported status → the
    // reconcile prompt's "(no status reported)" row and the retry's fallback blocker.
    let bare = try await captureRun(.agentic, withDirector: true)
    out["director-decompose-noinstruction.md"] = bare.directorPrompts[0]
    out["director-reconcile-r1-bare.md"] = bare.directorPrompts[1]
    out["coding-reconcile-bare.md"] = prompt(in: bare.codingArgvs[1])

    // Chat-triggered run: the Director's own chat turn WAS the decompose turn, so the strategy
    // skips straight to dispatch — the reconcile loop still runs.
    let briefed = try await captureRun(.agentic, withDirector: true, directorAlreadyBriefed: true)
    out["dispatch-agentic-briefed.txt"] = briefed.shape.joined(separator: "\n") + "\n"

    return out
}

// MARK: - The pin

/// Every fixture starts with this header; the argv/dispatch fixtures append their normalization
/// note. Headers are constants, so they are compared like every other pinned byte.
private func header(for name: String) -> String {
    let base = "<!-- equivalence-class: byte-identical to main @ 75bd1e4; never edit by hand; "
        + "regen: SZ_WRITE_FIXTURES=Modules/Tests/SZAITests/Fixtures/Equivalence "
        + "swift test --filter SZPromptEquivalence -->\n"
    guard name.hasSuffix(".txt") else { return base }
    return base + "<!-- normalized: -p prompt elided (bytes pinned by the coding-*.md fixtures); "
        + "--session-id/--resume per-process UUIDs replaced by placeholders; project/cache paths are "
        + "the fixed inputs /sz-equivalence/{project,cache} -->\n"
}

@MainActor
@Test func everyRenderedPromptMatchesItsEquivalenceFixture() async throws {
    let files = try await generateFixtures().reduce(into: [String: String]()) {
        $0[$1.key] = header(for: $1.key) + $1.value
    }

    if let dir = ProcessInfo.processInfo.environment["SZ_WRITE_FIXTURES"] {
        let root = URL(filePath: dir)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, text) in files {
            try text.write(to: root.appending(path: name), atomically: true, encoding: .utf8)
        }
        print("[equivalence-fixtures] wrote \(files.count) files to \(dir)")
        return
    }

    let fixturesDir = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "Fixtures/Equivalence")
    for (name, text) in files.sorted(by: { $0.key < $1.key }) {
        let url = fixturesDir.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("missing fixture \(name) — regenerate with SZ_WRITE_FIXTURES")
            continue
        }
        let pinned = try String(contentsOf: url, encoding: .utf8)
        if text != pinned {
            // A 25k blob diff is unreadable — point at the first divergent line instead.
            let a = text.split(separator: "\n", omittingEmptySubsequences: false)
            let b = pinned.split(separator: "\n", omittingEmptySubsequences: false)
            let i = zip(a, b).enumerated().first { $1.0 != $1.1 }?.offset ?? min(a.count, b.count)
            Issue.record("""
                \(name) diverges at line \(i + 1)
                  generated: \(i < a.count ? String(a[i]) : "<ended>")
                  pinned:    \(i < b.count ? String(b[i]) : "<ended>")
                """)
        }
    }

    // A fixture nothing generates is a stale pin — the gate must not carry dead weight silently.
    let onDisk = try FileManager.default.contentsOfDirectory(atPath: fixturesDir.path)
        .filter { !$0.hasPrefix(".") }
    for stray in onDisk where files[stray] == nil {
        Issue.record("fixture \(stray) has no generator — stale pin, delete or re-cover it")
    }
}
