// SPDX-License-Identifier: AGPL-3.0-only
// THE BRIEF PINS: every prompt the shipped agent packs render is pinned byte-for-byte by a
// committed fixture, and every shipped template must be served by some pinned render — a
// new template cannot ship unpinned. The pins guard against ACCIDENTAL drift: a refactor,
// a renderer change, a stray edit may not move one shipped byte unnoticed. A DELIBERATE
// prose change re-records its pin in the same commit and says so:
//     SZ_RECORD_BRIEF_PINS=1 swift test --filter SZBriefPinTests
// then review the fixture diff and commit it WITH the template change. An unexplained pin
// diff is a bug. (The fixtures began as the one-message migration's equivalence gate,
// recorded from the previous orchestrator; the renders still use that recorder's fixed
// inputs, spelled as the living model's typed values — text + SZWorld + SZBriefExtras.)
import Foundation
import Testing
@testable import SZAI
@testable import SZCore

// MARK: - The recorder's fixed world (inherited from the migration recorder)

private let cameraID = SZNodeID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let grayID = SZNodeID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let cameraPrompt =
    "Live Mac camera feed delivered as a texture output — the canonical macOS camera source node."
private let grayPrompt = "Convert the incoming camera texture to grayscale (per-pixel luminance)."

private let testsDir = URL(filePath: #filePath).deletingLastPathComponent()
private let fixturesDir = testsDir.appending(path: "Fixtures/BriefPins")
private let shippedPacksRoot = testsDir
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // Modules
    .appending(path: "Sources/SZAI/Resources/Agents")

/// The sample's camera contract, read from the committed .subz exactly as the recorder does.
private let cameraContract: SZNodeContract = {
    let url = testsDir
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // SubjectiveZero
        .appending(path: "Samples/grayscale-prompt.subz/nodes/\(cameraID.uuidString)/node-contract.json")
    guard let data = try? Data(contentsOf: url),
          let contract = try? JSONDecoder().decode(SZNodeContract.self, from: data) else {
        fatalError("brief pins: cannot read the sample camera contract at \(url.path)")
    }
    return contract
}()

/// The recorder's kitchen-sink contract — every `SZBoundaryPrompt` branch.
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

/// The recorder's run graph: two sample nodes + data edge + flow edge + render endpoint.
private func fixtureGraph(grayContract: SZNodeContract? = nil) -> SZGraph {
    SZGraph(
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
}

/// The recorder's graph-summary fallback exercise: empty prompt, NEEDS REBUILD, no edges,
/// no render endpoint.
private let summaryVariantsGraph = SZGraph(
    nodes: [
        SZNode(id: SZNodeID(uuidString: "44444444-4444-4444-8444-444444444444")!,
               kind: .prompt, title: "Untitled", prompt: "", position: SZPoint(x: 0, y: 0)),
        SZNode(id: SZNodeID(uuidString: "55555555-5555-4555-8555-555555555555")!,
               kind: .generated, title: "Levels", prompt: "Adjust levels.",
               contract: SZNodeContract(
                   title: "Levels", sfSymbol: "slider.horizontal.3", summary: "Adjusts levels.",
                   inputs: [SZPort(name: "input", type: .texture)],
                   outputs: [SZPort(name: "output", type: .texture, display: true)]),
               position: SZPoint(x: 1, y: 0),
               buildStamp: SZBuildStamp(portSurface: [], prompt: "Adjust levels.")),   // surface off the stamp → NEEDS REBUILD
    ])

/// The recorder's fixed reconcile inputs.
private let grayStatus =
    "needsInput: the contract's `mode` options are ambiguous — which value is the default?"
private let fleetInboxLine =
    "node \(grayID.uuidString): the boundary declares `mode` but no options were provided"
/// The recorder's fixed mutation delta — one entry per actor kind.
private let reconcileMutations = [
    SZGraphMutation(actor: .user, kind: "connected",
                    subjects: ["MacBook Camera.output → Grayscale Effect.input"]),
    SZGraphMutation(actor: .director, kind: "re-prompted", subjects: ["Grayscale Effect"]),
    SZGraphMutation(actor: .agent(grayID), kind: "toggled display",
                    subjects: ["→ Grayscale Effect.output"]),
]
private let libraryIndexText = "## Sources\n- `camera.macos` — the live camera\n"

// MARK: - The gate

/// Records every pack-relative template path the renderer serves — the coverage scan's
/// truth, wrapped around the SAME renders the byte test pins.
private final class SZServedTemplates: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var paths: Set<String> = []   // "agent/prompts/<file>"
    func note(_ agent: String, _ path: String) {
        lock.lock(); paths.insert("\(agent)/\(path)"); lock.unlock()
    }
}

struct SZBriefPinTests {

    /// Every pinned brief, rendered through the living path: SZBriefRenderer + the shipped
    /// packs, fed the model's own typed values. `serving` observes each template served.
    private static func renderAll(serving served: SZServedTemplates? = nil) throws -> [String: String] {
        let renderer = SZBriefRenderer { agent, path in
            served?.note(agent, path)
            let url = shippedPacksRoot.appending(path: agent).appending(path: path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw SZBriefRenderError.missingTemplate(agent: agent, path: path)
            }
            return text
        }
        let base = fixtureGraph()
        var out: [String: String] = [:]

        // — chat framings —
        out["chat-director-cold.md"] = try renderer.render(
            agent: "director", template: "chat",
            message: "make it warmer and add a soft glow",
            world: SZWorld(graph: base))
        out["chat-director-resumed.md"] = try renderer.render(
            agent: "director", template: "chat-resumed",
            message: "now dim the highlights a little",
            world: SZWorld(graph: base, resuming: true))
        out["chat-node-cold.md"] = try renderer.render(
            agent: "coding", template: "node-chat",
            message: "add a strength slider",
            world: SZWorld(graph: base, node: grayID),
            extras: SZBriefExtras(
                nodeContract: "{\n  \"title\": \"Grayscale\"\n}",
                nodeSource: "struct Node {\n    // fixture source\n}"))

        // — the node-compile family (work deliveries against the graph's typed boundary) —
        let workWorld = SZWorld(graph: base, node: grayID,
                                assignment: SZAssignment(attempt: 1))
        out["coding-compile-cold.md"] = try renderer.render(
            agent: "coding", template: "node-compile", message: "", world: workWorld)
        let inline = try renderer.render(
            agent: "coding", template: "node-compile", message: "", world: workWorld,
            extras: SZBriefExtras(libraryIndex: libraryIndexText))
        out["coding-compile-inline.md"] = inline
        // opencode's tool-namespacing is a provider transform applied to the rendered brief —
        // the same real byte transform the recorder pinned.
        out["coding-compile-inline-opencode.md"] = SZOpenCodeProvider.namespacedSubZTools(in: inline)
        out["coding-compile-preserve.md"] = try renderer.render(
            agent: "coding", template: "node-compile", message: "", world: workWorld,
            extras: SZBriefExtras(preserveBehavior: true))
        out["coding-compile-contracted.md"] = try renderer.render(
            agent: "coding", template: "node-compile", message: "",
            world: SZWorld(graph: fixtureGraph(grayContract: kitchenSinkContract),
                           node: grayID, assignment: SZAssignment(attempt: 1)))

        // — the re-grounding retry briefs (work re-deliveries) —
        out["coding-reconcile-with-note.md"] = try renderer.render(
            agent: "coding", template: "node-reconcile", message: "",
            world: SZWorld(graph: base, statuses: [grayID: grayStatus], node: grayID,
                           assignment: SZAssignment(attempt: 2, note: "Use Rec.709 luma weights.")))
        out["coding-reconcile-plain.md"] = try renderer.render(
            agent: "coding", template: "node-reconcile", message: "",
            world: SZWorld(graph: base, statuses: [grayID: grayStatus], node: grayID,
                           assignment: SZAssignment(attempt: 3)))
        // No reported status → the renderer's fallback blocker, same words as before.
        out["coding-reconcile-bare.md"] = try renderer.render(
            agent: "coding", template: "node-reconcile", message: "",
            world: SZWorld(graph: base, node: grayID, assignment: SZAssignment(attempt: 2)))

        // — the director's build briefs —
        func run(workSet: [SZNodeID] = [], round: Int = 0, roundCap: Int = 0,
                 steers: [String] = [], instruction: String = "") -> SZRun {
            SZRun(workSet: workSet, round: round, roundCap: roundCap,
                  steers: steers, instruction: instruction)
        }
        out["director-decompose.md"] = try renderer.render(
            agent: "director", template: "decompose", message: "",
            world: SZWorld(graph: base, run: run(instruction: "make the camera feed grayscale")))
        out["director-decompose-noinstruction.md"] = try renderer.render(
            agent: "director", template: "decompose", message: "",
            world: SZWorld(graph: base, run: run()))
        out["director-reconcile-r1.md"] = try renderer.render(
            agent: "director", template: "reconcile", message: "",
            world: SZWorld(graph: base, statuses: [grayID: grayStatus],
                           run: run(workSet: [grayID], round: 1, roundCap: 2,
                                    steers: [fleetInboxLine]),
                           mutations: reconcileMutations))
        // Round 2: the inbox drained on round 1; the statuses are the run's last-reported.
        out["director-reconcile-r2.md"] = try renderer.render(
            agent: "director", template: "reconcile", message: "",
            world: SZWorld(graph: base, statuses: [grayID: grayStatus],
                           run: run(workSet: [grayID], round: 2, roundCap: 2)))
        out["director-reconcile-r1-bare.md"] = try renderer.render(
            agent: "director", template: "reconcile", message: "",
            world: SZWorld(graph: base, run: run(workSet: [grayID], round: 1, roundCap: 2)))

        // — graphSummary's fallback branches, through the one summary renderer —
        out["director-graph-summary-variants.md"] =
            SZDirectorPrompt.graphSummary(summaryVariantsGraph)

        // — graph-op seed briefs (the split/merge render bundle) —
        out["graphop-split-stage.md"] = try renderer.render(
            agent: "coding", template: "split-stage", message: "", world: SZWorld(),
            extras: SZBriefExtras(graphOp: SZBriefExtras.GraphOp(
                original: "Grayscale Effect", intent: grayPrompt, stage: 1, count: 2,
                source: "// original Node.swift\n", contract: kitchenSinkContract,
                instruction: "a blur stage then a sharpen stage")))
        out["graphop-split-stage-bare.md"] = try renderer.render(
            agent: "coding", template: "split-stage", message: "", world: SZWorld(),
            extras: SZBriefExtras(graphOp: SZBriefExtras.GraphOp(
                original: "Grayscale Effect", intent: grayPrompt, stage: 2, count: 2,
                contract: kitchenSinkContract)))
        out["graphop-merge.md"] = try renderer.render(
            agent: "coding", template: "merge", message: "", world: SZWorld(),
            extras: SZBriefExtras(graphOp: SZBriefExtras.GraphOp(
                count: 2,
                constituents: [
                    .init(title: "MacBook Camera", intent: cameraPrompt,
                          source: "// camera source\n"),
                    .init(title: "Grayscale Effect", intent: grayPrompt),
                ],
                contract: kitchenSinkContract, instruction: "merge favouring performance")))

        // — the agent_library_index framing —
        out["library-index.md"] = try renderer.libraryIndex(
            agent: "coding", categories: libraryIndexText)

        // — the doors' ask briefs (attempt-0 bytes; the repair wrapper appends only on retries) —
        out["director-triage.md"] = try renderer.render(
            agent: "director", template: "triage",
            message: "make it warmer and add a soft glow",
            world: SZWorld(graph: base))
        out["coding-triage.md"] = try renderer.render(
            agent: "coding", template: "triage",
            message: "add a strength slider",
            world: SZWorld(graph: base, node: grayID))

        // — the edit lane's work order (re-grounded on the node's live files every turn) —
        out["coding-edit.md"] = try renderer.render(
            agent: "coding", template: "edit",
            message: "add a strength slider",
            world: SZWorld(graph: base, node: grayID, resuming: true),
            extras: SZBriefExtras(
                nodeContract: "{\n  \"title\": \"Grayscale\"\n}",
                nodeSource: "struct Node {\n    // fixture source\n}"))

        // — the deliberately bare resumed node chat (the session carries the context) —
        out["chat-node-resumed.md"] = try renderer.render(
            agent: "coding", template: "node-chat-resumed",
            message: "now dim the highlights a little",
            world: SZWorld(graph: base, node: grayID, resuming: true))

        // — the debug agent's whole brief —
        out["chat-debug.md"] = try renderer.render(
            agent: "debug", template: "chat",
            message: "why is the output black?",
            world: SZWorld(graph: base))

        return out
    }

    private static let recordEnv = "SZ_RECORD_BRIEF_PINS"
    private static let pinHeader = "<!-- brief pin; never edit by hand; re-record deliberately: "
        + "SZ_RECORD_BRIEF_PINS=1 swift test --filter SZBriefPinTests -->"

    /// Record mode: rewrite only pins whose BODY differs (each existing header preserved),
    /// create missing ones. NEVER a green run — it fails naming what it wrote, so CI can
    /// never record silently and the fixture diff must be reviewed.
    private static func record(_ rendered: [String: String]) throws {
        var wrote: [String] = []
        for (name, text) in rendered.sorted(by: { $0.key < $1.key }) {
            let url = fixturesDir.appending(path: name)
            if let existing = try? String(contentsOf: url, encoding: .utf8),
               let headerEnd = existing.firstIndex(of: "\n") {
                let header = String(existing[..<headerEnd])
                guard String(existing[existing.index(after: headerEnd)...]) != text else { continue }
                try (header + "\n" + text).write(to: url, atomically: true, encoding: .utf8)
            } else {
                try (pinHeader + "\n" + text).write(to: url, atomically: true, encoding: .utf8)
            }
            wrote.append(name)
        }
        let summary = wrote.isEmpty
            ? "\(recordEnv) set, but every pin already matches — nothing recorded; re-run without the env"
            : "recorded \(wrote.count) pin(s): \(wrote.joined(separator: ", ")) — review the "
                + "fixture diff, commit it WITH the template change, re-run without \(recordEnv)"
        Issue.record("\(summary)")
    }

    @Test func everyBriefPinIsReproduced() throws {
        let rendered = try Self.renderAll()
        if ProcessInfo.processInfo.environment[Self.recordEnv] != nil {
            try Self.record(rendered)
            return
        }
        for (name, text) in rendered.sorted(by: { $0.key < $1.key }) {
            let url = fixturesDir.appending(path: name)
            guard let pinnedFile = try? String(contentsOf: url, encoding: .utf8) else {
                Issue.record("\(name): no pin on disk — a new render is RECORDED deliberately (\(Self.recordEnv)=1 swift test --filter SZBriefPinTests), then committed with its template")
                continue
            }
            // Strip the pin header line (a comment, not a rendered byte); everything after
            // it is the pinned prompt.
            guard let headerEnd = pinnedFile.firstIndex(of: "\n") else {
                Issue.record("\(name): pin carries no header line")
                continue
            }
            let pinned = String(pinnedFile[pinnedFile.index(after: headerEnd)...])
            if text != pinned {
                let a = text.split(separator: "\n", omittingEmptySubsequences: false)
                let b = pinned.split(separator: "\n", omittingEmptySubsequences: false)
                let i = zip(a, b).enumerated().first { $1.0 != $1.1 }?.offset ?? min(a.count, b.count)
                Issue.record("""
                    \(name) diverges at line \(i + 1)
                      rendered: \(i < a.count ? String(a[i]) : "<ended>")
                      pinned:   \(i < b.count ? String(b[i]) : "<ended>")
                    accidental drift is a bug — fix the code; a DELIBERATE prose change re-records \
                    its pin (\(Self.recordEnv)=1 swift test --filter SZBriefPinTests) and commits \
                    the fixture diff with the template change
                    """)
            }
        }
    }

    /// Coverage, direction one: every pin on disk is rendered — nothing drops out silently,
    /// and a stale pin (a fixture nothing renders) fails loudly.
    @Test func everyPinIsRendered() throws {
        let rendered = try Self.renderAll()
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: fixturesDir.path)
            .filter { !$0.hasPrefix(".") }
        for name in onDisk.sorted() {
            #expect(rendered[name] != nil,
                    "pin \(name) is rendered by nothing — if its render was removed on purpose, delete the fixture with it")
        }
    }

    /// Coverage, direction two — the inversion, with NO exempt list: every shipped
    /// template must be served by some pinned render (directly, or as a partial another
    /// render pulls in). A template nothing serves is a brief that can drift unpinned —
    /// add a render to `renderAll` and record its pin.
    @Test func everyShippedTemplateIsPinned() throws {
        let served = SZServedTemplates()
        _ = try Self.renderAll(serving: served)
        let fm = FileManager.default
        for agent in try fm.contentsOfDirectory(atPath: shippedPacksRoot.path).sorted() {
            let promptsDir = shippedPacksRoot.appending(path: agent).appending(path: "prompts")
            guard let files = try? fm.contentsOfDirectory(atPath: promptsDir.path) else { continue }
            for file in files.sorted() where file.hasSuffix(".md.mustache") {
                #expect(served.paths.contains("\(agent)/prompts/\(file)"),
                        "\(agent)/prompts/\(file) is served by no pinned render")
            }
        }
    }

    // The shipped packs' own health — load, shape, briefs, seats, and full validation with
    // the step declarations attached — is pinned in SZAgentPackTests
    // (`theShippedPacksValidateZeroDefects`), not here: this suite is about the bytes.
}
