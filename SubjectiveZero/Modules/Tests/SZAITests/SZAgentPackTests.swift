// SPDX-License-Identifier: AGPL-3.0-only
// The pack loader against scratch packs on disk: per-folder loading keeps healthy siblings
// alive, every validation category fires exactly where it should, step-attached checks go
// through the injected provider seam (and are SKIPPED — visibly — without one), and the
// check() report tells the truth about the tier attained.
import Foundation
import Testing
import SZCore
@testable import SZAI

// MARK: - Scratch packs

/// One agent folder to materialize: `agentJSON` overrides the derived manifest wholesale
/// (for malformed-file tests); `graph` is the raw graph.json (nil = none written); steps
/// are folder name → whether a `Step.swift` is written inside. `prompts` entries write a
/// fixed token-free body; `promptTexts` (name → template text) is for the token-scan tests.
private struct ScratchPack {
    var folder: String
    var id: String? = nil            // manifest id; defaults to the folder name
    var seat: String? = nil
    var agentJSON: String? = nil
    var graph: String? = nil
    var prompts: [String] = []
    var promptTexts: [String: String] = [:]
    var steps: [String: Bool] = [:]
}

private func makeRoot(_ packs: [ScratchPack]) throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "sz-agent-pack-tests-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for pack in packs {
        let dir = root.appending(path: pack.folder)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = pack.agentJSON
            ?? "{\"id\": \"\(pack.id ?? pack.folder)\", \"seat\": \(pack.seat.map { "\"\($0)\"" } ?? "null")}"
        try manifest.write(to: dir.appending(path: "agent.json"), atomically: true, encoding: .utf8)
        if let graph = pack.graph {
            try graph.write(to: dir.appending(path: "graph.json"),
                            atomically: true, encoding: .utf8)
        }
        if !pack.prompts.isEmpty || !pack.promptTexts.isEmpty {
            let prompts = dir.appending(path: "prompts")
            try fm.createDirectory(at: prompts, withIntermediateDirectories: true)
            for name in pack.prompts {
                try "A brief.\n".write(to: prompts.appending(path: name),
                                       atomically: true, encoding: .utf8)
            }
            for (name, text) in pack.promptTexts {
                try text.write(to: prompts.appending(path: name),
                               atomically: true, encoding: .utf8)
            }
        }
        for (name, hasSource) in pack.steps {
            let step = dir.appending(path: "steps/\(name)")
            try fm.createDirectory(at: step, withIntermediateDirectories: true)
            if hasSource {
                try "let step = SZStep(outcomes: [\"go\"]) { _ in \"go\" }\n"
                    .write(to: step.appending(path: "Step.swift"), atomically: true, encoding: .utf8)
            }
        }
    }
    return root
}

/// The director's graph: door(step) → plan(turn) → route(step) → send(dispatch) — the
/// three node forms wired together behind the door.
private func runGraph(brief: String = "plan", to: String = "coding",
                      routeOutcome: String = "yes", edges: String = "") -> String {
    let extra = edges.isEmpty ? "" : ", \(edges)"
    return """
    {"nodes": [
       {"id": "door", "step": "door"},
       {"id": "plan", "turn": {"brief": "\(brief)", "session": "spawn"}},
       {"id": "route", "step": "route"},
       {"id": "send", "dispatch": {"to": "\(to)"}}],
     "edges": [
       {"from": "door", "outcome": "go", "to": "plan"},
       {"from": "plan", "outcome": "ok", "to": "route"},
       {"from": "route", "outcome": "\(routeOutcome)", "to": "send"}\(extra)]}
    """
}

/// A minimal door + one turn.
private func turnGraph(brief: String = "impl") -> String {
    """
    {"nodes": [{"id": "door", "step": "door"},
               {"id": "work", "turn": {"brief": "\(brief)"}}],
     "edges": [{"from": "door", "outcome": "go", "to": "work"}]}
    """
}

private func directorPack(graph: String = runGraph()) -> ScratchPack {
    ScratchPack(folder: "director-a", seat: "director", graph: graph,
                prompts: ["plan.md.mustache"], steps: ["door": true, "route": true])
}

private func codingPack() -> ScratchPack {
    ScratchPack(folder: "coding-b", seat: "coding", graph: turnGraph(),
                prompts: ["impl.md.mustache"], steps: ["door": true])
}

// MARK: - Step-provider stubs

private struct StubFailure: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

private struct StubSteps: SZStepProviding {
    var infos: [String: SZStepDeclarationInfo] = [:]   // "agent/step" → declaration
    var failure: String? = nil
    func declaration(agent: String, step: String) async throws -> SZStepDeclarationInfo? {
        if let failure { throw StubFailure(reason: failure) }
        return infos["\(agent)/\(step)"]
    }
}

/// The stub matching the well-formed packs' doors and gates.
private let healthySteps = StubSteps(infos: [
    "director-a/door": SZStepDeclarationInfo(outcomes: ["go"]),
    "director-a/route": SZStepDeclarationInfo(outcomes: ["yes", "no"]),
    "coding-b/door": SZStepDeclarationInfo(outcomes: ["go"]),
])

private func cleanup(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
}

// MARK: - Loading

@Test func wellFormedTwoAgentPackValidatesClean() async throws {
    let root = try makeRoot([directorPack(), codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    #expect(loaded.defects.isEmpty)
    #expect(loaded.packs.map(\.id) == ["coding-b", "director-a"])
    #expect(loaded.seats == SZSeatAssignment(director: "director-a", coding: "coding-b"))

    let director = try #require(loaded.packs.first { $0.id == "director-a" })
    #expect(director.graph != nil)
    #expect(director.prompts == ["prompts/plan.md.mustache"])
    #expect(director.steps == [SZAgentPack.StepFolder(name: "door", hasSource: true),
                               SZAgentPack.StepFolder(name: "route", hasSource: true)])

    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects.isEmpty, "\(defects)")
}

@Test func unreadablePackReportsWhileSiblingsLoad() async throws {
    let root = try makeRoot([directorPack(), codingPack(),
                             ScratchPack(folder: "broken", agentJSON: "not json")])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    #expect(loaded.packs.map(\.id) == ["coding-b", "director-a"])   // siblings healthy
    #expect(loaded.defects.count == 1)
    guard case .unreadable(let file, let detail) = try #require(loaded.defects.first) else {
        Issue.record("expected .unreadable, got \(loaded.defects)")
        return
    }
    #expect(file == "broken/agent.json")
    #expect(!detail.isEmpty)
}

@Test func misdeclaredIDIsADefect() throws {
    let root = try makeRoot([ScratchPack(folder: "alpha", id: "beta")])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    #expect(loaded.packs.isEmpty)
    #expect(loaded.defects == [.misdeclared(file: "alpha/agent.json",
        detail: "declares id 'beta' — the id IS the folder name")])
}

/// A graph.json that will not decode is a defect BESIDE the pack, never a reason to drop
/// it: the pack keeps its seat and its steps. A folder with NO graph.json is its own
/// honest defect — nothing can ever be delivered to it.
@Test func aBrokenOrMissingGraphReportsWhileThePackKeepsItsSeat() throws {
    var director = directorPack()
    director.graph = "not json"
    let broken = try makeRoot([director, codingPack()])
    defer { cleanup(broken) }
    let loaded = SZAgentPackLoader.load(root: broken)
    let pack = try #require(loaded.packs.first { $0.id == "director-a" })
    #expect(pack.graph == nil)
    #expect(loaded.seats == SZSeatAssignment(director: "director-a", coding: "coding-b"))
    #expect(loaded.defects.count == 1)
    #expect(loaded.defects.contains { defect in
        if case .unreadable(let file, _) = defect { return file == "director-a/graph.json" }
        return false
    })

    var graphless = directorPack()
    graphless.graph = nil
    let missing = try makeRoot([graphless, codingPack()])
    defer { cleanup(missing) }
    let loadedMissing = SZAgentPackLoader.load(root: missing)
    #expect(loadedMissing.defects == [.noGraph(agent: "director-a")])
}

// MARK: - Validation categories

@Test func graphShapeDefectsAreWrappedWithTheAgent() async throws {
    let dangling = runGraph(edges: "{\"from\": \"plan\", \"outcome\": \"error\", \"to\": \"ghost\"}")
    let root = try makeRoot([directorPack(graph: dangling), codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects == [.graphShape(agent: "director-a",
                                    defect: .danglingEdge(from: "plan", to: "ghost"))])
}

@Test func theDoorMustExistAndBeAStep() async throws {
    // No door node at all.
    let doorless = """
    {"nodes": [{"id": "plan", "turn": {"brief": "plan"}}], "edges": []}
    """
    let root = try makeRoot([directorPack(graph: doorless), codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects.contains(.graphShape(agent: "director-a", defect: .noDoor)))

    // A door that is not a step — the entry must be code the author can open.
    let turnDoor = """
    {"nodes": [{"id": "door", "turn": {"brief": "plan"}}], "edges": []}
    """
    let root2 = try makeRoot([directorPack(graph: turnDoor), codingPack()])
    defer { cleanup(root2) }
    let loaded2 = SZAgentPackLoader.load(root: root2)
    let defects2 = await SZAgentPackLoader.validate(packs: loaded2.packs, steps: healthySteps)
    #expect(defects2.contains(.graphShape(agent: "director-a", defect: .doorNotStep)))
}

@Test func edgesIntoTheDoorAndUnreachableNodesAreRefused() async throws {
    let backwards = runGraph(edges: "{\"from\": \"route\", \"outcome\": \"no\", \"to\": \"door\"}")
    let root = try makeRoot([directorPack(graph: backwards), codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects.contains(.graphShape(agent: "director-a",
                                         defect: .edgeIntoDoor(from: "route"))))

    let stranded = """
    {"nodes": [{"id": "door", "step": "door"},
               {"id": "island", "turn": {"brief": "plan"}}],
     "edges": []}
    """
    let root2 = try makeRoot([directorPack(graph: stranded), codingPack()])
    defer { cleanup(root2) }
    let loaded2 = SZAgentPackLoader.load(root: root2)
    let defects2 = await SZAgentPackLoader.validate(packs: loaded2.packs, steps: healthySteps)
    #expect(defects2.contains(.graphShape(agent: "director-a",
                                          defect: .unreachable(nodes: ["island"]))))
}

@Test func turnBriefMustBeAmongThePackPrompts() async throws {
    let root = try makeRoot([directorPack(graph: runGraph(brief: "missing")), codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects == [.missingTemplate(agent: "director-a", node: "plan",
                                         path: "prompts/missing.md.mustache")])
}

@Test func aBriefTokenOutsideTheTableIsADefect() async throws {
    // `{{graph}}` is in the one token table; `{{bogus}}` is nothing — it would ship to the
    // model literal, so the gate names it.
    var director = directorPack()
    director.prompts = []
    director.promptTexts = ["plan.md.mustache": "The graph:\n{{graph}}\n\nDo {{bogus}} now.\n"]
    let root = try makeRoot([director, codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects == [.unknownTemplateToken(agent: "director-a", node: "plan",
                                              template: "prompts/plan.md.mustache",
                                              token: "bogus")])
}

@Test func aMentionedTokenNeedsItsPartialsInThePack() async throws {
    // `{{toolbelt}}` renders from the pack's toolbelt partial — mentioning it without
    // shipping the file is a defect; shipping it validates clean.
    var director = directorPack()
    director.prompts = []
    director.promptTexts = ["plan.md.mustache": "{{graph}}\n\n{{toolbelt}}\n"]
    let root = try makeRoot([director, codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects == [.missingPartial(agent: "director-a", node: "plan",
                                        token: "toolbelt",
                                        partial: "prompts/toolbelt.md.mustache")])

    director.promptTexts["toolbelt.md.mustache"] = "## Tools\nUse them well.\n"
    let repaired = try makeRoot([director, codingPack()])
    defer { cleanup(repaired) }
    let loadedRepaired = SZAgentPackLoader.load(root: repaired)
    let clean = await SZAgentPackLoader.validate(packs: loadedRepaired.packs, steps: healthySteps)
    #expect(clean.isEmpty, "\(clean)")
}

@Test func stepNodeNeedsAFolderWithSource() async throws {
    var director = directorPack()
    director.steps = ["door": true, "route": false]   // folder exists, no Step.swift
    let root = try makeRoot([director, codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects == [.missingStepSource(agent: "director-a", node: "route", step: "route")])
}

@Test func unfilledAndContestedSeatsAreLibraryDefects() async throws {
    // Nobody claims a seat: both report unfilled, and the assignment stays empty.
    let seatless = try makeRoot([ScratchPack(folder: "solo", graph: turnGraph(brief: "p"),
                                             prompts: ["p.md.mustache"],
                                             steps: ["door": true])])
    defer { cleanup(seatless) }
    let none = SZAgentPackLoader.load(root: seatless)
    #expect(none.seats == SZSeatAssignment())
    let unfilled = await SZAgentPackLoader.validate(packs: none.packs, steps: nil)
    #expect(unfilled.contains(.seatUnfilled(seat: .director)))
    #expect(unfilled.contains(.seatUnfilled(seat: .coding)))

    // Two directors: contested, and the contested seat resolves to nobody.
    var second = directorPack()
    second.folder = "director-z"
    let contested = try makeRoot([directorPack(), second, codingPack()])
    defer { cleanup(contested) }
    let loaded = SZAgentPackLoader.load(root: contested)
    #expect(loaded.seats == SZSeatAssignment(director: nil, coding: "coding-b"))
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: StubSteps(infos: [
        "director-a/door": SZStepDeclarationInfo(outcomes: ["go"]),
        "director-a/route": SZStepDeclarationInfo(outcomes: ["yes", "no"]),
        "director-z/door": SZStepDeclarationInfo(outcomes: ["go"]),
        "director-z/route": SZStepDeclarationInfo(outcomes: ["yes", "no"]),
        "coding-b/door": SZStepDeclarationInfo(outcomes: ["go"]),
    ]))
    #expect(defects.contains(.seatContested(seat: .director,
                                            holders: ["director-a", "director-z"])))
}

@Test func dispatchMustTargetAHeldSeat() async throws {
    // "debug" is no seat at all; and a real seat nobody holds is equally unknown.
    let root = try makeRoot([directorPack(graph: runGraph(to: "debug"))])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects.contains(.unknownDispatchSeat(agent: "director-a", node: "send",
                                                  seat: "debug")))

    let unheld = try makeRoot([directorPack()])   // dispatches to "coding"; nobody holds it
    defer { cleanup(unheld) }
    let loaded2 = SZAgentPackLoader.load(root: unheld)
    let defects2 = await SZAgentPackLoader.validate(packs: loaded2.packs, steps: healthySteps)
    #expect(defects2.contains(.unknownDispatchSeat(agent: "director-a", node: "send",
                                                   seat: "coding")))
}

// MARK: - Step-attached checks (through the provider seam)

@Test func edgeOutcomesOutsideTheDeclaredSetAreDefects() async throws {
    let root = try makeRoot([directorPack(graph: runGraph(routeOutcome: "maybe")), codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects == [.undeclaredStepOutcome(agent: "director-a", node: "route",
                                               outcome: "maybe", declared: ["yes", "no"])])
}

@Test func stepDeclaringNothingUnderWiredEdgesIsADefect() async throws {
    let root = try makeRoot([directorPack(), codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    // The stub knows NO declarations — every step with wired edges reports, doors included.
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: StubSteps())
    #expect(defects.contains(.stepDeclaresNothing(agent: "director-a", node: "door", step: "door")))
    #expect(defects.contains(.stepDeclaresNothing(agent: "director-a", node: "route", step: "route")))
    #expect(defects.contains(.stepDeclaresNothing(agent: "coding-b", node: "door", step: "door")))
}

@Test func aThrowingProviderReportsTheStepUnavailable() async throws {
    let root = try makeRoot([directorPack(), codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let broken = StubSteps(failure: "swiftc exploded")
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: broken)
    #expect(defects.contains(.stepUnavailable(agent: "director-a", step: "route",
                                              detail: "swiftc exploded")))
    #expect(defects.allSatisfy {
        if case .stepUnavailable = $0 { return true }
        return false
    })
}

@Test func withoutAProviderStepChecksAreSkippedNeverPassed() async throws {
    // The same pack that defects under StubSteps() must raise NO step defects with nil —
    // and the report must SAY the checks were skipped.
    let root = try makeRoot([directorPack(), codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: nil)
    #expect(defects.isEmpty)

    let report = await SZAgentPackLoader.check(root: root, steps: nil)
    #expect(report.contains("step checks skipped"))
}

// MARK: - The report

@Test func checkReportsValidatesForAHealthyPack() async throws {
    let root = try makeRoot([directorPack(), codingPack()])
    defer { cleanup(root) }
    let report = await SZAgentPackLoader.check(root: root, steps: healthySteps)
    #expect(report.contains("verdict: validates — 2 agents, zero defects"))
    #expect(!report.contains("step checks skipped"))
    #expect(report.contains("agent director-a · seat: director"))
    #expect(report.contains("agent coding-b · seat: coding"))
    // The door's declared outcomes are the agent's front page.
    #expect(report.contains("graph · door: go"))
}

@Test func checkReportsLoadsWhenDefectsRemain() async throws {
    let root = try makeRoot([directorPack(graph: runGraph(brief: "missing")), codingPack()])
    defer { cleanup(root) }
    let report = await SZAgentPackLoader.check(root: root, steps: healthySteps)
    #expect(report.contains("verdict: loads, does not validate"))
    #expect(report.contains("defects (1):"))
}

@Test func checkReportsDoesNotLoadWhenNothingDecodes() async throws {
    let root = try makeRoot([ScratchPack(folder: "broken", agentJSON: "{]")])
    defer { cleanup(root) }
    let report = await SZAgentPackLoader.check(root: root, steps: nil)
    #expect(report.contains("verdict: does not load"))
    #expect(report.contains("step checks skipped"))
}

// MARK: - The shipped packs

private let shippedPacksRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()   // SZAITests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // Modules
    .appending(path: "Sources/SZAI/Resources/Agents")

/// CROSS-TARGET PIN, side A. These declarations are hand-written to match what each
/// shipped-pack `Step.swift` declares, because this target may not import SZRuntime to
/// compile them. Side B is SZRuntimeTests' `SZShippedPackStepTests`, which compiles the SAME
/// sources through the real toolchain and asserts each module's declaration JSON equals
/// these claims, field for field — edit a shipped step and both sides move together.
private let shippedPackSteps = StubSteps(infos: [
    "director/door": SZStepDeclarationInfo(
        outcomes: ["build", "answer", "answer-resumed", "implement"]),
    "director/work-left": SZStepDeclarationInfo(outcomes: ["yes", "no"]),
    "coding/door": SZStepDeclarationInfo(
        outcomes: ["implement", "continue", "chat", "chat-resumed"]),
    "debug/door": SZStepDeclarationInfo(outcomes: ["answer"]),
])

/// The packs the app ships attain the FULL verdict: load clean, seats fill, and — with the
/// step declarations attached — validate to zero defects, token and partial scans included.
@Test func theShippedPacksValidateZeroDefects() async throws {
    let loaded = SZAgentPackLoader.load(root: shippedPacksRoot)
    #expect(loaded.defects.isEmpty, "\(loaded.defects)")
    #expect(loaded.packs.map(\.id) == ["coding", "debug", "director"])
    #expect(loaded.seats == SZSeatAssignment(director: "director", coding: "coding"))

    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: shippedPackSteps)
    #expect(defects.isEmpty, "\(defects)")

    let report = await SZAgentPackLoader.check(root: shippedPacksRoot, steps: shippedPackSteps)
    #expect(report.contains("verdict: validates — 3 agents, zero defects"))
    #expect(!report.contains("step checks skipped"))
}

/// The shipped director: ONE graph whose door decides everything — a granted build goes
/// to work, prose is answered cold or resumed — with the retry round as the dispatch's own
/// leashed settled edge. Pinned so the shape the redesign asked for cannot drift.
@Test func theShippedDirectorDecidesEverythingAtItsDoor() throws {
    let loaded = SZAgentPackLoader.load(root: shippedPacksRoot)
    let director = try #require(loaded.packs.first { $0.id == "director" })
    let graph = try #require(director.graph)
    #expect(graph.door?.form == .step(name: "door"))
    #expect(graph.edge(from: "door", outcome: "build")?.to == "decompose")
    #expect(graph.edge(from: "door", outcome: "answer")?.to == "chat")
    #expect(graph.edge(from: "door", outcome: "answer-resumed")?.to == "chat-resumed")
    // `implement` is the requestBuild ack — deliberately unwired: the run is the reply.
    #expect(graph.edge(from: "door", outcome: "implement") == nil)
    #expect(graph.edge(from: "decompose", outcome: "ok")?.to == "implement")
    let settled = try #require(graph.edge(from: "implement", outcome: "settled"))
    #expect(settled.to == "unresolved")
    #expect(settled.maxTraversals == 2)   // the leash IS the retry budget
    #expect(graph.edge(from: "unresolved", outcome: "yes")?.to == "reconcile")
    #expect(graph.edge(from: "unresolved", outcome: "no") == nil)   // resolved fleet → end
    #expect(graph.edge(from: "reconcile", outcome: "ok")?.to == "implement")
    // The chat turns' endings are the traversal's — what an agent says never routes.
    #expect(graph.edge(from: "chat", outcome: "ok") == nil)
    #expect(graph.edge(from: "chat-resumed", outcome: "ok") == nil)
}

/// Every shipped graph is one connected document behind one door, with clean shape.
@Test func everyShippedGraphIsOneConnectedDocumentBehindItsDoor() throws {
    let loaded = SZAgentPackLoader.load(root: shippedPacksRoot)
    #expect(!loaded.packs.isEmpty)
    for pack in loaded.packs {
        let graph = try #require(pack.graph, "\(pack.id) has no graph")
        #expect(graph.door != nil, "\(pack.id) has no door")
        #expect(graph.defects().isEmpty, "\(pack.id): \(graph.defects())")
    }
}

/// docs/AUTHORING.md's "Your own pack, from scratch" recipe, followed literally: the exact
/// files the tutorial lists must load and validate to ZERO defects through the real
/// loader (door declarations stubbed — the recipe's doors are one-liners the tutorial
/// shows; compiling them is the runtime's business). AUTHORING.md mirrors these bytes —
/// if the rules drift, this test fails before a reader does.
@Test func theAuthoringTutorialsMinimalPackValidates() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "sz-authoring-recipe-\(UUID().uuidString)")
    defer { cleanup(root) }
    let files: [String: String] = [
        "director/agent.json": #"{ "id": "director", "seat": "director" }"#,
        "director/graph.json": """
        {
          "nodes": [
            { "id": "door", "step": "door" },
            { "id": "plan", "turn": { "brief": "plan" } },
            { "id": "implement", "dispatch": { "to": "coding" } }
          ],
          "edges": [
            { "from": "door", "outcome": "build", "to": "plan" },
            { "from": "plan", "outcome": "ok", "to": "implement" }
          ]
        }
        """,
        "director/steps/door/Step.swift": """
        // Every delivery here is the granted build — route it to work.
        let step = SZStep(outcomes: ["build"]) { _ in "build" }
        """,
        "director/prompts/plan.md.mustache": """
        Look at the graph and sharpen each unimplemented node's prompt.

        {{graph}}

        {{instruction}}
        """,
        "coding/agent.json": #"{ "id": "coding", "seat": "coding" }"#,
        "coding/graph.json": """
        {
          "nodes": [
            { "id": "door", "step": "door" },
            { "id": "implement", "turn": { "brief": "implement" } }
          ],
          "edges": [
            { "from": "door", "outcome": "implement", "to": "implement" }
          ]
        }
        """,
        "coding/steps/door/Step.swift": """
        // Assigned work goes straight to the implementation turn.
        let step = SZStep(outcomes: ["implement"]) { _ in "implement" }
        """,
        "coding/prompts/implement.md.mustache": """
        Implement node {{node}}: {{prompt}}

        {{boundary}}
        """,
    ]
    for (path, text) in files {
        let url = root.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    let loaded = SZAgentPackLoader.load(root: root)
    #expect(loaded.defects.isEmpty, "\(loaded.defects)")
    #expect(loaded.seats == SZSeatAssignment(director: "director", coding: "coding"))
    let recipeSteps = StubSteps(infos: [
        "director/door": SZStepDeclarationInfo(outcomes: ["build"]),
        "coding/door": SZStepDeclarationInfo(outcomes: ["implement"]),
    ])
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: recipeSteps)
    #expect(defects.isEmpty, "\(defects)")
    let report = await SZAgentPackLoader.check(root: root, steps: recipeSteps)
    #expect(report.contains("verdict: validates — 2 agents, zero defects"))
}

/// The pin stub claims exactly the steps the shipped packs carry — a new step folder cannot
/// ship unclaimed (validation would skip it silently through the stub's nil), and a stale
/// claim cannot outlive its folder.
@Test func theStepPinCoversExactlyTheShippedStepFolders() throws {
    let loaded = SZAgentPackLoader.load(root: shippedPacksRoot)
    let shipped = Set(loaded.packs.flatMap { pack in
        pack.steps.filter(\.hasSource).map { "\(pack.id)/\($0.name)" }
    })
    #expect(shipped == Set(shippedPackSteps.infos.keys))
}
