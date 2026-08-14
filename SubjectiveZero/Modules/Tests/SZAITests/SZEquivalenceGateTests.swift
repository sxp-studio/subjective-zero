// SPDX-License-Identifier: AGPL-3.0-only
// THE EQUIVALENCE GATE: the render path — SZBriefRenderer over the shipped agent packs
// (Sources/SZAI/Resources/Agents) — must reproduce, byte for byte, every prompt the
// previous orchestrator rendered, as pinned by the committed fixtures (recorded before that
// orchestrator was deleted; the recording harness went with it). The fixtures are the gate
// and are NEVER edited to make this pass; every render here uses the SAME fixed inputs the
// recording harness used (same sample-anchored ids, prompts, and contract — restated below
// because the recorder kept its world private).
//
// Facts documents are hand-assembled JSON following the SZFacts spec field names. Where a
// value is host context that does not exist yet in the new architecture, the EXACT input the
// recording harness used is stubbed into the facts/delivery — never an approximation of the
// bytes:
//  - chat facts carry `graphJSON` (the chat briefs re-project the live graph; the spec gains
//    the field when the host projection lands),
//  - node-anchored chat carries the host-read contract/source strings verbatim,
//  - graph-op requests carry the recorder's kitchen-sink boundary contract.
//
// The retired strategies' *.txt fixtures (dispatch shape / argv assembly) moved to
// Fixtures/Legacy/ when their subject was deleted — historical, no gate reads them.
import Foundation
import Testing
@testable import SZAI
@testable import SZCore

// MARK: - The recorder's fixed world (mirrors SZPromptEquivalenceTests)

private let cameraID = SZNodeID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let grayID = SZNodeID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let cameraPrompt =
    "Live Mac camera feed delivered as a texture output — the canonical macOS camera source node."
private let grayPrompt = "Convert the incoming camera texture to grayscale (per-pixel luminance)."

private let testsDir = URL(filePath: #filePath).deletingLastPathComponent()
private let fixturesDir = testsDir.appending(path: "Fixtures/Equivalence")
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
        fatalError("equivalence gate: cannot read the sample camera contract at \(url.path)")
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
               position: SZPoint(x: 1, y: 0), rebuildReason: .contractChanged),
    ])

// MARK: - Facts assembly

private func encoded(_ graph: SZGraph) throws -> String {
    String(decoding: try JSONEncoder().encode(graph), as: UTF8.self)
}

/// A facts document from spec-named fields (JSONSerialization: the doc is hand-shaped here
/// exactly because the host that shapes it lands next phase).
private func factsJSON(_ fields: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
}

/// The recorder's fixed reconcile inputs.
private let grayStatus =
    "needsInput: the contract's `mode` options are ambiguous — which value is the default?"
private let fleetInboxLine =
    "node \(grayID.uuidString): the boundary declares `mode` but no options were provided"
private let libraryIndexText = "## Sources\n- `camera.macos` — the live camera\n"

// MARK: - The gate

struct SZEquivalenceGateTests {

    /// Every *.md fixture, rendered through the living path: SZBriefRenderer + the shipped packs.
    private static func renderAll() throws -> [String: String] {
        let renderer = SZBriefRenderer(packRoot: shippedPacksRoot)
        let base = try encoded(fixtureGraph())
        var out: [String: String] = [:]

        // — chat framings —
        out["chat-director-cold.md"] = try renderer.render(
            agent: "director", template: "prompts/chat.md.mustache", kind: .chat,
            factsJSON: factsJSON(["sentMessage": "make it warmer and add a soft glow",
                                  "resuming": false, "graphJSON": base]))
        out["chat-director-resumed.md"] = try renderer.render(
            agent: "director", template: "prompts/chat-resumed.md.mustache", kind: .chat,
            factsJSON: factsJSON(["sentMessage": "now dim the highlights a little",
                                  "resuming": true, "graphJSON": base]))
        out["chat-node-cold.md"] = try renderer.render(
            agent: "coding", template: "prompts/node-chat.md.mustache", kind: .chat,
            factsJSON: factsJSON(["sentMessage": "add a strength slider",
                                  "resuming": false, "nodeSeed": grayID.uuidString]),
            delivery: SZBriefDelivery(
                nodeContract: "{\n  \"title\": \"Grayscale\"\n}",
                nodeSource: "struct Node {\n    // fixture source\n}"))

        // — the node-compile family (.item deliveries against the graph's typed boundary) —
        let itemFacts = try factsJSON(["attempt": 1, "graphJSON": base])
        out["coding-compile-cold.md"] = try renderer.render(
            agent: "coding", template: "prompts/node-compile.md.mustache", kind: .work,
            factsJSON: itemFacts, delivery: SZBriefDelivery(work: grayID.uuidString))
        let inline = try renderer.render(
            agent: "coding", template: "prompts/node-compile.md.mustache", kind: .work,
            factsJSON: itemFacts,
            delivery: SZBriefDelivery(work: grayID.uuidString, libraryIndex: libraryIndexText))
        out["coding-compile-inline.md"] = inline
        // opencode's tool-namespacing is a provider transform applied to the rendered brief —
        // the same real byte transform the recorder pinned.
        out["coding-compile-inline-opencode.md"] = SZOpenCodeProvider.namespacedSubZTools(in: inline)
        out["coding-compile-preserve.md"] = try renderer.render(
            agent: "coding", template: "prompts/node-compile.md.mustache", kind: .work,
            factsJSON: itemFacts,
            delivery: SZBriefDelivery(work: grayID.uuidString, preserveBehavior: true))
        out["coding-compile-contracted.md"] = try renderer.render(
            agent: "coding", template: "prompts/node-compile.md.mustache", kind: .work,
            factsJSON: factsJSON(["attempt": 1,
                                  "graphJSON": encoded(fixtureGraph(grayContract: kitchenSinkContract))]),
            delivery: SZBriefDelivery(work: grayID.uuidString))

        // — the re-grounding retry briefs (.item re-deliveries) —
        out["coding-reconcile-with-note.md"] = try renderer.render(
            agent: "coding", template: "prompts/node-reconcile.md.mustache", kind: .work,
            factsJSON: factsJSON(["attempt": 2, "graphJSON": base, "blocker": grayStatus,
                                  "senderNote": "Use Rec.709 luma weights."]),
            delivery: SZBriefDelivery(work: grayID.uuidString))
        out["coding-reconcile-plain.md"] = try renderer.render(
            agent: "coding", template: "prompts/node-reconcile.md.mustache", kind: .work,
            factsJSON: factsJSON(["attempt": 3, "graphJSON": base, "blocker": grayStatus]),
            delivery: SZBriefDelivery(work: grayID.uuidString))
        // No reported status → the renderer's fallback blocker, same words as before.
        out["coding-reconcile-bare.md"] = try renderer.render(
            agent: "coding", template: "prompts/node-reconcile.md.mustache", kind: .work,
            factsJSON: factsJSON(["attempt": 2, "graphJSON": base]),
            delivery: SZBriefDelivery(work: grayID.uuidString))

        // — the director's build-kind briefs —
        out["director-decompose.md"] = try renderer.render(
            agent: "director", template: "prompts/decompose.md.mustache", kind: .build,
            factsJSON: factsJSON(["graphJSON": base]),
            delivery: SZBriefDelivery(instruction: "make the camera feed grayscale"))
        out["director-decompose-noinstruction.md"] = try renderer.render(
            agent: "director", template: "prompts/decompose.md.mustache", kind: .build,
            factsJSON: factsJSON(["graphJSON": base]))
        out["director-reconcile-r1.md"] = try renderer.render(
            agent: "director", template: "prompts/reconcile.md.mustache", kind: .build,
            factsJSON: factsJSON(["graphJSON": base, "workSet": [grayID.uuidString],
                                  "nodeStatuses": [grayID.uuidString: grayStatus],
                                  "steers": [fleetInboxLine], "round": 1, "roundCap": 2]))
        // Round 2: the inbox drained on round 1; the statuses are the run's last-reported.
        out["director-reconcile-r2.md"] = try renderer.render(
            agent: "director", template: "prompts/reconcile.md.mustache", kind: .build,
            factsJSON: factsJSON(["graphJSON": base, "workSet": [grayID.uuidString],
                                  "nodeStatuses": [grayID.uuidString: grayStatus],
                                  "steers": [String](), "round": 2, "roundCap": 2]))
        out["director-reconcile-r1-bare.md"] = try renderer.render(
            agent: "director", template: "prompts/reconcile.md.mustache", kind: .build,
            factsJSON: factsJSON(["graphJSON": base, "workSet": [grayID.uuidString],
                                  "nodeStatuses": [String: String](),
                                  "steers": [String](), "round": 1, "roundCap": 2]))

        // — graphSummary's fallback branches, through the new path's projection —
        out["director-graph-summary-variants.md"] =
            try SZBriefRenderer.graphSummary(ofJSON: encoded(summaryVariantsGraph))

        // — graph-op seed briefs (.request deliveries) —
        out["graphop-split-stage.md"] = try renderer.render(
            agent: "coding", template: "prompts/split-stage.md.mustache", kind: .request,
            factsJSON: factsJSON(["op": "split", "nodes": [grayID.uuidString]]),
            delivery: SZBriefDelivery(graphOp: SZBriefDelivery.GraphOp(
                original: "Grayscale Effect", intent: grayPrompt, stage: 1, count: 2,
                source: "// original Node.swift\n", contract: kitchenSinkContract,
                instruction: "a blur stage then a sharpen stage")))
        out["graphop-split-stage-bare.md"] = try renderer.render(
            agent: "coding", template: "prompts/split-stage.md.mustache", kind: .request,
            factsJSON: factsJSON(["op": "split", "nodes": [grayID.uuidString]]),
            delivery: SZBriefDelivery(graphOp: SZBriefDelivery.GraphOp(
                original: "Grayscale Effect", intent: grayPrompt, stage: 2, count: 2,
                contract: kitchenSinkContract)))
        out["graphop-merge.md"] = try renderer.render(
            agent: "coding", template: "prompts/merge.md.mustache", kind: .request,
            factsJSON: factsJSON(["op": "merge",
                                  "nodes": [cameraID.uuidString, grayID.uuidString]]),
            delivery: SZBriefDelivery(graphOp: SZBriefDelivery.GraphOp(
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

        return out
    }

    @Test func everyPromptFixtureIsReproducedByTheNewRenderPath() throws {
        let rendered = try Self.renderAll()

        for (name, text) in rendered.sorted(by: { $0.key < $1.key }) {
            let url = fixturesDir.appending(path: name)
            let pinnedFile = try String(contentsOf: url, encoding: .utf8)
            // Strip the pinned header line (a comment constant of the recorder, not a
            // rendered byte); everything after it is the prompt the old path produced.
            guard let headerEnd = pinnedFile.firstIndex(of: "\n") else {
                Issue.record("\(name): fixture carries no header line")
                continue
            }
            let pinned = String(pinnedFile[pinnedFile.index(after: headerEnd)...])
            if text != pinned {
                let a = text.split(separator: "\n", omittingEmptySubsequences: false)
                let b = pinned.split(separator: "\n", omittingEmptySubsequences: false)
                let i = zip(a, b).enumerated().first { $1.0 != $1.1 }?.offset ?? min(a.count, b.count)
                Issue.record("""
                    \(name) diverges at line \(i + 1)
                      new path: \(i < a.count ? String(a[i]) : "<ended>")
                      pinned:   \(i < b.count ? String(b[i]) : "<ended>")
                    """)
            }
        }
    }

    /// The gate covers the whole pinned set: every fixture on disk is rendered — nothing can
    /// drop out silently, and a stale pin (a fixture nothing renders) fails loudly.
    @Test func everyFixtureIsRendered() throws {
        let rendered = try Self.renderAll()
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: fixturesDir.path)
            .filter { !$0.hasPrefix(".") }
        for name in onDisk.sorted() {
            #expect(rendered[name] != nil, "fixture \(name) is not rendered by the gate")
        }
    }

    // The shipped packs' own health — load, shape, briefs, seats, and full validation with
    // the step declarations attached — is pinned in SZAgentPackTests
    // (`theShippedPacksValidateZeroDefects`), not here: this suite is about the bytes.
}
