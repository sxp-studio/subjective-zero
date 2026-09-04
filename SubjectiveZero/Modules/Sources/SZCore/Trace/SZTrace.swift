// SPDX-License-Identifier: AGPL-3.0-only
// THE way to measure anything in this codebase: wrap it in a debug fence.
//
//     SZTrace.span(SZTurnStage.compileCheck) { compile(...) }       // a timed phase
//     let fence = SZTrace.begin("my.stage"); ...; fence.end()       // when begin/end straddle scopes
//     SZTrace.instant(SZTurnStage.toolCall, detail: name)           // a moment worth marking
//
// Fences work from ANY module on ANY thread and attribute automatically: the turn owner binds
// `SZTrace.$context` (a task-local) around the work, and Swift's structured concurrency carries it
// through every plain `await` and into unstructured `Task {}` children (inherited at creation).
// A `span {}` also pushes itself as the ambient parent, so nested fences form a tree
// (`SZTurnEvent.parentID`) — the bridge's mcp.tool span parents the compile/promote fences inside
// the handler with zero plumbing.
//
// Attribution rules (drop-by-design — an event is DROPPED, never misfiled):
//   - tracing disabled (`isEnabled`, SZ_TRACE=1/0 override, else DEBUG on / release off) → no-op;
//   - no ambient context (off-turn work: cold project loads, file-watcher reloads, probes) → no-op;
//   - `Task.detached` and GCD callbacks (readabilityHandler, network handlers, terminationHandler)
//     carry NO task-locals — never `begin` a fence there. A fence BEGUN in task code may `end()`
//     anywhere: it captured its context at begin.
//
// Events land keyed by the context's turnID; the turn owner collects them at turn end with
// `take(turnID:)` (explicit key — turn finalization runs in a `defer` OUTSIDE the binding) and
// folds them onto the turn's message. See SZTurnBreakdown for the event/stage model.
import Foundation
import Synchronization

/// Who a trace event belongs to. Bound as a task-local by the turn owner (`deliver`) or the
/// attribution resolver (the MCP bridge); fences read it — no parameters threaded anywhere.
public struct SZTraceContext: Sendable, Equatable {
    /// The assistant message the turn streams into — the key events land under.
    public var turnID: UUID
    public var scopeKey: String
    /// The owning run, for run-owned turns — stamped onto every event so a run's turns can be
    /// found across scopes without time-window guessing.
    public var runID: UUID?

    public init(turnID: UUID, scopeKey: String, runID: UUID? = nil) {
        self.turnID = turnID
        self.scopeKey = scopeKey
        self.runID = runID
    }
}

/// The instrumentation facade — static so a fence is a one-liner anywhere. State lives in a
/// shared `SZTraceRecorder`; tests instantiate their own.
public enum SZTrace {
    /// THE gate: `SZ_TRACE=1/0` overrides; default on in DEBUG builds, off in release. Evaluated
    /// once — call sites compile in every build and no-op here, so enabling in prod later is a
    /// launch-env (or default flip) away.
    public static let isEnabled: Bool = enabled(env: ProcessInfo.processInfo.environment)

    /// The gate's truth table, pure for tests.
    static func enabled(env: [String: String]) -> Bool {
        switch env["SZ_TRACE"] {
        case "1": return true
        case "0": return false
        default:
            #if DEBUG
            return true
            #else
            return false
            #endif
        }
    }

    /// The ambient attribution — bound by turn owners, read by every fence.
    @TaskLocal public static var context: SZTraceContext?
    /// The enclosing `span {}`'s event id — how nested fences get their `parentID`.
    @TaskLocal static var currentParent: UUID?

    static let shared = SZTraceRecorder()

    /// A moment worth marking (no duration) — e.g. a streamed tool-use sighting.
    public static func instant(_ stage: String, detail: String? = nil) {
        guard isEnabled, let context else { return }
        shared.record(SZTurnEvent(stage: stage, start: Date(), duration: nil, detail: detail,
                                  parentID: currentParent, runID: context.runID),
                      turnID: context.turnID)
    }

    /// Open a fence. Captures start AND context now, so `end()` attributes correctly from
    /// anywhere — another task, a defer, after an actor hop. Prefer `span {}` where the
    /// measured work is a single scope.
    public static func begin(_ stage: String, detail: String? = nil) -> SZTraceFence {
        guard isEnabled, let context else { return SZTraceFence(state: nil) }
        return SZTraceFence(state: .init(stage: stage, start: Date(),
                                         monotonicStart: ContinuousClock.now, detail: detail,
                                         context: context, id: UUID(), parent: currentParent))
    }

    /// The one-liner fence: time the closure (recorded even when it throws) and parent any
    /// fences it opens.
    @discardableResult
    public static func span<T>(_ stage: String, detail: String? = nil,
                               _ body: () throws -> T) rethrows -> T {
        let fence = begin(stage, detail: detail)
        defer { fence.end() }
        guard let id = fence.state?.id else { return try body() }
        return try $currentParent.withValue(id) { try body() }
    }

    /// Span whose close is derived from the body's RESULT — e.g. the bridge stamping a tool
    /// result's size onto its span. A thrown body records with the begin-time detail alone.
    @discardableResult
    public static func span<T>(_ stage: String, detail: String? = nil,
                               closing: (T) -> (detail: String?, addedTokens: Int?),
                               _ body: () throws -> T) rethrows -> T {
        let fence = begin(stage, detail: detail)
        guard let id = fence.state?.id else { return try body() }
        do {
            let value = try $currentParent.withValue(id) { try body() }
            let meta = closing(value)
            fence.end(detail: meta.detail, addedTokens: meta.addedTokens)
            return value
        } catch {
            fence.end()
            throw error
        }
    }

    /// Async twin of the closing span, for a body that may await.
    @discardableResult
    public static func span<T: Sendable>(_ stage: String, detail: String? = nil,
                                         closing: (T) -> (detail: String?, addedTokens: Int?),
                                         isolation: isolated (any Actor)? = #isolation,
                                         _ body: () async throws -> T) async rethrows -> T {
        let fence = begin(stage, detail: detail)
        guard let id = fence.state?.id else { return try await body() }
        do {
            let value = try await $currentParent.withValue(id) { try await body() }
            let meta = closing(value)
            fence.end(detail: meta.detail, addedTokens: meta.addedTokens)
            return value
        } catch {
            fence.end()
            throw error
        }
    }

    /// Async twin — `#isolation` keeps the caller's actor, so `span` never hops.
    @discardableResult
    public static func span<T: Sendable>(_ stage: String, detail: String? = nil,
                                         isolation: isolated (any Actor)? = #isolation,
                                         _ body: () async throws -> T) async rethrows -> T {
        let fence = begin(stage, detail: detail)
        defer { fence.end() }
        guard let id = fence.state?.id else { return try await body() }
        return try await $currentParent.withValue(id) { try await body() }
    }

    /// Record a ready-made event under an explicit turn — the escape hatch for owners that hold
    /// the key but no ambient context (queue wait is recorded before the turn's binding exists).
    public static func record(_ event: SZTurnEvent, turnID: UUID) {
        guard isEnabled else { return }
        shared.record(event, turnID: turnID)
    }

    /// Turn end: remove and return the turn's events (the owner folds them onto the message).
    public static func take(turnID: UUID) -> [SZTurnEvent] {
        guard isEnabled else { return [] }
        return shared.take(turnID: turnID)
    }

    /// Drop a turn's events without landing them (a bowed-out delivery must not leak its rows
    /// onto the scope's next turn).
    public static func discard(turnID: UUID) {
        shared.discard(turnID: turnID)
    }
}

/// An open fence — a value, so it crosses task/actor boundaries freely. `state == nil` means
/// tracing was off or no context was ambient at `begin`: `end()` is a free no-op.
public struct SZTraceFence: Sendable {
    struct State: Sendable {
        var stage: String
        var start: Date
        /// DURATIONS come from the monotonic clock (the codebase's SZActivityClock idiom) — an
        /// NTP step or manual clock change mid-span must not corrupt a measurement. `start`
        /// stays a Date: it's persisted and ordered across turns.
        var monotonicStart: ContinuousClock.Instant
        var detail: String?
        var context: SZTraceContext
        var id: UUID
        var parent: UUID?
    }
    let state: State?

    /// Close the fence. `detail` (when given) replaces the begin-time detail — e.g. an outcome
    /// ("ok"/"failed") known only at the end; `addedTokens` marks a context-adding action's
    /// approximate payload (see `SZTurnEvent.addedTokens`).
    public func end(detail: String? = nil, addedTokens: Int? = nil) {
        guard let state else { return }
        let elapsed = ContinuousClock.now - state.monotonicStart
        SZTrace.shared.record(
            SZTurnEvent(stage: state.stage, start: state.start,
                        duration: elapsed.szSeconds,
                        detail: detail ?? state.detail,
                        id: state.id, parentID: state.parent, runID: state.context.runID,
                        addedTokens: addedTokens),
            turnID: state.context.turnID)
    }
}

extension Duration {
    /// `Duration` → fractional seconds — the conversion every monotonic measurement needs
    /// (fence ends, `deliver`'s turn wall, the run rollup's end anchor).
    public var szSeconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

/// The storage: a lock-protected per-turn event map. Instantiable so tests can hammer their own;
/// the app uses `SZTrace.shared`. An uncontended `Mutex` acquire is tens of ns, and nothing
/// records on the streaming hot path (only tool sightings and turn-boundary fences), so per-turn
/// lock touches stay in the dozens.
public final class SZTraceRecorder: Sendable {
    /// Runaway guard: a turn recording more than this many events keeps the first `cap` and
    /// drops the rest — a debug view, not a flight recorder.
    private let cap: Int
    private struct Storage {
        var turns: [UUID: [SZTurnEvent]] = [:]
        /// Tombstones: recently finalized turn ids. A tool call already queued when its turn's
        /// listener died (CLI killed on timeout/cancel) can record AFTER take() — without this
        /// it would re-create the entry, never taken again, growing the map forever.
        var closedRing: [UUID] = []
        var closedSet: Set<UUID> = []
    }
    private let storage = Mutex<Storage>(Storage())

    public init(cap: Int = 512) {
        self.cap = cap
    }

    public func record(_ event: SZTurnEvent, turnID: UUID) {
        storage.withLock { state in
            guard !state.closedSet.contains(turnID) else { return }   // post-finalize straggler
            guard state.turns[turnID, default: []].count < cap else { return }
            state.turns[turnID, default: []].append(event)
        }
    }

    public func take(turnID: UUID) -> [SZTurnEvent] {
        storage.withLock { state in
            close(turnID, in: &state)
            return state.turns.removeValue(forKey: turnID) ?? []
        }
    }

    public func discard(turnID: UUID) {
        storage.withLock { state in
            close(turnID, in: &state)
            state.turns.removeValue(forKey: turnID)
        }
    }

    private func close(_ turnID: UUID, in state: inout Storage) {
        guard !state.closedSet.contains(turnID) else { return }
        state.closedRing.append(turnID)
        state.closedSet.insert(turnID)
        if state.closedRing.count > 64 {
            state.closedSet.remove(state.closedRing.removeFirst())
        }
    }
}
