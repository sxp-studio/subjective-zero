// SPDX-License-Identifier: AGPL-3.0-only
// Loads a ROOT of agent packs and validates the library as a whole. Loading collects, never
// first-errors: an unreadable pack becomes a defect while its siblings load, and a broken
// graph.json becomes a defect while the folder's seat still loads. Only a broken agent.json
// drops a pack — without its manifest a folder has no identity. A pack root is user
// content, never a reason to crash.
//
// Split of labor: SZAgentGraph.defects() checks graph SHAPE; validate(packs:steps:) checks
// everything needing pack or library context — briefs (existence, the one token table, the
// partials a mentioned token pulls), step folders, seats, dispatch targets, and (through
// the injected SZStepProviding seam) the compiled steps' declared outcomes. With no
// provider those step-attached checks are SKIPPED and the report says so.
import Foundation
import SZCore

// MARK: - Defects

/// Everything pack loading + library validation can refuse, one case per category.
/// (`Error` so a file-level decode can carry one as a `Result` failure.)
public enum SZAgentPackDefect: Error, Sendable, Equatable, CustomStringConvertible {
    /// A file that would not read or decode; `detail` carries the underlying error.
    case unreadable(file: String, detail: String)
    /// A file that decoded but lies about itself (an id that isn't the folder name).
    case misdeclared(file: String, detail: String)
    /// The folder has no graph.json — nothing can ever be delivered to this agent.
    case noGraph(agent: String)
    /// A graph-shape defect (`SZAgentGraph.defects()`), wrapped with its home.
    case graphShape(agent: String, defect: SZAgentGraphDefect)
    /// A turn's `brief` stem names no file in the pack's prompt inventory.
    case missingTemplate(agent: String, node: String, path: String)
    /// A brief mentions a `{{token}}` outside the one token table — it would ship literal.
    case unknownTemplateToken(agent: String, node: String, template: String, token: String)
    /// A brief mentions a token whose section renders from a pack partial the prompt
    /// inventory does not carry.
    case missingPartial(agent: String, node: String, token: String, partial: String)
    /// A step node names a folder with no `Step.swift` (or no folder at all).
    case missingStepSource(agent: String, node: String, step: String)
    /// Library level: no loaded agent holds this seat.
    case seatUnfilled(seat: SZAgentSeat)
    /// Library level: more than one loaded agent claims this seat.
    case seatContested(seat: SZAgentSeat, holders: [String])
    /// A dispatch's `to` names no seat any loaded agent holds.
    case unknownDispatchSeat(agent: String, node: String, seat: String)
    /// An outcome-labeled edge leaves a step on an outcome its declaration never produces.
    case undeclaredStepOutcome(agent: String, node: String, outcome: String, declared: [String])
    /// A step declares no outcomes, yet the graph wires outcome-labeled edges from it.
    case stepDeclaresNothing(agent: String, node: String, step: String)
    /// The step provider could not produce a declaration (compile/load failure).
    case stepUnavailable(agent: String, step: String, detail: String)

    public var description: String {
        switch self {
        case .unreadable(let file, let detail):
            "\(file) would not read: \(detail)"
        case .misdeclared(let file, let detail):
            "\(file) misdeclares itself: \(detail)"
        case .noGraph(let agent):
            "\(agent) has no graph.json — nothing can be delivered to it"
        case .graphShape(let agent, let defect):
            "\(agent)/graph.json: \(defect)"
        case .missingTemplate(let agent, let node, let path):
            "\(agent) node '\(node)': brief '\(path)' is not among the pack's prompts"
        case .unknownTemplateToken(let agent, let node, let template, let token):
            "\(agent) node '\(node)': \(template) mentions '{{\(token)}}', a token nothing substitutes"
        case .missingPartial(let agent, let node, let token, let partial):
            "\(agent) node '\(node)': '{{\(token)}}' renders from '\(partial)', which is not among the pack's prompts"
        case .missingStepSource(let agent, let node, let step):
            "\(agent) node '\(node)': steps/\(step) has no Step.swift"
        case .seatUnfilled(let seat):
            "no loaded agent holds the \(seat.rawValue) seat"
        case .seatContested(let seat, let holders):
            "the \(seat.rawValue) seat is contested: \(holders.joined(separator: ", "))"
        case .unknownDispatchSeat(let agent, let node, let seat):
            "\(agent) node '\(node)': dispatches to '\(seat)', a seat no loaded agent holds"
        case .undeclaredStepOutcome(let agent, let node, let outcome, let declared):
            "\(agent) node '\(node)': edge leaves on '\(outcome)', but the step declares \(declared)"
        case .stepDeclaresNothing(let agent, let node, let step):
            "\(agent) node '\(node)': steps/\(step) declares no outcomes, yet edges leave it"
        case .stepUnavailable(let agent, let step, let detail):
            "\(agent)/steps/\(step) has no declaration: \(detail)"
        }
    }
}

/// What loading a root produced: every pack that decoded, the load-tier defects of those
/// that didn't, and the seats as resolved over the loaded set (nil where unfilled or
/// contested — `validate` reports which).
public struct SZAgentPackLoadResult: Sendable {
    public var packs: [SZAgentPack]
    public var defects: [SZAgentPackDefect]
    public var seats: SZSeatAssignment

    public init(packs: [SZAgentPack] = [], defects: [SZAgentPackDefect] = [],
                seats: SZSeatAssignment = SZSeatAssignment()) {
        self.packs = packs
        self.defects = defects
        self.seats = seats
    }
}

// MARK: - The loader

public enum SZAgentPackLoader {
    /// The pack root this module SHIPS (`Resources/Agents`, bundled whole via `.copy`).
    /// nil only in a build whose bundle carries no resources. Callers that want the packs
    /// user-editable materialize a copy and load that instead — the host owns that policy.
    public static var bundledRoot: URL? {
        Bundle.module.url(forResource: "Agents", withExtension: nil)
    }

    /// Load every agent folder under `root`. Sorted everywhere a directory is traversed —
    /// filesystem enumeration order may not decide anything, including defect order.
    public static func load(root: URL) -> SZAgentPackLoadResult {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            // Dot-folders are the filesystem's or the host's business, never an agent.
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var packs: [SZAgentPack] = []
        var defects: [SZAgentPackDefect] = []
        if folders.isEmpty {
            defects.append(.unreadable(file: root.lastPathComponent,
                                       detail: "no agent folders inside"))
        }
        for folder in folders {
            let loaded = load(folder: folder)
            if let pack = loaded.pack { packs.append(pack) }
            defects += loaded.defects
        }
        return SZAgentPackLoadResult(packs: packs, defects: defects, seats: seats(of: packs))
    }

    /// The seats as the loaded set fills them: an id only where EXACTLY one pack claims the
    /// seat. Unfilled and contested both resolve nil; `validate` names the difference.
    static func seats(of packs: [SZAgentPack]) -> SZSeatAssignment {
        var seats = SZSeatAssignment()
        for seat in SZAgentSeat.allCases {
            let holders = packs.filter { $0.seat == seat }
            if holders.count == 1 { seats[seat] = holders[0].id }
        }
        return seats
    }

    /// `agent.json`: id (must equal the folder name — identity lives in the filesystem)
    /// and an optional seat. Nothing else: the graph is `graph.json`, whole.
    private struct Manifest: Decodable {
        var id: String
        var seat: SZAgentSeat?
    }

    /// One folder's load: the pack (nil only when `agent.json` itself is broken) plus
    /// EVERY defect the folder shows.
    private static func load(folder: URL) -> (pack: SZAgentPack?, defects: [SZAgentPackDefect]) {
        let fm = FileManager.default
        let folderName = folder.lastPathComponent

        let manifest: Manifest
        switch decode(Manifest.self, folder.appending(path: "agent.json"), in: folderName) {
        case .success(let decoded): manifest = decoded
        case .failure(let defect): return (nil, [defect])
        }
        guard manifest.id == folderName else {
            return (nil, [.misdeclared(file: "\(folderName)/agent.json",
                detail: "declares id '\(manifest.id)' — the id IS the folder name")])
        }

        var defects: [SZAgentPackDefect] = []
        var graph: SZAgentGraph?
        let graphURL = folder.appending(path: "graph.json")
        if fm.fileExists(atPath: graphURL.path) {
            switch decode(SZAgentGraph.self, graphURL, in: folderName) {
            case .success(let decoded): graph = decoded
            case .failure(let defect): defects.append(defect)
            }
        } else {
            defects.append(.noGraph(agent: folderName))
        }

        let prompts = ((try? fm.contentsOfDirectory(
            at: folder.appending(path: "prompts"), includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent)
            .filter { $0.hasSuffix(".md.mustache") }
            .map { "prompts/\($0)" }
            .sorted()
        // The templates' text rides along for validation's token scan. A file that lists
        // but will not read scans as empty; the read failure surfaces loudly at render.
        let promptSources = Dictionary(uniqueKeysWithValues: prompts.map { path in
            (path, (try? String(contentsOf: folder.appending(path: path), encoding: .utf8)) ?? "")
        })

        let steps = ((try? fm.contentsOfDirectory(
            at: folder.appending(path: "steps"), includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { stepFolder in
                SZAgentPack.StepFolder(
                    name: stepFolder.lastPathComponent,
                    hasSource: fm.fileExists(atPath: stepFolder.appending(path: "Step.swift").path))
            }

        return (SZAgentPack(id: manifest.id, seat: manifest.seat, graph: graph,
                            prompts: prompts, promptSources: promptSources, steps: steps),
                defects)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ url: URL,
                                             in folder: String) -> Result<T, SZAgentPackDefect> {
        do {
            return .success(try JSONDecoder().decode(T.self, from: Data(contentsOf: url)))
        } catch {
            return .failure(.unreadable(file: "\(folder)/\(url.lastPathComponent)",
                                        detail: String(describing: error)))
        }
    }

    // MARK: - Validation

    /// Every defect the loaded set carries, collected. `steps` nil skips the step-attached
    /// checks (declared outcomes); the caller's report must say so, which `check` does.
    public static func validate(packs: [SZAgentPack],
                                steps: (any SZStepProviding)?) async -> [SZAgentPackDefect] {
        var defects: [SZAgentPackDefect] = []

        // Seats — a rule about the COMPLETE library: exactly one holder each.
        for seat in SZAgentSeat.allCases {
            let holders = packs.filter { $0.seat == seat }.map(\.id).sorted()
            if holders.isEmpty {
                defects.append(.seatUnfilled(seat: seat))
            } else if holders.count > 1 {
                defects.append(.seatContested(seat: seat, holders: holders))
            }
        }
        let filledSeats = Set(packs.compactMap(\.seat))

        for pack in packs.sorted(by: { $0.id < $1.id }) {
            guard let graph = pack.graph else { continue }   // noGraph already reported
            defects += graph.defects().map { .graphShape(agent: pack.id, defect: $0) }
            defects += await nodeDefects(pack: pack, graph: graph,
                                         filledSeats: filledSeats, steps: steps)
        }
        return defects
    }

    /// Per-node checks: briefs resolve against the one token table, step folders carry
    /// source, dispatches name held seats — and, with a provider, the compiled steps'
    /// declarations agree with the wiring (the door included: it is a step).
    private static func nodeDefects(pack: SZAgentPack, graph: SZAgentGraph,
                                    filledSeats: Set<SZAgentSeat>,
                                    steps: (any SZStepProviding)?) async -> [SZAgentPackDefect] {
        var defects: [SZAgentPackDefect] = []
        for node in graph.nodes {
            switch node.form {
            case .turn(let turn):
                defects += briefDefects(pack: pack, node: node.id, brief: turn.brief)

            case .dispatch(let dispatch):
                if SZAgentSeat(rawValue: dispatch.to).map(filledSeats.contains) != true {
                    defects.append(.unknownDispatchSeat(agent: pack.id, node: node.id,
                                                        seat: dispatch.to))
                }

            case .step(let name):
                guard let folder = pack.step(named: name), folder.hasSource else {
                    defects.append(.missingStepSource(agent: pack.id, node: node.id, step: name))
                    continue
                }
                guard let steps else { continue }   // skipped, and the report says so
                let outgoing = graph.edges.filter { $0.from == node.id }
                do {
                    let declaration = try await steps.declaration(agent: pack.id, step: name)
                    if let declaration, !declaration.outcomes.isEmpty {
                        for edge in outgoing where !declaration.outcomes.contains(edge.outcome) {
                            defects.append(.undeclaredStepOutcome(
                                agent: pack.id, node: node.id,
                                outcome: edge.outcome, declared: declaration.outcomes))
                        }
                    } else if !outgoing.isEmpty {
                        defects.append(.stepDeclaresNothing(agent: pack.id, node: node.id,
                                                            step: name))
                    }
                } catch {
                    defects.append(.stepUnavailable(agent: pack.id, step: name,
                                                    detail: String(describing: error)))
                }
            }
        }
        return defects
    }

    /// One brief's checks: the file exists, every `{{token}}` is in the one token table,
    /// and every partial a mentioned token renders from ships in the pack.
    private static func briefDefects(pack: SZAgentPack, node: String,
                                     brief: String) -> [SZAgentPackDefect] {
        let path = SZBriefRenderer.templatePath(brief)
        guard pack.prompts.contains(path) else {
            return [.missingTemplate(agent: pack.id, node: node, path: path)]
        }
        guard let text = pack.promptSources[path] else { return [] }
        var defects: [SZAgentPackDefect] = []
        for token in SZPromptTemplate.tokens(in: text) {
            guard SZBriefRenderer.knownTokens.contains(token) else {
                defects.append(.unknownTemplateToken(
                    agent: pack.id, node: node, template: path, token: token))
                continue
            }
            for partial in SZBriefRenderer.requiredPartials[token] ?? []
            where !pack.prompts.contains(partial) {
                defects.append(.missingPartial(
                    agent: pack.id, node: node, token: token, partial: partial))
            }
        }
        return defects
    }

    // MARK: - The report

    /// The pre-flight report: load + validate `root` exactly as the host would and render
    /// the result — per-agent summary, sorted defects, and a verdict naming the highest
    /// tier honestly attained: `does not load` / `loads, does not validate` / `validates`.
    /// With no step provider the verdict carries `step checks skipped`.
    public static func check(root: URL, steps: (any SZStepProviding)?) async -> String {
        let loaded = load(root: root)
        let defects = loaded.defects + (await validate(packs: loaded.packs, steps: steps))

        var lines = ["pack: \(root.path)"]
        for pack in loaded.packs.sorted(by: { $0.id < $1.id }) {
            let compiled = pack.steps.filter(\.hasSource).count
            lines.append("agent \(pack.id)"
                + (pack.seat.map { " · seat: \($0.rawValue)" } ?? " · no seat")
                + " · \(pack.steps.count) step\(pack.steps.count == 1 ? "" : "s")"
                + (compiled != pack.steps.count ? " (\(compiled) with source)" : "")
                + " · \(pack.prompts.count) prompt\(pack.prompts.count == 1 ? "" : "s")")
            if let graph = pack.graph {
                var facts = ["\(graph.nodes.count) node\(graph.nodes.count == 1 ? "" : "s")"]
                // The door's declared outcomes ARE the agent's front page — what it can
                // decide about a message — shown when a provider can compile the door.
                if let steps, case .step(let doorStep) = graph.door?.form,
                   let declaration = (try? await steps.declaration(agent: pack.id, step: doorStep)) ?? nil,
                   !declaration.outcomes.isEmpty {
                    facts.insert("door: \(declaration.outcomes.joined(separator: " · "))", at: 0)
                }
                lines.append("  graph · " + facts.joined(separator: " · "))
            }
        }

        let skipped = steps == nil ? " · step checks skipped" : ""
        if !defects.isEmpty {
            lines.append("defects (\(defects.count)):")
            lines += defects.map(\.description).sorted().map { "  · \($0)" }
        }
        if loaded.packs.isEmpty {
            lines.append("verdict: does not load" + skipped)
        } else if defects.isEmpty {
            let count = loaded.packs.count
            lines.append("verdict: validates — \(count) agent\(count == 1 ? "" : "s"), zero defects" + skipped)
        } else {
            lines.append("verdict: loads, does not validate" + skipped)
        }
        return lines.joined(separator: "\n")
    }
}
