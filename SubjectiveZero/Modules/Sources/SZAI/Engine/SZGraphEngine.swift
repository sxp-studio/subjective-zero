// SPDX-License-Identifier: AGPL-3.0-only
// The traversal engine: one delivered message, through one graph, to one conclusion. It
// holds no host types — everything arrives through the SZTraversalHost/SZStepRunning/
// SZModelRouting seams — so tests drive the real engine with stubs, never a replica.
//
// Four primitives, by design:
// - message:  the door. Costs nothing and asks nothing — the delivered kind IS the outcome,
//             so the traversal leaves by the port bearing its own name.
// - step:     compiled async code; the ONLY home of routing intelligence (it may askModel).
// - turn:     a full agent turn; mechanically dumb — `ok`/`error`, nothing else. A turn's
//             content never routes; the VERDICT-prose-scanning era is unrepresentable.
// - dispatch: resolve the items fact, hand the host the orders, and WAIT — the host
//             supervises the set (SZThreadMachine) and returns its one settled summary;
//             the node then produces `settled` and routes its edge like any other. A
//             retry round is the settled edge looping back under a `maxTraversals`
//             leash — the same bound every other loop speaks, no second mechanism.
//
// One message is one traversal: the engine walks from the door to the conclusion, fleets
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
    /// The seat those orders address, straight off the dispatch node.
    public var sentTarget: String?
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

    /// Traverse from the message node to a conclusion. Cancellation is checked at every node
    /// boundary and concludes as `.cancelled` — never a defect, never caught-and-continued.
    public func run(kind: SZMessageKind) async -> SZTraversalResult {
        var notes: [SZTraversalNote] = []
        var sent: [SZItemOrder] = []
        var sentTarget: String?
        var ordinal = 0
        struct EdgeKey: Hashable { let from: String; let outcome: String }
        var boundsSpent: [EdgeKey: Int] = [:]

        func note(_ value: SZTraversalNote) {
            notes.append(value)
            host.note(value)
        }

        guard let door = graph.messageNode else {
            // Validation refuses a doorless graph at load, so reaching here means an
            // unvalidated graph was handed to the engine. It refuses to guess an entry.
            return SZTraversalResult(
                conclusion: .defect(node: "", detail: "the graph has no message node"),
                sent: [], sentTarget: nil, notes: [])
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
            switch node.form {
            case .message:
                // The door: no work, no cost, no host seam. An unrouted kind is a routing
                // bug — the gate cannot know which kinds a host will deliver — so it is a
                // defect naming the kind rather than a silent end.
                guard graph.edge(from: id, outcome: kind.rawValue) != nil else {
                    let detail = "nothing routes a '\(kind.rawValue)' message"
                    note(SZTraversalNote(ordinal: ordinal, node: id, phase: .failed, detail: detail))
                    conclusion = .defect(node: id, detail: detail)
                    continue
                }
                outcome = kind.rawValue

            case .ask(let ask):
                // The declarative twin of a step's askModel: render the prompt like a
                // brief, run one stateless completion through the SAME serving path, and
                // route the decoded outcome. The repair loop is the engine's here — the
                // reply is re-asked with the decode error attached, once.
                let facts = host.factsJSON(kind: kind)
                var answered: String?
                var lastDetail = "no reply"
                var cancelled = false
                for attempt in 0...1 {
                    let request = Self.askRequestJSON(template: ask.prompt, attempt: attempt,
                                                     error: attempt == 0 ? nil : lastDetail,
                                                     previousReply: attempt == 0 ? nil : answered)
                    let reply: String
                    do {
                        reply = try await host.serveAsk(agent: agent, step: id, kind: kind,
                                                        factsJSON: facts, requestJSON: request)
                    } catch is CancellationError {
                        cancelled = true
                        break
                    } catch {
                        lastDetail = String(describing: error)
                        break   // a completion failure is not a shape mismatch — no repair
                    }
                    if let outcome = Self.extractOutcome(from: reply) {
                        if ask.outcomes.contains(outcome) { answered = outcome; break }
                        lastDetail = "'\(outcome)' is not among \(ask.outcomes)"
                        answered = reply
                    } else {
                        lastDetail = #"the reply carries no {"outcome": …} object"#
                        answered = reply
                    }
                    answered = nil
                }
                if cancelled {
                    note(SZTraversalNote(ordinal: ordinal, node: id, phase: .done))
                    conclusion = .cancelled(node: id)
                    continue
                }
                guard let ruled = answered else {
                    let detail = "ask '\(id)' got no usable ruling: \(lastDetail)"
                    note(SZTraversalNote(ordinal: ordinal, node: id, phase: .failed, detail: detail))
                    conclusion = .defect(node: id, detail: detail)
                    continue
                }
                // Effects are config here — validated against the kind's catalog exactly
                // like a step's, performed before the edge routes.
                let asked = ask.effects[ruled] ?? []
                if !asked.isEmpty {
                    let declared = SZEffectCatalog.cases(kind: kind.rawValue)
                    if let unknown = asked.first(where: { !declared.contains($0) }) {
                        let detail = "ask '\(id)' declares effect '\(unknown)', outside "
                            + "the '\(kind.rawValue)' effect set"
                        note(SZTraversalNote(ordinal: ordinal, node: id, phase: .failed, detail: detail))
                        conclusion = .defect(node: id, detail: detail)
                        continue
                    }
                    for effect in asked {
                        await host.perform(effect: effect, kind: kind)
                    }
                }
                outcome = ruled

            case .step(let name):
                // The facts snapshot is pinned HERE: the evaluation and every ask it makes
                // see the same document, however long the step runs.
                let facts = host.factsJSON(kind: kind)
                let report = await steps.evaluate(
                    agent: agent, step: name, factsJSON: facts,
                    ask: { [host, agent] request in
                        try await host.serveAsk(agent: agent, step: name, kind: kind,
                                                factsJSON: facts, requestJSON: request)
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
                // EFFECTS: host actions the step requested with its outcome. Validated
                // against the graph kind's catalogued effect set — an unknown name is a
                // traversal defect naming it, and nothing performs. Performed in the step's
                // own order, AFTER the step returned and BEFORE edge routing.
                if !report.effects.isEmpty {
                    let declared = SZEffectCatalog.cases(kind: kind.rawValue)
                    if let unknown = report.effects.first(where: { !declared.contains($0) }) {
                        let detail = "step '\(name)' requested effect '\(unknown)', outside "
                            + "the '\(kind.rawValue)' effect set"
                        note(SZTraversalNote(ordinal: ordinal, node: id, phase: .failed, detail: detail))
                        conclusion = .defect(node: id, detail: detail)
                        continue
                    }
                    for effect in report.effects {
                        await host.perform(effect: effect, kind: kind)
                    }
                }
                outcome = answered

            case .turn(let turn):
                let rendered: String
                do {
                    rendered = try host.renderBrief(agent: agent, template: turn.brief, kind: kind)
                } catch {
                    let detail = "brief '\(turn.brief)' would not render: \(error)"
                    note(SZTraversalNote(ordinal: ordinal, node: id, phase: .failed, detail: detail))
                    conclusion = .defect(node: id, detail: detail)
                    continue
                }
                let choice = router.resolve(SZModelCall(
                    class: .turn, agent: agent, graph: graph.name, step: id))
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

            case .dispatch(let dispatch):
                let items = host.itemsFact(named: dispatch.items, kind: kind)
                let orders = items.map { SZItemOrder(node: $0) }
                sent += orders
                sentTarget = dispatch.to
                // The visit is RUNNING for the whole fleet phase — the card pulses and
                // its tally counts up through the progress notes, which is how the panel
                // says "these agents are working right now".
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
                                 tally: noteTally))

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
                    // The leash ran out: the traversal ends where it stands, on its own
                    // ending class — bounded edges limit repetition, nothing more.
                    conclusion = ending()
                    continue
                }
                boundsSpent[key] = spent + 1
            }
            current = edge.to
        }

        return SZTraversalResult(
            conclusion: conclusion ?? .defect(node: current ?? "", detail: "the traversal never concluded"),
            sent: sent,
            sentTarget: sentTarget,
            notes: notes)
    }

    // MARK: - The ask form's wire pieces

    /// The ask request in the SAME wire shape a compiled step's `askModel` sends, so the
    /// query service serves both identically (render → route → complete → journal → repair).
    nonisolated static func askRequestJSON(template: String, attempt: Int,
                                           error: String?, previousReply: String?) -> String {
        var request: [String: Any] = ["template": template, "attempt": attempt]
        if let error {
            request["repair"] = ["error": error, "previousReply": previousReply ?? ""]
        }
        let data = (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// `{"outcome": …}` out of a CLI-shaped reply: the bytes as-is, else every balanced
    /// object inside them (fences, preambles, restated formats), string-literal aware —
    /// the SDK's tolerant-decode rule, restated on this side of the ABI for the one shape
    /// an ask node reads.
    nonisolated static func extractOutcome(from reply: String) -> String? {
        struct Ruling: Decodable { let outcome: String }
        let decoder = JSONDecoder()
        if let whole = try? decoder.decode(Ruling.self, from: Data(reply.utf8)) {
            return whole.outcome
        }
        var searchStart = reply.startIndex
        while let start = reply[searchStart...].firstIndex(of: "{") {
            if let end = balancedEnd(in: reply, from: start),
               let ruling = try? decoder.decode(Ruling.self, from: Data(reply[start...end].utf8)) {
                return ruling.outcome
            }
            searchStart = reply.index(after: start)
        }
        return nil
    }

    /// The index of the closer balancing the opener at `start`, skipping string literals
    /// (with escape handling). nil if the reply never balances.
    private nonisolated static func balancedEnd(in reply: String,
                                                from start: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < reply.endIndex {
            let ch = reply[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = reply.index(after: index)
        }
        return nil
    }
}

extension SZTraversalEnding {
    /// The engine's conclusion in the machine's vocabulary — class-preserving: a refusal
    /// stays a refusal, a defect stays a defect, and only the node attribution is dropped
    /// (the machine supervises threads; the record keeps the node).
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
