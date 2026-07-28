// SPDX-License-Identifier: AGPL-3.0-only
// The per-turn debug breakdown: what happened inside one agent round, as timed phases and instants
// stamped by the host while the turn runs, stored on the turn's message (`SZChatMessage.breakdown`),
// and persisted with the transcript like everything else. The Director's run-complete narration
// carries the run-level rollup (`aggregate`). Collection is gated host-side (SZ_TRACE / DEBUG);
// a transcript written with tracing off simply has no breakdowns.
import Foundation

/// One timed phase or instant inside an agent turn. `stage` is an open dot-namespaced string
/// (constants in `SZTurnStage`), not an enum, so transcripts written by newer builds keep decoding
/// in older ones as stages are added.
public struct SZTurnEvent: Sendable, Equatable, Codable {
    public var stage: String
    public var start: Date
    /// nil = instant (a moment worth marking, not a measured span).
    public var duration: TimeInterval?
    /// Tool name, outcome note, sub-span summary — whatever makes the row read well.
    public var detail: String?
    /// Span identity — set by `SZTrace.span`/`begin` so nested fences can reference it. nil for
    /// instants and derived rows.
    public var id: UUID?
    /// The enclosing span's `id` — the block-timeline hierarchy (a compile fence inside the
    /// bridge's mcp.tool span carries that span's id).
    public var parentID: UUID?
    /// The owning run, for run-owned turns — how a run's turns are found across scopes.
    public var runID: UUID?
    /// APPROXIMATE tokens this action added to the agent's context (chars/4): a tool span's
    /// result payload, the prompt row's rendered prompt. nil = not a context-adding action.
    /// This is what decomposes a turn's "in" count into causes the app can actually see.
    public var addedTokens: Int?

    public init(stage: String, start: Date = Date(), duration: TimeInterval? = nil,
                detail: String? = nil, id: UUID? = nil, parentID: UUID? = nil,
                runID: UUID? = nil, addedTokens: Int? = nil) {
        self.stage = stage
        self.start = start
        self.duration = duration
        self.detail = detail
        self.id = id
        self.parentID = parentID
        self.runID = runID
        self.addedTokens = addedTokens
    }
}

extension SZTurnEvent {
    private enum CodingKeys: String, CodingKey {
        case stage, start, duration, detail, id, parentID, runID, addedTokens
    }

    // Append-tolerant like SZChatMessage: only `stage` is hard-required; a malformed event decodes
    // as far as it can rather than failing the whole transcript.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stage = try c.decode(String.self, forKey: .stage)
        start = try c.decodeIfPresent(Date.self, forKey: .start) ?? Date()
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        runID = try c.decodeIfPresent(UUID.self, forKey: .runID)
        addedTokens = try c.decodeIfPresent(Int.self, forKey: .addedTokens)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stage, forKey: .stage)
        try c.encode(start, forKey: .start)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(parentID, forKey: .parentID)
        try c.encodeIfPresent(runID, forKey: .runID)
        try c.encodeIfPresent(addedTokens, forKey: .addedTokens)
    }
}

/// The stage taxonomy — constants, not an enum (see `SZTurnEvent.stage`). Nested stages (mcp/compile/
/// promote happen INSIDE the turn's wall time) are breakdowns of it, never additive with it.
public enum SZTurnStage {
    public static let queueWait      = "queue.wait"        // enqueue → delivery started (chat turns)
    public static let promptSize     = "prompt.size"       // instant; detail = rendered prompt size
    public static let firstOutput    = "spawn.firstOutput" // provider launch → first stdout chunk
    public static let toolCall       = "tool.call"         // streamed tool-use instant; detail = name
    public static let mcpTool        = "mcp.tool"          // host-measured tool span; detail = name
    public static let compileCheck   = "compile.check"     // staged-source compile check
    public static let promote        = "promote"           // staged → live promote, whole body
    public static let promoteReload  = "promote.reload"    // promote's rebuild + project reload share
    public static let modelTime      = "turn.model"        // derived: the turn minus its measured phases
    public static let providerReport = "provider.report"   // the CLI's own account of the turn
    // Run-rollup stages (the Director's run-complete narration):
    public static let runNode        = "run.node"          // one work-set node's summed agent time
    public static let runDirector    = "run.director"      // the Director's own turns, summed
    public static let runTotal       = "run.total"         // wall clock + token/cost totals

    /// Short human label for a stage — shared by the chat panel and anything else that renders
    /// events. Unknown stages fall back to the raw name (forward tolerance).
    public static func displayName(_ stage: String) -> String {
        switch stage {
        case queueWait: return "queued"
        case promptSize: return "prompt"
        case firstOutput: return "first output"
        case toolCall, mcpTool: return "tool"
        case compileCheck: return "compile"
        case promote: return "promote"
        case promoteReload: return "reload"
        case modelTime: return "model thinking"
        case providerReport: return "cli-reported"
        case runNode: return "node"
        case runDirector: return "director"
        case runTotal: return "run"
        default: return stage
        }
    }
}

/// Pure helpers over turn breakdowns — turn-end finalization and the run-level rollup fold live
/// here so they're testable without the app target.
public enum SZTurnBreakdown {
    /// Turn-end post-processing over the events `SZTrace.take(turnID:)` returns:
    /// - an MCP tool shows up twice (the CLI's streamed `tool.call` sighting AND the host-measured
    ///   `mcp.tool` span) — keep the span, drop the sightings it supersedes; a CLI's local tools
    ///   have no span and keep theirs;
    /// - sort chronologically;
    /// - append the derived `turn.model` residual — everything not inside a measured phase is the
    ///   model itself (reasoning + streaming between tools; plus any fences attribution dropped).
    ///   queue wait precedes `started`; compile/promote nest inside mcp.tool spans — neither is
    ///   subtracted twice;
    /// - pin `provider.report` rows last as the summary line.
    /// Empty in → empty out.
    public static func finalize(events: [SZTurnEvent], started: Date, ended: Date) -> [SZTurnEvent] {
        guard !events.isEmpty else { return [] }
        var events = events
        // An MCP tool shows up twice — the CLI's streamed sighting AND the host-measured span.
        // Pair each span with its closest same-name sighting (±10s) and drop just THAT one: the
        // old name-set dedupe deleted every sighting of a tool the moment one call got a span,
        // erasing calls whose spans were attribution-dropped.
        let spans = events.filter { $0.stage == SZTurnStage.mcpTool }
        var pairedSightings = Set<Int>()
        for span in spans {
            var best: (index: Int, distance: TimeInterval)?
            for (index, event) in events.enumerated()
            where event.stage == SZTurnStage.toolCall && event.detail == span.detail
                && !pairedSightings.contains(index) {
                let distance = abs(event.start.timeIntervalSince(span.start))
                if distance <= 10, distance < (best?.distance ?? .infinity) {
                    best = (index, distance)
                }
            }
            if let best { pairedSightings.insert(best.index) }
        }
        events = events.enumerated().filter { !pairedSightings.contains($0.offset) }.map(\.element)
        events.sort { $0.start < $1.start }
        let reportRows = events.filter { $0.stage == SZTurnStage.providerReport }
        events.removeAll { $0.stage == SZTurnStage.providerReport }
        // Residual = wall − UNION of the measured spans, never a sum: overlap (a CLI's parallel
        // tool calls, a starved first-output fence) must not drive the residual negative and
        // silently drop the model row while the visible rows overcount the turn.
        let wall = max(0, ended.timeIntervalSince(started))
        let model = wall - coveredLength(of: events, from: started, to: ended)
        if model > 0.05 {
            events.append(SZTurnEvent(stage: SZTurnStage.modelTime, start: started, duration: model,
                                      runID: events.first?.runID))
        }
        events.append(contentsOf: reportRows)
        return events
    }

    /// Union length of the measured top-level spans (first output + tool spans; compile/promote
    /// nest inside their tool span), clipped to the turn's window.
    private static func coveredLength(of events: [SZTurnEvent], from started: Date,
                                      to ended: Date) -> TimeInterval {
        let intervals: [(Date, Date)] = events.compactMap { event in
            switch event.stage {
            case SZTurnStage.firstOutput, SZTurnStage.mcpTool:
                guard let duration = event.duration else { return nil }
                let intervalStart = max(event.start, started)
                let intervalEnd = min(event.start.addingTimeInterval(duration), ended)
                return intervalEnd > intervalStart ? (intervalStart, intervalEnd) : nil
            default: return nil
            }
        }.sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var cursor = started
        for (intervalStart, intervalEnd) in intervals {
            let clipped = max(intervalStart, cursor)
            if intervalEnd > clipped {
                total += intervalEnd.timeIntervalSince(clipped)
                cursor = intervalEnd
            }
        }
        return total
    }

    /// THE row title for every surface (chat disclosure, Profiler rows, text summaries) — three
    /// renderers drifted composing these independently (the summary printed a legacy phrase the
    /// UIs filtered). `depth` (span-nesting glyphs) is derived when not supplied.
    public static func rowTitle(for event: SZTurnEvent, in events: [SZTurnEvent],
                                depth: Int? = nil) -> String {
        let resolvedDepth = depth ?? Self.depth(of: event, in: events)
        let prefix = resolvedDepth > 0
            ? String(repeating: "  ", count: resolvedDepth - 1) + "└ " : ""
        let base: String
        switch event.stage {
        case SZTurnStage.toolCall, SZTurnStage.mcpTool:
            base = "\(prefix)→ \(event.detail ?? "tool")"
        case SZTurnStage.modelTime:
            // Honesty: the residual includes any UNMEASURED local tools (a CLI's own shell/file
            // work streams as sightings with no span) — a 60s local build must not read as the
            // model thinking.
            let label = modelLabel(of: event) ?? "model"
            let hasLocalTools = events.contains { $0.stage == SZTurnStage.toolCall }
            base = "\(prefix)(\(label) thinking\(hasLocalTools ? " + local tools" : ""))"
        case SZTurnStage.runTotal:
            base = prefix + SZTurnStage.displayName(event.stage)
        case SZTurnStage.runNode:
            base = "  " + (event.detail?.components(separatedBy: " · ").first
                ?? SZTurnStage.displayName(event.stage))
        case SZTurnStage.runDirector:
            base = "  " + SZTurnStage.displayName(event.stage)
        default:
            let name = SZTurnStage.displayName(event.stage)
            base = prefix + (event.detail.map { "\(name) · \($0)" } ?? name)
        }
        // What this action ADDED to the agent's context — the per-action decomposition of the
        // turn's "in" count, rendered wherever the row renders.
        if let added = event.addedTokens {
            return "\(base) · +\(formatTokens(added)) tok"
        }
        return base
    }

    /// One finished turn, as the rollup sees it: which scope it ran in, a display label for that
    /// scope (node title or "Director"), and what the turn recorded.
    public struct RunTurn: Sendable, Equatable {
        public var scopeKey: String
        public var label: String
        public var isDirector: Bool
        public var start: Date
        public var duration: TimeInterval?
        public var usage: SZTokenUsage?
        public var events: [SZTurnEvent]
        /// The turn's message id — the key for prompt inspection (`viewTurnPrompt`).
        public var turnID: UUID?

        public init(scopeKey: String, label: String, isDirector: Bool, start: Date,
                    duration: TimeInterval?, usage: SZTokenUsage?, events: [SZTurnEvent],
                    turnID: UUID? = nil) {
            self.scopeKey = scopeKey
            self.label = label
            self.isDirector = isDirector
            self.start = start
            self.duration = duration
            self.usage = usage
            self.events = events
            self.turnID = turnID
        }
    }

    /// Fold a run's turns into the rollup breakdown for the run-complete narration: one `run.node`
    /// row per work-set node (summed agent time; compile/promote shares in the detail), one
    /// `run.director` row (decompose is the first director turn, later ones are reconcile rounds —
    /// the strategy runs them sequentially, so transcript order IS round order), a summed
    /// `queue.wait`, and a `run.total` with wall time and token/cost totals. Rows are ordered by
    /// when each began — the run's actual timeline (decompose first, then the parallel nodes) —
    /// with the total pinned last. Nested spans stay inside their turn's time — nothing here
    /// double-counts.
    public static func aggregate(turns: [RunTurn], runStart: Date, runEnd: Date) -> [SZTurnEvent] {
        guard !turns.isEmpty else { return [] }
        var rows: [SZTurnEvent] = []

        let directorTurns = turns.filter(\.isDirector)
        // Preserve first-seen order so rows match the transcript's story.
        var nodeOrder: [String] = []
        var nodeTurns: [String: [RunTurn]] = [:]
        for turn in turns where !turn.isDirector {
            if nodeTurns[turn.scopeKey] == nil { nodeOrder.append(turn.scopeKey) }
            nodeTurns[turn.scopeKey, default: []].append(turn)
        }

        for key in nodeOrder {
            let group = nodeTurns[key] ?? []
            let agentSeconds = group.compactMap(\.duration).reduce(0, +)
            let compile = stageTotal(SZTurnStage.compileCheck, in: group)
            let promote = stageTotal(SZTurnStage.promote, in: group)
            var bits = ["\(group.count) turn\(group.count == 1 ? "" : "s")"]
            if compile.count > 0 { bits.append("compile \(format(compile.seconds))") }
            if promote.count > 0 { bits.append("promote \(format(promote.seconds))") }
            rows.append(SZTurnEvent(stage: SZTurnStage.runNode,
                                    start: group.map(\.start).min() ?? runStart,
                                    duration: agentSeconds,
                                    detail: "\(group[0].label) · \(bits.joined(separator: " · "))"))
        }

        // One row PER director turn (not a sum): each is a distinct span on the run's timeline —
        // decompose before the fleet, reconcile rounds between dispatches.
        for (i, turn) in directorTurns.enumerated() {
            rows.append(SZTurnEvent(stage: SZTurnStage.runDirector, start: turn.start,
                                    duration: turn.duration,
                                    detail: i == 0 ? "decompose" : "reconcile \(i)"))
        }

        let queueWaits = turns.flatMap(\.events).filter { $0.stage == SZTurnStage.queueWait }
        if !queueWaits.isEmpty {
            rows.append(SZTurnEvent(stage: SZTurnStage.queueWait,
                                    start: queueWaits.map(\.start).min() ?? runStart,
                                    duration: queueWaits.compactMap(\.duration).reduce(0, +),
                                    detail: "\(queueWaits.count) message\(queueWaits.count == 1 ? "" : "s")"))
        }

        rows.sort { $0.start < $1.start }   // the run's timeline, not grouped-by-kind
        rows.append(SZTurnEvent(stage: SZTurnStage.runTotal,
                                start: runStart,
                                duration: runEnd.timeIntervalSince(runStart),
                                detail: totalsDetail(turns: turns)))
        return rows
    }

    /// Sum the token usage across turns — nil when no turn reported any (absence stays absence,
    /// matching `SZTokenUsage`'s no-zeros rule).
    public static func totalUsage(of turns: [RunTurn]) -> SZTokenUsage? {
        let usages = turns.compactMap(\.usage)
        guard !usages.isEmpty else { return nil }
        let cached = usages.compactMap(\.cachedInputTokens)
        let reasoning = usages.compactMap(\.reasoningOutputTokens)
        let costs = usages.compactMap(\.costUSD)
        return SZTokenUsage(
            inputTokens: usages.map(\.inputTokens).reduce(0, +),
            outputTokens: usages.map(\.outputTokens).reduce(0, +),
            cachedInputTokens: cached.isEmpty ? nil : cached.reduce(0, +),
            reasoningOutputTokens: reasoning.isEmpty ? nil : reasoning.reduce(0, +),
            costUSD: costs.isEmpty ? nil : costs.reduce(0, +))
    }

    /// One recorded run, reassembled from transcripts: the Director narration's rollup rows plus
    /// every turn (any scope) whose breakdown carries the run's id — what the Debug panel lists
    /// and `debug_run_summary` renders.
    public struct RunRecord: Sendable, Equatable, Identifiable {
        public var id: UUID              // the runID
        public var startedAt: Date       // run.total's start
        public var wallDuration: TimeInterval
        public var rollup: [SZTurnEvent]
        public var turns: [RunTurn]      // chronological
    }

    /// Reassemble the recorded runs from a project's transcripts, newest first. Pure over the
    /// chat map (`SZStore.chat`) + a scopeKey→title lookup for node labels, so SZUI, the MCP
    /// handler, and tests all share it. A rollup whose rows predate run stamping (an old
    /// transcript) is skipped — no run identity, no grouping.
    public static func runRecords(chat: [String: [SZChatMessage]],
                                  titles: [String: String]) -> [RunRecord] {
        // Every run-stamped turn, grouped by run.
        var turnsByRun: [UUID: [RunTurn]] = [:]
        for (scopeKey, messages) in chat {
            for message in messages {
                guard let events = message.breakdown,
                      let runID = events.compactMap(\.runID).first,
                      !events.contains(where: { $0.stage == SZTurnStage.runTotal })  // not a rollup
                else { continue }
                let isDirector = scopeKey == SZChatScope.directorKey
                turnsByRun[runID, default: []].append(RunTurn(
                    scopeKey: scopeKey,
                    label: isDirector ? "Director" : (titles[scopeKey] ?? String(scopeKey.prefix(8))),
                    isDirector: isDirector,
                    start: message.timestamp,
                    duration: message.duration,
                    usage: message.usage,
                    events: events,
                    turnID: message.id))
            }
        }
        // Each rollup narration (run.total row) becomes one record.
        var records: [RunRecord] = []
        for message in chat[SZChatScope.directorKey] ?? [] {
            guard let rollup = message.breakdown,
                  let total = rollup.last(where: { $0.stage == SZTurnStage.runTotal }),
                  let runID = total.runID else { continue }
            records.append(RunRecord(id: runID, startedAt: total.start,
                                     wallDuration: total.duration ?? 0, rollup: rollup,
                                     turns: (turnsByRun[runID] ?? []).sorted { $0.start < $1.start }))
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    /// A stable identity for cross-view linking (timeline block ↔ detail row): the fence id
    /// where one exists, else content-derived — identical wherever the same event (or the same
    /// derived segment) is rendered.
    public static func eventKey(_ event: SZTurnEvent) -> String {
        if let id = event.id { return id.uuidString }
        return "\(event.stage)|\(event.start.timeIntervalSinceReferenceDate)|\(event.duration ?? -1)"
    }

    /// An event's nesting depth within its turn — the `parentID` chain length (0 = top level).
    /// How the UIs indent: `reload` inside `promote` inside `agent_compile_node` renders two
    /// levels deep, so sibling-looking numbers that would "double count" visibly nest instead.
    public static func depth(of event: SZTurnEvent, in events: [SZTurnEvent]) -> Int {
        var byID: [UUID: SZTurnEvent] = [:]
        for candidate in events {
            if let id = candidate.id { byID[id] = candidate }
        }
        var depth = 0
        var parent = event.parentID
        while depth < 8, let id = parent, let parentEvent = byID[id] {
            depth += 1
            parent = parentEvent.parentID
        }
        return depth
    }

    /// A thinking row's model identity ("gpt-5.6-terra · fast"), nil when unknown. Filters the
    /// legacy explanatory phrase old transcripts carry as detail — it must never render as a
    /// model name.
    public static func modelLabel(of event: SZTurnEvent) -> String? {
        guard event.stage == SZTurnStage.modelTime,
              let detail = event.detail,
              detail != "reasoning + streaming between tools" else { return nil }
        return detail
    }

    /// The model's ACTUAL working segments: the complement of the measured top-level spans
    /// (first output + tool spans; compile/promote nest inside their tool span) within the
    /// turn's extent. Derived on demand — the stored `turn.model` row keeps the total; these
    /// place it in time. One implementation feeds the timeline blocks AND the detail rows.
    public static func modelSegments(of turn: RunTurn,
                                     minimum: TimeInterval = 0.05) -> [SZTurnEvent] {
        guard let duration = turn.duration, duration > 0 else { return [] }
        // Segments inherit the stored model row's detail (the model's identity — "gpt-5.6-terra ·
        // fast"), so every derived segment can say WHO was thinking.
        let modelDetail = turn.events.first { $0.stage == SZTurnStage.modelTime }?.detail
        let turnEnd = turn.start.addingTimeInterval(duration)
        let covered: [(Date, Date)] = turn.events.compactMap { event in
            switch event.stage {
            case SZTurnStage.firstOutput, SZTurnStage.mcpTool:
                guard let span = event.duration else { return nil }
                return (event.start, event.start.addingTimeInterval(span))
            default: return nil
            }
        }.sorted { $0.0 < $1.0 }
        var segments: [SZTurnEvent] = []
        var cursor = turn.start
        for (spanStart, spanEnd) in covered {
            if spanStart.timeIntervalSince(cursor) > minimum {
                segments.append(SZTurnEvent(stage: SZTurnStage.modelTime, start: cursor,
                                            duration: spanStart.timeIntervalSince(cursor),
                                            detail: modelDetail,
                                            runID: turn.events.first?.runID))
            }
            cursor = max(cursor, spanEnd)
        }
        if turnEnd.timeIntervalSince(cursor) > minimum {
            segments.append(SZTurnEvent(stage: SZTurnStage.modelTime, start: cursor,
                                        duration: turnEnd.timeIntervalSince(cursor),
                                        detail: modelDetail,
                                        runID: turn.events.first?.runID))
        }
        return segments
    }

    /// Chat-only turns (no run): a Director or Coding Agent turn the user drove directly,
    /// recorded with a breakdown but no `runID`. Each becomes a single-turn record (id = the
    /// message id, empty rollup) so the Profiler lists and renders them with the same detail
    /// view as runs. Newest first, capped — the run records carry the history; this is recency.
    public static func chatTurnRecords(chat: [String: [SZChatMessage]],
                                       titles: [String: String], limit: Int = 20) -> [RunRecord] {
        var records: [RunRecord] = []
        for (scopeKey, messages) in chat {
            for message in messages {
                guard let events = message.breakdown, !events.isEmpty,
                      events.allSatisfy({ $0.runID == nil }),
                      !events.contains(where: { $0.stage == SZTurnStage.runTotal }),
                      let duration = message.duration else { continue }
                let isDirector = scopeKey == SZChatScope.directorKey
                let label = isDirector ? "Director" : (titles[scopeKey] ?? String(scopeKey.prefix(8)))
                records.append(RunRecord(
                    id: message.id, startedAt: message.timestamp, wallDuration: duration,
                    rollup: [],
                    turns: [RunTurn(scopeKey: scopeKey, label: label, isDirector: isDirector,
                                    start: message.timestamp, duration: duration,
                                    usage: message.usage, events: events,
                                    turnID: message.id)]))
            }
        }
        return Array(records.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    /// The run report as plain text — one implementation for the panel's Copy button and
    /// `debug_run_summary`, so a human and a debugging agent read the same thing.
    public static func renderSummary(_ record: RunRecord) -> String {
        var lines: [String] = []
        let totalDetail = record.rollup.last { $0.stage == SZTurnStage.runTotal }?.detail
        // A chat-driven single turn (empty rollup) titles itself by its agent, not a run id.
        let title = record.rollup.isEmpty
            ? "Turn — \(record.turns.first?.label ?? "agent")"
            : "Run \(record.id.uuidString.prefix(8))"
        lines.append("\(title) — \(summaryDate(record.startedAt)) · "
                     + "wall \(format(record.wallDuration))"
                     + (totalDetail.map { " · \($0)" } ?? ""))
        if record.rollup.isEmpty {
            // No run rows to lay out — the per-turn phase list below is the whole story.
            return (lines + turnSections(record)).joined(separator: "\n")
        }
        lines.append("")
        lines.append("timeline:")
        for row in record.rollup where row.stage != SZTurnStage.runTotal {
            let offset = row.start.timeIntervalSince(record.startedAt)
            let name = row.stage == SZTurnStage.runNode
                ? (row.detail?.components(separatedBy: " · ").first ?? "node")
                : SZTurnStage.displayName(row.stage)
            let extra: String
            if row.stage == SZTurnStage.runNode {
                let parts = row.detail?.components(separatedBy: " · ").dropFirst() ?? []
                extra = parts.isEmpty ? "" : " — \(parts.joined(separator: " · "))"
            } else {
                extra = row.detail.map { " — \($0)" } ?? ""
            }
            // "Mac Camera  46s — 1 turn · compile 1.6s (starts +17s)": what, how long, then when
            // it began relative to the run (omitted when it starts the run).
            let starts = offset >= 1 ? "  (starts +\(format(offset)))" : ""
            lines.append("  \(name)  \(row.duration.map(format) ?? "")\(extra)\(starts)")
        }
        return (lines + turnSections(record)).joined(separator: "\n")
    }

    /// The per-turn phase lists — shared by the run and single-turn summary shapes.
    private static func turnSections(_ record: RunRecord) -> [String] {
        var lines: [String] = []
        for turn in record.turns {
            lines.append("")
            let usage = turn.usage.map {
                " · \(formatTokens($0.inputTokens)) in / \(formatTokens($0.outputTokens)) out"
            } ?? ""
            lines.append("[\(turn.label)] \(turn.duration.map(format) ?? "?")\(usage)")
            for event in turn.events {
                lines.append("  \(rowTitle(for: event, in: turn.events))  \(event.duration.map(format) ?? "")")
            }
        }
        return lines
    }

    /// The run's token story as plain text — one implementation for the panel's Copy Tokens
    /// button and `debug_run_tokens`, so pasting it into a debugging conversation carries the
    /// same numbers the panel shows. Per-turn on purpose: CLIs report usage once, at turn end.
    public static func renderTokenReport(_ record: RunRecord) -> String {
        let title = record.rollup.isEmpty
            ? "Turn — \(record.turns.first?.label ?? "agent")"
            : "Run \(record.id.uuidString.prefix(8))"
        // Totals from the rollup's run.total row where one exists (it carries the cached share
        // and cost the run narration showed), else folded from the turns.
        let totals = record.rollup.last { $0.stage == SZTurnStage.runTotal }?.detail
            ?? totalsDetail(turns: record.turns)
        var lines = ["tokens — \(title) · \(summaryDate(record.startedAt))"
                     + (totals.map { " · \($0)" } ?? "")]
        lines.append("")
        let labelWidth = (record.turns.map { $0.label.count + 2 }.max() ?? 2)
        for turn in record.turns {
            let offset = turn.start.timeIntervalSince(record.startedAt)
            let when = (offset >= 1 ? "+\(format(offset))" : "0").leftPadded(to: 7)
            let label = "[\(turn.label)]".rightPadded(to: labelWidth)
            lines.append("  \(when)  \(label)  "
                         + (turn.usage.map(tokenLine) ?? "(no usage reported)"))
        }
        lines.append("")
        lines.append("(per-turn totals — the CLI reports usage once, at turn end)")
        return lines.joined(separator: "\n")
    }

    /// "166.6k in (89% cached) / 1.2k out (321 reasoning) · $0.31" — a single usage, spelled out.
    public static func tokenLine(_ usage: SZTokenUsage) -> String {
        var s = "\(formatTokens(usage.inputTokens)) in"
        if let cached = usage.cachedInputTokens, usage.inputTokens > 0 {
            s += " (\(Int((Double(cached) / Double(usage.inputTokens) * 100).rounded()))% cached)"
        }
        s += " / \(formatTokens(usage.outputTokens)) out"
        if let reasoning = usage.reasoningOutputTokens, reasoning > 0 {
            s += " (\(formatTokens(reasoning)) reasoning)"
        }
        if let cost = usage.costUSD { s += String(format: " · $%.2f", cost) }
        return s
    }

    private static func summaryDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func stageTotal(_ stage: String, in turns: [RunTurn]) -> (count: Int, seconds: TimeInterval) {
        let events = turns.flatMap(\.events).filter { $0.stage == stage }
        return (events.count, events.compactMap(\.duration).reduce(0, +))
    }

    private static func totalsDetail(turns: [RunTurn]) -> String? {
        guard let usage = totalUsage(of: turns) else { return nil }
        var s = "\(formatTokens(usage.inputTokens)) in / \(formatTokens(usage.outputTokens)) out"
        if let cached = usage.cachedInputTokens, usage.inputTokens > 0 {
            s += " (\(Int((Double(cached) / Double(usage.inputTokens) * 100).rounded()))% cached)"
        }
        if let cost = usage.costUSD { s += String(format: " · $%.2f", cost) }
        return s
    }

    /// Compact duration for breakdown rows and detail strings ("218µs", "2.1ms", "7.9s", "2m 12s").
    /// The precision tier follows the magnitude — a 200µs host tool must not read as "0ms", and a
    /// 2ms span not as noise.
    public static func format(_ seconds: TimeInterval) -> String {
        // A negative duration is a measurement bug (a wall-clock step) — render it LOUD, never
        // mask it as "0µs".
        if seconds < 0 { return "−" + format(-seconds) }
        if seconds < 0.0000005 { return "0µs" }
        if seconds < 0.0009995 { return "\(Int((seconds * 1_000_000).rounded()))µs" }
        if seconds < 0.009995 { return String(format: "%.1fms", seconds * 1000) }
        if seconds < 0.9995 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds < 9.95 { return String(format: "%.1fs", seconds) }
        if seconds < 59.5 { return "\(Int(seconds.rounded()))s" }
        let whole = Int(seconds.rounded())
        return "\(whole / 60)m \(whole % 60)s"
    }

    /// Tiered like SZUI's `szFormatTokensCompact` (which delegates here): the 999_950 boundary
    /// keeps "1000.0k" from ever rendering — a fleet run's totals reach millions.
    public static func formatTokens(_ count: Int) -> String {
        switch count {
        case ..<1000: return "\(count)"
        case ..<999_950: return String(format: "%.1fk", Double(count) / 1000)
        default: return String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }
}

extension String {
    fileprivate func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
    fileprivate func rightPadded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
