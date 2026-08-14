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
/// (for malformed-file tests); graphs are filename stem → raw JSON; steps are folder name →
/// whether a `Step.swift` is written inside. `prompts` entries write a fixed token-free
/// body; `promptTexts` (name → template text) is for the token-scan tests.
private struct ScratchPack {
    var folder: String
    var id: String? = nil            // manifest id; defaults to the folder name
    var seat: String? = nil
    var defaults: [String: String]? = nil   // manifest `defaults` (kind → graph name)
    var agentJSON: String? = nil
    var graphs: [String: String] = [:]
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
        let defaults = pack.defaults.map { entries in
            ", \"defaults\": {" + entries.sorted(by: { $0.key < $1.key })
                .map { "\"\($0.key)\": \"\($0.value)\"" }.joined(separator: ", ") + "}"
        } ?? ""
        let manifest = pack.agentJSON
            ?? "{\"id\": \"\(pack.id ?? pack.folder)\", \"seat\": \(pack.seat.map { "\"\($0)\"" } ?? "null")\(defaults)}"
        try manifest.write(to: dir.appending(path: "agent.json"), atomically: true, encoding: .utf8)
        if !pack.graphs.isEmpty {
            let graphs = dir.appending(path: "graphs")
            try fm.createDirectory(at: graphs, withIntermediateDirectories: true)
            for (stem, json) in pack.graphs {
                try json.write(to: graphs.appending(path: "\(stem).json"),
                               atomically: true, encoding: .utf8)
            }
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
                try "let step = SZCondition { _ in true }\n"
                    .write(to: step.appending(path: "Step.swift"), atomically: true, encoding: .utf8)
            }
        }
    }
    return root
}

/// A minimal one-turn graph routing `kind` — a door and the turn behind it.
private func turnGraph(name: String, kind: String = "build",
                       brief: String = "prompts/plan.md.mustache",
                       edges: String = "") -> String {
    let extra = edges.isEmpty ? "" : ", \(edges)"
    return """
    {"name": "\(name)",
     "nodes": [{"id": "message", "onMessage": {}},
               {"id": "plan", "turn": {"brief": "\(brief)", "session": "spawn"}}],
     "edges": [{"from": "message", "outcome": "\(kind)", "to": "plan"}\(extra)]}
    """
}

/// The director's run graph: turn → step → dispatch, the three node forms wired together.
private func runGraph(items: String = "workSet", to: String = "coding",
                      routeOutcome: String = "yes") -> String {
    """
    {"name": "run",
     "nodes": [
       {"id": "message", "onMessage": {}},
       {"id": "plan", "turn": {"brief": "prompts/plan.md.mustache", "session": "spawn"}},
       {"id": "route", "step": "route"},
       {"id": "send", "dispatch": {"to": "\(to)", "items": "\(items)"}}],
     "edges": [
       {"from": "message", "outcome": "build", "to": "plan"},
       {"from": "plan", "outcome": "ok", "to": "route"},
       {"from": "route", "outcome": "\(routeOutcome)", "to": "send"}]}
    """
}

private func directorPack(graph: String = runGraph()) -> ScratchPack {
    ScratchPack(folder: "director-a", seat: "director", graphs: ["run": graph],
                prompts: ["plan.md.mustache"], steps: ["route": true])
}

private func codingPack() -> ScratchPack {
    ScratchPack(folder: "coding-b", seat: "coding",
                graphs: ["work": turnGraph(name: "work", kind: "work",
                                           brief: "prompts/impl.md.mustache")],
                prompts: ["impl.md.mustache"])
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

/// The stub matching the well-formed pack: `route` declares yes/no over build facts.
private let healthySteps = StubSteps(infos: [
    "director-a/route": SZStepDeclarationInfo(outcomes: ["yes", "no"], facts: "build"),
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
    #expect(director.graphs.map(\.name) == ["run"])
    #expect(director.prompts == ["prompts/plan.md.mustache"])
    #expect(director.steps == [SZAgentPack.StepFolder(name: "route", hasSource: true)])

    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects.isEmpty)
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

/// A graph file that will not decode is a defect BESIDE the folder's healthy graphs, never
/// a reason to drop the pack: the pack keeps its seat, its healthy graphs, and its steps —
/// and two bad graph files report two defects, not first-error.
@Test func badGraphFilesReportWhileThePackKeepsItsSeatAndSiblings() throws {
    var director = directorPack()
    director.graphs["junk"] = "not json"
    director.graphs["liar"] = turnGraph(name: "other")   // names itself unlike its file
    let root = try makeRoot([director, codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)

    // The pack survives with exactly its healthy graphs, and the seat stays filled.
    let pack = try #require(loaded.packs.first { $0.id == "director-a" })
    #expect(pack.graphs.map(\.name) == ["run"])
    #expect(pack.steps == [SZAgentPack.StepFolder(name: "route", hasSource: true)])
    #expect(loaded.seats == SZSeatAssignment(director: "director-a", coding: "coding-b"))

    // BOTH defects report — one bad graph never hides another.
    #expect(loaded.defects.count == 2)
    #expect(loaded.defects.contains { defect in
        if case .unreadable(let file, _) = defect { return file == "director-a/graphs/junk.json" }
        return false
    })
    #expect(loaded.defects.contains(.misdeclared(file: "director-a/graphs/liar.json",
        detail: "names itself 'other' — the name IS the filename")))
}

// MARK: - Validation categories

@Test func graphShapeDefectsAreWrappedWithTheGraphName() async throws {
    let dangling = turnGraph(name: "run",
                             edges: "{\"from\": \"plan\", \"outcome\": \"ok\", \"to\": \"ghost\"}")
    let root = try makeRoot([directorPack(graph: dangling), codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects == [.graphShape(agent: "director-a", graph: "run",
                                    defect: .danglingEdge(from: "plan", to: "ghost"))])
}

@Test func twoGraphsRoutingOneKindIsACoinToss() async throws {
    // The variant era's `defaults` key existed to break this tie. A strategy is now a route
    // INSIDE a graph, so the tie has no legitimate reading and is simply refused.
    var director = directorPack(graph: turnGraph(name: "run"))
    director.graphs["alt"] = turnGraph(name: "alt")
    let root = try makeRoot([director, codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects == [.kindRoutedTwice(agent: "director-a", kind: .build,
                                         graphs: ["alt", "run"])])
}

@Test func severalDocumentsAreFineWhenTheyRouteDisjointKinds() async throws {
    // Merging kinds into one file is ALLOWED, never required: an agent may still spread
    // its lanes over several documents as long as each kind has one destination.
    var director = directorPack(graph: turnGraph(name: "run"))
    director.graphs["talk"] = turnGraph(name: "talk", kind: "message")
    let root = try makeRoot([director, codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects.isEmpty, "\(defects)")

    let pack = try #require(loaded.packs.first { $0.id == "director-a" })
    #expect(pack.graph(routing: .build)?.name == "run")
    #expect(pack.graph(routing: .message)?.name == "talk")
    #expect(pack.graph(routing: .work) == nil)
}

@Test func aRetiredDefaultsKeyIsRefusedByName() throws {
    // Silently ignoring it would leave an author believing they still steer which graph
    // answers what — the same policy the retired `entry`/`kind` graph keys get.
    let root = try makeRoot([ScratchPack(folder: "alpha",
        agentJSON: "{\"id\": \"alpha\", \"seat\": null, \"defaults\": {\"build\": \"g\"}}")])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    #expect(loaded.packs.isEmpty)
    #expect(loaded.defects.count == 1)
    if case .unreadable(let file, let detail) = loaded.defects.first {
        #expect(file == "alpha/agent.json")
        #expect(detail.contains("retired"))
    } else {
        Issue.record("expected an unreadable defect, got \(loaded.defects)")
    }
}

@Test func turnBriefMustBeAmongThePackPrompts() async throws {
    let root = try makeRoot([
        directorPack(graph: turnGraph(name: "run", brief: "prompts/missing.md.mustache")),
        codingPack(),
    ])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects == [.missingTemplate(agent: "director-a", graph: "run", node: "plan",
                                         path: "prompts/missing.md.mustache")])
}

@Test func aBriefTokenOutsideTheKindNamespaceIsADefect() async throws {
    // `{{graph}}` is a build token; `{{bogus}}` is nothing — it would ship to the model
    // literal, so the gate names it.
    var director = directorPack()
    director.prompts = []
    director.promptTexts = ["plan.md.mustache": "The graph:\n{{graph}}\n\nDo {{bogus}} now.\n"]
    let root = try makeRoot([director, codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects == [.unknownTemplateToken(agent: "director-a", graph: "run", node: "plan",
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
    #expect(defects == [.missingPartial(agent: "director-a", graph: "run", node: "plan",
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
    director.steps = ["route": false]   // folder exists, no Step.swift
    let root = try makeRoot([director, codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects == [.missingStepSource(agent: "director-a", graph: "run", node: "route",
                                           step: "route")])
}

@Test func unfilledAndContestedSeatsAreLibraryDefects() async throws {
    // Nobody claims a seat: both report unfilled, and the assignment stays empty.
    let seatless = try makeRoot([ScratchPack(folder: "solo",
                                             graphs: ["chat": turnGraph(name: "chat", kind: "message",
                                                                        brief: "prompts/p.md.mustache")],
                                             prompts: ["p.md.mustache"])])
    defer { cleanup(seatless) }
    let none = SZAgentPackLoader.load(root: seatless)
    #expect(none.seats == SZSeatAssignment())
    let unfilled = await SZAgentPackLoader.validate(packs: none.packs, steps: nil)
    #expect(unfilled.contains(.seatUnfilled(seat: .director)))
    #expect(unfilled.contains(.seatUnfilled(seat: .coding)))

    // Two directors: contested, and the contested seat resolves to nobody.
    var second = directorPack()
    second.folder = "director-z"
    second.graphs = ["run": runGraph()]
    let contested = try makeRoot([directorPack(), second, codingPack()])
    defer { cleanup(contested) }
    let loaded = SZAgentPackLoader.load(root: contested)
    #expect(loaded.seats == SZSeatAssignment(director: nil, coding: "coding-b"))
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects.contains(.seatContested(seat: .director,
                                            holders: ["director-a", "director-z"])))
}

@Test func dispatchMustTargetAHeldSeat() async throws {
    // "debug" is no seat at all; and a real seat nobody holds is equally unknown.
    let root = try makeRoot([directorPack(graph: runGraph(to: "debug"))])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects.contains(.unknownDispatchSeat(agent: "director-a", graph: "run",
                                                  node: "send", seat: "debug")))

    let unheld = try makeRoot([directorPack()])   // dispatches to "coding"; nobody holds it
    defer { cleanup(unheld) }
    let loaded2 = SZAgentPackLoader.load(root: unheld)
    let defects2 = await SZAgentPackLoader.validate(packs: loaded2.packs, steps: healthySteps)
    #expect(defects2.contains(.unknownDispatchSeat(agent: "director-a", graph: "run",
                                                   node: "send", seat: "coding")))
}

@Test func dispatchItemsFactMustExistAndBeStringListTyped() async throws {
    let unknown = try makeRoot([directorPack(graph: runGraph(items: "nope")), codingPack()])
    defer { cleanup(unknown) }
    let loaded = SZAgentPackLoader.load(root: unknown)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects == [.dispatchItemsFact(agent: "director-a", graph: "run", node: "send",
                                           fact: "nope",
                                           detail: "no 'build' fact by that name")])

    // `round` IS a build fact — but an Int one, and a dispatch fans out over [String].
    let wrongType = try makeRoot([directorPack(graph: runGraph(items: "round")), codingPack()])
    defer { cleanup(wrongType) }
    let loaded2 = SZAgentPackLoader.load(root: wrongType)
    let defects2 = await SZAgentPackLoader.validate(packs: loaded2.packs, steps: healthySteps)
    #expect(defects2 == [.dispatchItemsFact(agent: "director-a", graph: "run", node: "send",
                                            fact: "round",
                                            detail: "typed Int, a dispatch needs [String]")])
}

// MARK: - Step-attached checks (through the provider seam)

@Test func edgeOutcomesOutsideTheDeclaredSetAreDefects() async throws {
    let root = try makeRoot([directorPack(graph: runGraph(routeOutcome: "maybe")), codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: healthySteps)
    #expect(defects == [.undeclaredStepOutcome(agent: "director-a", graph: "run", node: "route",
                                               outcome: "maybe", declared: ["yes", "no"])])
}

@Test func stepFactsKindMustMatchTheGraphKind() async throws {
    let root = try makeRoot([directorPack(), codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let chatty = StubSteps(infos: [
        "director-a/route": SZStepDeclarationInfo(outcomes: ["yes", "no"], facts: "message"),
    ])
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: chatty)
    #expect(defects == [.stepFactsMismatch(agent: "director-a", graph: "run", node: "route",
                                           step: "route", declared: "message")])

    // A declaration WITHOUT a facts kind is refused too: every SDK path stamps the kind,
    // so an unstamped declaration is hand-rolled — the very case the gate exists for.
    let untyped = StubSteps(infos: [
        "director-a/route": SZStepDeclarationInfo(outcomes: ["yes", "no"]),
    ])
    let refused = await SZAgentPackLoader.validate(packs: loaded.packs, steps: untyped)
    #expect(refused == [.stepFactsMismatch(agent: "director-a", graph: "run", node: "route",
                                           step: "route", declared: "(none)")])
}

@Test func stepDeclaringNothingUnderWiredEdgesIsADefect() async throws {
    let root = try makeRoot([directorPack(), codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    // The stub knows no declaration for route → "declares nothing"; run wires an edge off it.
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: StubSteps())
    #expect(defects == [.stepDeclaresNothing(agent: "director-a", graph: "run", node: "route",
                                             step: "route")])
}

@Test func aThrowingProviderReportsTheStepUnavailable() async throws {
    let root = try makeRoot([directorPack(), codingPack()])
    defer { cleanup(root) }
    let loaded = SZAgentPackLoader.load(root: root)
    let broken = StubSteps(failure: "swiftc exploded")
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: broken)
    #expect(defects == [.stepUnavailable(agent: "director-a", step: "route",
                                         detail: "swiftc exploded")])
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
    #expect(report.contains("graph run · build"))
    #expect(report.contains("graph work · work"))
}

@Test func checkReportsLoadsWhenDefectsRemain() async throws {
    let root = try makeRoot([
        directorPack(graph: turnGraph(name: "run", brief: "prompts/missing.md.mustache")),
        codingPack(),
    ])
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
    "director/work-left": SZStepDeclarationInfo(outcomes: ["yes", "no"], facts: "build"),
    "director/resuming": SZStepDeclarationInfo(outcomes: ["yes", "no"], facts: "message"),
    "coding/retrying": SZStepDeclarationInfo(outcomes: ["yes", "no"], facts: "work"),
    "coding/resuming": SZStepDeclarationInfo(outcomes: ["yes", "no"], facts: "message"),
    "coding/request-op": SZStepDeclarationInfo(outcomes: ["split", "merge"], facts: "request"),
])

/// The packs the app ships attain the FULL verdict: load clean, seats fill, and — with the
/// step declarations attached — validate to zero defects, token and partial scans included.
/// The `debug` pack rides along seatless: the pure-authoring proof (zero Swift anywhere).
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

/// The director ships ONE document routing every kind it accepts, with the three build
/// strategies as ROUTES off a `strategy` step rather than as separate files. This is the
/// shape the "all my steps in one graph" complaint asked for, pinned.
@Test func theShippedDirectorIsOneDocumentRoutingEveryKind() throws {
    let loaded = SZAgentPackLoader.load(root: shippedPacksRoot)
    let director = try #require(loaded.packs.first { $0.id == "director" })
    #expect(director.graphs.map(\.name) == ["director"])
    let graph = try #require(director.graph(routing: .build))
    #expect(Set(graph.routes.keys) == [.message, .build])
    #expect(graph.routes[.message] == "triage")
    // V1 ships ONE build lane — a work message routes straight into decompose, and the
    // retry round is the dispatch's own leashed settled edge. No strategy router: a
    // preference is not a decision, and anyone who wants variant lanes authors them
    // (the runVariant fact stays as that seam).
    #expect(graph.routes[.build] == "decompose")
    #expect(graph.edge(from: "decompose", outcome: "ok")?.to == "implement")
    let settled = try #require(graph.edge(from: "implement", outcome: "settled"))
    #expect(settled.to == "unresolved")
    #expect(settled.maxTraversals == 2)   // the leash IS the retry budget
    #expect(graph.edge(from: "unresolved", outcome: "yes")?.to == "reconcile")
    #expect(graph.edge(from: "unresolved", outcome: "no") == nil)   // resolved fleet → end
    #expect(graph.edge(from: "reconcile", outcome: "ok")?.to == "implement")
}

/// The message lane: TRIAGE rules on the prose first — `answer` routes into the resuming
/// fork whose turns END the traversal, `implement` fires the requestBuild effect as pure
/// config and ends at the ask. No post-turn ruling exists; what an agent says never routes.
@Test func theShippedMessageLaneTriagesBeforeAnyTurn() throws {
    let loaded = SZAgentPackLoader.load(root: shippedPacksRoot)
    let director = try #require(loaded.packs.first { $0.id == "director" })
    let graph = try #require(director.graph(routing: .message))
    #expect(graph.node("triage")?.form == .ask(.init(
        prompt: "prompts/triage.md.mustache",
        outcomes: ["answer", "implement"],
        effects: ["implement": ["requestBuild"]])))
    #expect(graph.edge(from: "triage", outcome: "answer")?.to == "resuming")
    #expect(graph.edge(from: "triage", outcome: "implement") == nil)   // effect + end
    #expect(graph.edge(from: "resuming", outcome: "no")?.to == "cold")
    #expect(graph.edge(from: "resuming", outcome: "yes")?.to == "resumed")
    #expect(graph.edge(from: "cold", outcome: "ok") == nil)      // the turn's ending is the end
    #expect(graph.edge(from: "resumed", outcome: "ok") == nil)
    #expect(graph.kinds(reaching: "triage") == [.message])
}

/// The rule the whole change exists to enforce, asserted over the library generically — no
/// agent named, so a new pack is covered by existing: every shipped graph has exactly one
/// door, every node hangs off it, and no node straddles two facts lanes.
@Test func everyShippedGraphIsOneConnectedLanePureDocument() throws {
    let loaded = SZAgentPackLoader.load(root: shippedPacksRoot)
    #expect(!loaded.packs.isEmpty)
    for pack in loaded.packs {
        for graph in pack.graphs {
            let door = try #require(graph.messageNode, "\(pack.id)/\(graph.name) has no door")
            #expect(!graph.routes.isEmpty, "\(pack.id)/\(graph.name) routes nothing")
            for node in graph.nodes where node.id != door.id {
                #expect(!graph.kinds(reaching: node.id).isEmpty,
                        "\(pack.id)/\(graph.name): '\(node.id)' is unreachable")
                #expect(graph.kinds(reaching: node.id).count == 1,
                        "\(pack.id)/\(graph.name): '\(node.id)' straddles lanes")
            }
        }
    }
}

/// docs/AUTHORING.md's "Your own pack, from scratch" recipe, followed literally: the exact
/// six files the tutorial lists must load and validate to ZERO defects through the real
/// loader. The tutorial was proven by following it; this pin keeps it true — if a loader
/// rule drifts, this test fails before a reader does. (The recipe has no step nodes, so a
/// bare stub provider exercises the full validation honestly.)
@Test func theAuthoringTutorialsMinimalPackValidates() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "sz-authoring-recipe-\(UUID().uuidString)")
    defer { cleanup(root) }
    let files: [String: String] = [
        "director/agent.json": #"{ "id": "director", "seat": "director" }"#,
        "director/graphs/build.json": """
        {
          "name": "build",
          "nodes": [
            { "id": "message", "onMessage": {} },
            { "id": "plan", "turn": { "brief": "prompts/plan.md.mustache" } },
            { "id": "implement", "dispatch": { "to": "coding", "items": "workSet" } }
          ],
          "edges": [
            { "from": "message", "outcome": "build", "to": "plan" },
            { "from": "plan", "outcome": "ok", "to": "implement" }
          ]
        }
        """,
        "director/prompts/plan.md.mustache": """
        Look at the graph and sharpen each unimplemented node's prompt.

        {{graph}}

        {{instruction}}
        """,
        "coding/agent.json": #"{ "id": "coding", "seat": "coding" }"#,
        "coding/graphs/work.json": """
        {
          "name": "work",
          "nodes": [
            { "id": "message", "onMessage": {} },
            { "id": "implement", "turn": { "brief": "prompts/implement.md.mustache" } }
          ],
          "edges": [ { "from": "message", "outcome": "work", "to": "implement" } ]
        }
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
    let defects = await SZAgentPackLoader.validate(packs: loaded.packs, steps: StubSteps())
    #expect(defects.isEmpty, "\(defects)")
    let report = await SZAgentPackLoader.check(root: root, steps: StubSteps())
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
