// SPDX-License-Identifier: AGPL-3.0-only
// The traversal engine: one delivered message, through one graph, to one conclusion. It
// holds no host types — everything arrives through the SZTraversalHost/SZStepRunning/
// SZModelRouting seams — so tests drive the real engine with stubs, never a replica.
//
// Three primitives, by design:
// - step:     compiled async code; the ONLY home of routing intelligence (it may askModel).
// - turn:     a full agent turn; mechanically dumb — `ok`/`error`, nothing else. A turn's
//             content never routes; the VERDICT-prose-scanning era is unrepresentable.
// - dispatch: resolve the items fact, hand the host `.item` orders, conclude. The settled
//             reply re-enters the graph through the thread machine, not this traversal.
//
// Threads — sequences of traversals joined by messages — are SZThreadMachine's business.
import Foundation
import SZCore

/// How a traversal ended. `declined` is a step outcome named `declined` with no edge —
/// refusal is not failure. `defect` is the engine refusing to guess (unknown node, an
/// outcome outside the declared set, a step that would not start).
public enum SZTraversalConclusion: Sendable, Equatable {
    case ended(step: String, outcome: String)
    case failed(step: String, detail: String)
    case cancelled(step: String)
    case declined(step: String, reason: String?)
    case defect(step: String, detail: String)
}

/// A step node's attached declaration, resolved at pack load (outcomes from the compiled
/// step's own export; facts kind checked there too). The engine trusts it — the gate ran.
public struct SZStepAttachment: Sendable {
    public var outcomes: Set<String>
    public init(outcomes: Set<String>) { self.outcomes = outcomes }
}

public struct SZTraversalResult: Sendable {
    public var conclusion: SZTraversalConclusion
    /// Item orders a dispatch sent (empty otherwise) — the machine opens a set from these.
    public var sent: [SZItemOrder]
    public var notes: [SZTraversalNote]
}

@MainActor
public struct SZGraphEngine {
    let agent: String
    let graph: SZAgentGraph
    /// Declared outcomes per step node id, attached by the pack loader.
    let attachments: [String: SZStepAttachment]
    let host: any SZTraversalHost
    let steps: any SZStepRunning
    let router: any SZModelRouting

    public init(agent: String, graph: SZAgentGraph, attachments: [String: SZStepAttachment],
                host: any SZTraversalHost, steps: any SZStepRunning, router: any SZModelRouting) {
        self.agent = agent
        self.graph = graph
        self.attachments = attachments
        self.host = host
        self.steps = steps
        self.router = router
    }

    /// Traverse from `kind`'s entry to a conclusion. Cancellation is checked at every node
    /// boundary and concludes as `.cancelled` — never a defect, never caught-and-continued.
    public func run(kind: SZMessageKind) async -> SZTraversalResult {
        var notes: [SZTraversalNote] = []
        var sent: [SZItemOrder] = []
        var ordinal = 0
        var boundsSpent: [String: Int] = [:]   // "from|outcome" → traversals taken

        func note(_ value: SZTraversalNote) {
            notes.append(value)
            host.note(value)
        }

        guard let entry = graph.entry[kind] else {
            // An undeclared entry ends the traversal before it begins — the pack gate
            // refuses graphs missing their OWN kind's entry, so this is a foreign kind.
            return SZTraversalResult(
                conclusion: .ended(step: "", outcome: "unhandled"), sent: [], notes: [])
        }

        var current: String? = entry
        var conclusion: SZTraversalConclusion?

        while let id = current, conclusion == nil {
            guard !Task.isCancelled else {
                conclusion = .cancelled(step: id)
                break
            }
            guard let node = graph.node(id) else {
                conclusion = .defect(step: id, detail: "the graph names no node '\(id)'")
                break
            }
            ordinal += 1
            note(SZTraversalNote(ordinal: ordinal, node: id, phase: .running))

            let outcome: String
            switch node.form {
            case .step(let name):
                let report = await steps.evaluate(
                    agent: agent, step: name, factsJSON: host.factsJSON(kind: graph.kind),
                    ask: { [host, agent] request in
                        try await host.serveAsk(agent: agent, step: name, requestJSON: request)
                    })
                if report.cancelled {
                    note(SZTraversalNote(ordinal: ordinal, node: id, phase: .done, outcome: nil))
                    conclusion = .cancelled(step: id)
                    continue
                }
                if let failure = report.failure {
                    note(SZTraversalNote(ordinal: ordinal, node: id, phase: .failed, detail: failure))
                    conclusion = .defect(step: id, detail: failure)
                    continue
                }
                guard let answered = report.outcome,
                      attachments[id]?.outcomes.contains(answered) == true else {
                    let detail = "step '\(name)' answered '\(report.outcome ?? "nothing")', outside its declared outcomes"
                    note(SZTraversalNote(ordinal: ordinal, node: id, phase: .failed, detail: detail))
                    conclusion = .defect(step: id, detail: detail)
                    continue
                }
                outcome = answered

            case .turn(let turn):
                let rendered: String
                do {
                    rendered = try host.renderBrief(agent: agent, template: turn.brief, kind: graph.kind)
                } catch {
                    let detail = "brief '\(turn.brief)' would not render: \(error)"
                    note(SZTraversalNote(ordinal: ordinal, node: id, phase: .failed, detail: detail))
                    conclusion = .defect(step: id, detail: detail)
                    continue
                }
                let choice = router.resolve(SZModelCall(
                    class: .turn, agent: agent, graph: graph.name, step: id))
                let report = await host.runTurn(SZTurnOrder(
                    agent: agent, brief: rendered, session: turn.session,
                    tools: turn.tools, choice: choice))
                if Task.isCancelled {
                    note(SZTraversalNote(ordinal: ordinal, node: id, phase: .done))
                    conclusion = .cancelled(step: id)
                    continue
                }
                // Process truth only. A failed turn is `error` — a wired error edge may
                // route recovery; an unwired one ends the traversal as failed below.
                outcome = report.failed ? "error" : "ok"
                if report.failed, graph.edge(from: id, outcome: "error") == nil {
                    note(SZTraversalNote(ordinal: ordinal, node: id, phase: .failed, detail: report.detail))
                    conclusion = .failed(step: id, detail: report.detail ?? "the turn failed")
                    continue
                }

            case .dispatch(let dispatch):
                let items = host.itemsFact(named: dispatch.items, kind: graph.kind)
                sent = items.map { SZItemOrder(node: $0) }
                outcome = "sent"
                note(SZTraversalNote(ordinal: ordinal, node: id, phase: .done, outcome: outcome,
                                     detail: "\(sent.count) item(s) to \(dispatch.to)"))
                // Send-and-conclude: the shape gate refused any out-edge, so the loop ends
                // here and the settled reply re-enters via the machine.
                conclusion = .ended(step: id, outcome: outcome)
                continue
            }

            note(SZTraversalNote(ordinal: ordinal, node: id, phase: .done, outcome: outcome))

            guard let edge = graph.edge(from: id, outcome: outcome) else {
                conclusion = outcome == "declined"
                    ? .declined(step: id, reason: nil)
                    : .ended(step: id, outcome: outcome)
                continue
            }
            if let bound = edge.maxTraversals {
                let key = "\(edge.from)|\(edge.outcome)"
                let spent = boundsSpent[key, default: 0]
                guard spent < bound else {
                    // The leash ran out: the traversal ends where it stands, on its own
                    // outcome — bounded edges limit repetition, they do not fail it.
                    conclusion = .ended(step: id, outcome: outcome)
                    continue
                }
                boundsSpent[key] = spent + 1
            }
            current = edge.to
        }

        return SZTraversalResult(
            conclusion: conclusion ?? .defect(step: current ?? "", detail: "the traversal never concluded"),
            sent: sent,
            notes: notes)
    }
}
