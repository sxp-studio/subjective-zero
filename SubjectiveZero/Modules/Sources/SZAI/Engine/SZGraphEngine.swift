// SPDX-License-Identifier: AGPL-3.0-only
// The traversal engine: one delivered message, through one graph, to one conclusion. It
// holds no host types — everything arrives through the SZTraversalServing / SZStepRunning /
// SZModelRouting seams — so tests drive the real engine with stubs.
//
// Three node forms:
// - step:     compiled async code; the ONLY home of routing intelligence (it may ask). The
//             door is the step at the reserved `door` id, where every traversal begins.
// - turn:     a full agent turn; mechanically dumb — ok/error, nothing else.
// - dispatch: fan the run's work set out and WAIT — the delivery supervises the set and
//             returns its one settled summary; the node produces `settled` and routes.
//             A retry round is the settled edge looping back under a `maxTraversals` leash.
//
// One message is one traversal: the engine runs from the door to the conclusion, fleets
// and all, and the record's trace is the whole journey.
import Foundation
import SZCore

/// How a traversal ended. `declined` is a step outcome named `declined` with no edge —
/// refusal is not failure. `defect` is the engine refusing to guess (unknown node, an
/// outcome outside the declared set, a step that would not start).
public enum SZTraversalConclusion: Sendable, Equatable {
    case ended(node: String, outcome: String)
    case failed(node: String, detail: String)
    case cancelled(node: String)
    case declined(node: String, reason: String?)
    case defect(node: String, detail: String)
}

/// A step node's attached declaration, resolved at pack load. The engine trusts it — the
/// gate ran.
public struct SZStepAttachment: Sendable {
    public var outcomes: Set<String>
    public init(outcomes: Set<String>) { self.outcomes = outcomes }
}

public struct SZTraversalResult: Sendable {
    public var conclusion: SZTraversalConclusion
    public var notes: [SZTraversalNote]
}

@MainActor
public struct SZGraphEngine {
    let agent: String
    let graph: SZAgentGraph
    /// Declared outcomes per step node id, attached by the pack loader.
    let attachments: [String: SZStepAttachment]
    let host: any SZTraversalServing
    let steps: any SZStepRunning
    let router: any SZModelRouting

    public init(agent: String, graph: SZAgentGraph, attachments: [String: SZStepAttachment],
                host: any SZTraversalServing, steps: any SZStepRunning, router: any SZModelRouting) {
        self.agent = agent
        self.graph = graph
        self.attachments = attachments
        self.host = host
        self.steps = steps
        self.router = router
    }

    /// Deterministic wire bytes for one pinned facts snapshot.
    static func factsJSON(_ facts: SZFacts) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(facts) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Run from the door to a conclusion. Cancellation is checked at every node boundary
    /// and concludes as `.cancelled` — never a defect, never caught-and-continued.
    public func run() async -> SZTraversalResult {
        var notes: [SZTraversalNote] = []
        var ordinal = 0
        struct EdgeKey: Hashable { let from: String; let outcome: String }
        var boundsSpent: [EdgeKey: Int] = [:]

        func note(_ value: SZTraversalNote) {
            notes.append(value)
            host.note(value)
        }

        guard let door = graph.door else {
            // Validation refuses a doorless graph at load; reaching here means an
            // unvalidated graph was handed over. The engine refuses to guess an entry.
            return SZTraversalResult(
                conclusion: .defect(node: "", detail: "the graph has no door"),
                notes: [])
        }
        var current: String? = door.id
        var conclusion: SZTraversalConclusion?

        while let id = current, conclusion == nil {
            guard !Task.isCancelled else {
                conclusion = .cancelled(node: id)
                break
            }
            guard let node = graph.node(id) else {
                conclusion = .defect(node: id, detail: "the graph names no node '\(id)'")
                break
            }
            ordinal += 1
            note(SZTraversalNote(ordinal: ordinal, node: id, phase: .running))

            let outcome: String
            var turnFailure: String?
            var noteDetail: String?
            var noteTally: SZAgentGraphRun.Tally?
            var noteGeneration: String?
            switch node.form {
            case .step(let name):
                // The snapshot is pinned HERE: the evaluation and every ask it makes see
                // the same document, however long the step runs.
                let report = await steps.evaluate(
                    agent: agent, step: name, factsJSON: Self.factsJSON(host.facts()),
                    ask: { [host] request in
                        try await host.serveAsk(step: name, requestJSON: request)
                    })
                if report.cancelled {
                    note(SZTraversalNote(ordinal: ordinal, node: id, phase: .done, outcome: nil))
                    conclusion = .cancelled(node: id)
                    continue
                }
                if let failure = report.failure {
                    note(SZTraversalNote(ordinal: ordinal, node: id, phase: .failed, detail: failure))
                    conclusion = .defect(node: id, detail: failure)
                    continue
                }
                guard let answered = report.outcome,
                      attachments[id]?.outcomes.contains(answered) == true else {
                    let detail = "step '\(name)' answered '\(report.outcome ?? "nothing")', outside its declared outcomes"
                    note(SZTraversalNote(ordinal: ordinal, node: id, phase: .failed, detail: detail))
                    conclusion = .defect(node: id, detail: detail)
                    continue
                }
                // Effects: typed host actions the step requested with its outcome — an
                // unknown name is a defect and nothing performs. Performed in the step's
                // order, AFTER the step returned and BEFORE edge routing.
                if !report.effects.isEmpty {
                    var validated: [SZEffect] = []
                    for effectName in report.effects {
                        guard let effect = SZEffect(rawValue: effectName) else {
                            let detail = "step '\(name)' requested unknown effect '\(effectName)'"
                            note(SZTraversalNote(ordinal: ordinal, node: id, phase: .failed, detail: detail))
                            conclusion = .defect(node: id, detail: detail)
                            break
                        }
                        validated.append(effect)
                    }
                    guard conclusion == nil else { continue }
                    for effect in validated {
                        await host.perform(effect: effect)
                    }
                }
                outcome = answered

            case .turn(let turn):
                let rendered: String
                do {
                    rendered = try host.render(template: turn.brief)
                } catch {
                    let detail = "brief '\(turn.brief)' would not render: \(error)"
                    note(SZTraversalNote(ordinal: ordinal, node: id, phase: .failed, detail: detail))
                    conclusion = .defect(node: id, detail: detail)
                    continue
                }
                let choice = router.resolve(SZModelCall(
                    class: .turn, agent: agent, duty: turn.duty))
                let report = await host.runTurn(SZTurnOrder(
                    agent: agent, brief: rendered, session: turn.session,
                    tools: turn.tools, choice: choice))
                if Task.isCancelled {
                    note(SZTraversalNote(ordinal: ordinal, node: id, phase: .done))
                    conclusion = .cancelled(node: id)
                    continue
                }
                // Process truth only. A failed turn is `error` — a wired error edge may
                // route recovery; an unwired one ends the traversal as failed below.
                outcome = report.failed ? "error" : "ok"
                if report.failed { turnFailure = report.detail ?? "the turn failed" }
                noteGeneration = report.generation

            case .dispatch(let dispatch):
                // A dispatch sends the run's work set — the only dispatchable list.
                let items = host.facts().run?.workSet ?? []
                let orders = items.map { SZWorkOrder(node: $0.uuidString) }
                // The visit is RUNNING for the whole fleet phase — the card pulses and
                // its tally counts up through the progress notes.
                let visitOrdinal = ordinal
                let summary = await host.deliver(orders: orders, to: dispatch.to) { [host] tally in
                    host.note(SZTraversalNote(ordinal: visitOrdinal, node: id, phase: .running,
                                              tally: tally))
                }
                if Task.isCancelled {
                    note(SZTraversalNote(ordinal: ordinal, node: id, phase: .done))
                    conclusion = .cancelled(node: id)
                    continue
                }
                guard let summary else {
                    let detail = "this delivery cannot dispatch (no fleet host)"
                    note(SZTraversalNote(ordinal: ordinal, node: id, phase: .failed, detail: detail))
                    conclusion = .defect(node: id, detail: detail)
                    continue
                }
                outcome = "settled"
                noteDetail = "\(summary.outcomes.count)/\(orders.count) settled"
                    + (summary.failedCount > 0 ? " · \(summary.failedCount) failed" : "")
                noteTally = SZAgentGraphRun.Tally(settled: summary.outcomes.count,
                                                  total: orders.count,
                                                  failed: summary.failedCount)
            }

            note(SZTraversalNote(ordinal: ordinal, node: id,
                                 phase: turnFailure == nil ? .done : .failed,
                                 outcome: outcome, detail: turnFailure ?? noteDetail,
                                 tally: noteTally, generation: noteGeneration))

            // How this traversal ends when nothing routes onward from `outcome` — shared
            // by the edge-less exit and the spent leash, so neither can launder a failed
            // turn into success nor a refusal into completion.
            func ending() -> SZTraversalConclusion {
                if let turnFailure { return .failed(node: id, detail: turnFailure) }
                if outcome == "declined" { return .declined(node: id, reason: nil) }
                return .ended(node: id, outcome: outcome)
            }

            guard let edge = graph.edge(from: id, outcome: outcome) else {
                conclusion = ending()
                continue
            }
            if let bound = edge.maxTraversals {
                let key = EdgeKey(from: edge.from, outcome: edge.outcome)
                let spent = boundsSpent[key, default: 0]
                guard spent < bound else {
                    // The leash ran out: the traversal ends where it stands — bounded
                    // edges limit repetition, nothing more.
                    conclusion = ending()
                    continue
                }
                boundsSpent[key] = spent + 1
            }
            current = edge.to
        }

        return SZTraversalResult(
            conclusion: conclusion ?? .defect(node: current ?? "", detail: "the traversal never concluded"),
            notes: notes)
    }
}

extension SZTraversalEnding {
    /// The engine's conclusion in the record's vocabulary — class-preserving; only the
    /// node attribution is dropped (the record keeps the node in its trace).
    public init(_ conclusion: SZTraversalConclusion) {
        switch conclusion {
        case .ended: self = .ended
        case .failed(_, let detail): self = .failed(reason: detail)
        case .cancelled: self = .cancelled
        case .declined(_, let reason): self = .declined(reason: reason ?? "no reason given")
        case .defect(_, let detail): self = .defect(detail: detail)
        }
    }
}
