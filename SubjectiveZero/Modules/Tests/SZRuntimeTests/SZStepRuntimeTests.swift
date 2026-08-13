// SPDX-License-Identifier: AGPL-3.0-only
// The keyed execution tier over the step loader, proven against real swiftc → dlopen
// round-trips: schedule+evaluate, evaluate-awaits-the-compile, keep-old-on-red with the
// report callback, the evaluation watchdog, and latest-source-wins coalescing.
import Testing
import Foundation
import Synchronization
@testable import SZRuntime

// MARK: - Harness

/// Write `source` as a `Step.swift` in a fresh temp dir and hand back the three paths one
/// `scheduleLoad` wants. Each call gets its own dirs — reloads for the same key arrive as
/// fresh sources on disk, exactly like authored edits.
private func writeStep(_ source: String) throws -> (source: URL, build: URL, loads: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "sz-step-runtime-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stepURL = dir.appending(path: "Step.swift")
    try source.write(to: stepURL, atomically: true, encoding: .utf8)
    return (stepURL, dir.appending(path: "build"), dir.appending(path: "runtime-loads"))
}

@MainActor
private func schedule(_ runtime: SZStepRuntime, key: SZStepKey, source: String) throws {
    let paths = try writeStep(source)
    runtime.scheduleLoad(key: key, sourceURL: paths.source,
                         buildDir: paths.build, runtimeLoadsDir: paths.loads)
}

/// A step that answers a fixed string — cheap to compile, and trivially distinguishable
/// across reloads.
private func fixedOutcomeStep(_ outcome: String) -> String {
    """
    struct Fixed: SZStep {
        func evaluate(_ ctx: SZContext<SZChatFacts>) async throws -> String { "\(outcome)" }
    }
    let step = Fixed()
    """
}

private let workLeftCondition = """
let step = SZBuildCondition { $0.hasWorkLeft }
"""

/// Parks inside an ask until the host's runner settles it — the watchdog's prey.
private let blockingAskStep = """
let step = SZChatRouter("done") { ctx in
    _ = try await ctx.askModel(template: "block", as: [String: String].self)
    return "done"
}
"""

private let noAsk: SZStepAskRunner = { _ in throw CancellationError() }

/// Complete facts documents — the snapshot is all-required by design.
private func runtimeBuildFacts(workLeft: Int) -> String {
    let ids = "[" + (0..<workLeft).map { _ in "\"node-\(UUID().uuidString.prefix(8))\"" }.joined(separator: ", ") + "]"
    return #"{"unimplemented": \#(ids), "workSet": \#(ids), "nodeStatuses": {}, "buildErrors": {}, "round": 1, "roundCap": 2, "briefed": false, "projectLoaded": true, "graphJSON": "{}", "steers": [], "runVariant": ""}"#
}
private let runtimeChatFacts = #"{"sentMessage": "hey", "resuming": false, "draftedWork": false}"#

// MARK: - Tests

/// Serialized: each test drives real swiftc invocations; parallel compile storms are the
/// exact failure the runtime's compile slots exist to prevent.
@Suite(.serialized) @MainActor
struct SZStepRuntimeTests {

    @Test func scheduleThenEvaluateRoundTripsWithoutWaitingForTheCompile() async throws {
        let runtime = SZStepRuntime()
        let key = SZStepKey(agent: "director", step: "work-left")
        #expect(!runtime.isLoaded(key: key))
        try schedule(runtime, key: key, source: workLeftCondition)

        // No manual wait between schedule and evaluate — the await-the-compile contract IS
        // what makes this deterministic.
        #expect(await runtime.evaluate(key: key, factsJSON: runtimeBuildFacts(workLeft: 2), ask: noAsk) == .outcome("yes"))
        #expect(await runtime.evaluate(key: key, factsJSON: runtimeBuildFacts(workLeft: 0), ask: noAsk) == .outcome("no"))

        // The table reads agree, and the declaration is the step's own (yes/no).
        #expect(runtime.isLoaded(key: key))
        #expect(runtime.loadedKeys == [key])
        let declaration = try #require(runtime.declaration(key: key))
        #expect(declaration.contains("\"yes\"") && declaration.contains("\"no\""))

        // A key nothing was ever scheduled for fails, loudly and by name.
        let missing = await runtime.evaluate(
            key: SZStepKey(agent: "director", step: "absent"), factsJSON: runtimeChatFacts, ask: noAsk)
        #expect(missing == .failed("no step is loaded for director/absent"))

        // Unload drops the runtime's handle: the key stops answering.
        runtime.unload(key: key)
        #expect(!runtime.isLoaded(key: key))
        #expect(runtime.loadedKeys.isEmpty)
        #expect(runtime.declaration(key: key) == nil)
    }

    @Test func aRedCompileKeepsTheOldModuleAnsweringAndReportsOnce() async throws {
        let runtime = SZStepRuntime()
        let key = SZStepKey(agent: "director", step: "work-left")
        let reports = Mutex<[(SZStepKey, String)]>([])
        runtime.onRedCompile = { key, message in reports.withLock { $0.append((key, message)) } }

        try schedule(runtime, key: key, source: workLeftCondition)
        #expect(await runtime.evaluate(key: key, factsJSON: runtimeBuildFacts(workLeft: 1), ask: noAsk) == .outcome("yes"))

        // A source that cannot compile: the old module keeps answering, and the failure is
        // reported exactly once, key attached.
        try schedule(runtime, key: key, source: "let step = SZCondition {")
        #expect(await runtime.evaluate(key: key, factsJSON: runtimeBuildFacts(workLeft: 1), ask: noAsk) == .outcome("yes"))
        let seen = reports.withLock { $0 }
        #expect(seen.count == 1)
        #expect(seen.first?.0 == key)
        #expect(seen.first?.1.isEmpty == false)
    }

    @Test func theWatchdogTimesOutAParkedEvaluationAndTheStepStillServesAfter() async throws {
        let runtime = SZStepRuntime()
        let key = SZStepKey(agent: "coding", step: "gate")
        try schedule(runtime, key: key, source: blockingAskStep)
        runtime.evaluationDeadline = .seconds(1)

        // The runner never answers on its own; only the watchdog's cancellation frees it.
        let result = await runtime.evaluate(key: key, factsJSON: runtimeChatFacts) { _ in
            try await Task.sleep(for: .seconds(3600))
            return "{}"
        }
        guard case .failed(let reason) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason.contains("timed out"))
        #expect(reason.contains("coding/gate"))
        #expect(reason.contains("1s"))

        // The module settled cleanly: a fresh evaluation on the same key still answers.
        runtime.evaluationDeadline = .seconds(120)
        #expect(await runtime.evaluate(key: key, factsJSON: runtimeChatFacts) { _ in "{}" } == .outcome("done"))
    }

    @Test func aCallersOwnCancellationStaysCancelledNotATimeout() async throws {
        let runtime = SZStepRuntime()
        let key = SZStepKey(agent: "coding", step: "gate")
        try schedule(runtime, key: key, source: blockingAskStep)

        let askEntered = Mutex(false)
        let evaluation = Task {
            await runtime.evaluate(key: key, factsJSON: runtimeChatFacts) { _ in
                askEntered.withLock { $0 = true }
                try await Task.sleep(for: .seconds(3600))
                return "{}"
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        while !askEntered.withLock({ $0 }) {
            try #require(clock.now - start < .seconds(30), "the step never reached its ask")
            try await Task.sleep(for: .milliseconds(25))
        }
        evaluation.cancel()
        // The deadline never expired, so this is the caller's cancel — not a failure.
        #expect(await evaluation.value == .cancelled)
    }

    @Test func coalescedSchedulesEndWithTheLatestSourceLive() async throws {
        let runtime = SZStepRuntime()
        let key = SZStepKey(agent: "director", step: "verdict")

        // Three schedules back-to-back: the first starts compiling, the second parks, the
        // third replaces the parked one. Latest source wins.
        try schedule(runtime, key: key, source: fixedOutcomeStep("v1"))
        try schedule(runtime, key: key, source: fixedOutcomeStep("v2"))
        try schedule(runtime, key: key, source: fixedOutcomeStep("v3"))

        #expect(await runtime.evaluate(key: key, factsJSON: runtimeChatFacts, ask: noAsk) == .outcome("v3"))
    }
}
