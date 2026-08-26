// SPDX-License-Identifier: AGPL-3.0-only
// P0 proving ground for the step ABI: real swiftc → codesign → dlopen round-trips exercising
// the async evaluation contract — sync one-liners, `ctx.ask` typed rulings with repair
// retry, cancellation mid-flight, swap-with-drain hot reload, and the layout pin that keeps
// the host's request struct byte-matched with the kit's copy.
import Testing
import Foundation
import Synchronization
@testable import SZRuntime

// MARK: - Harness

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "sz-step-spike-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Write `source` as a `Step.swift`, compile it through the real toolchain, and load it.
private func loadStep(_ source: String, into loader: SZStepLoader? = nil) throws -> SZStepLoader {
    let dir = try makeTempDir()
    let stepURL = dir.appending(path: "Step.swift")
    try source.write(to: stepURL, atomically: true, encoding: .utf8)
    let dylib = try SZToolchain().compile(stepSource: stepURL, into: dir.appending(path: "build"))
    let target = loader ?? SZStepLoader()
    try target.load(dylib: dylib, runtimeLoadsDir: dir.appending(path: "runtime-loads"))
    return target
}

/// The host-side mirror of the kit's ask request, for asserting what a step sent.
private struct AskRequest: Decodable {
    struct Repair: Decodable { let error: String; let previousReply: String }
    let template: String
    let attempt: Int
    let repair: Repair?
}

private func decodeAsk(_ json: String) throws -> AskRequest {
    try JSONDecoder().decode(AskRequest.self, from: Data(json.utf8))
}

private struct EventuallyTimeout: Error {}

/// Throws on timeout so a stuck precondition fails the test THERE, instead of letting it
/// run on and drown the real failure in secondary ones.
private func eventually(within deadline: Duration = .seconds(15),
                        _ condition: @Sendable () -> Bool) async throws {
    let clock = ContinuousClock()
    let start = clock.now
    while !condition() {
        if clock.now - start > deadline {
            Issue.record("condition never became true within \(deadline)")
            throw EventuallyTimeout()
        }
        try await Task.sleep(for: .milliseconds(25))
    }
}

// MARK: - Step sources and facts documents

private let workLeftStep = """
let step = SZStep(outcomes: ["yes", "no"]) { $0.hasWorkLeft ? "yes" : "no" }
"""

private let classifyStep = """
struct Ruling: Codable { let kind: String }
let step = SZStep(outcomes: ["answer", "build"]) { ctx in
    try await ctx.ask("classify-reply", as: Ruling.self).kind
}
"""

/// Blocks inside an ask until the host's runner releases it — the in-flight body for the
/// cancellation and drain tests.
private let blockingAskStep = """
let step = SZStep(outcomes: ["done"]) { ctx in
    _ = try await ctx.ask("block", as: [String: String].self)
    return "done"
}
"""

/// Reports the kit-side layout of the request struct, interpolation-free.
private let layoutProbeStep = """
let step = SZStep(outcomes: ["layout"]) { _ in
    let parts = [
        MemoryLayout<SZStepEvalRequestRaw>.size,
        MemoryLayout<SZStepEvalRequestRaw>.alignment,
        MemoryLayout<SZStepEvalRequestRaw>.offset(of: \\.apiVersion) ?? -1,
        MemoryLayout<SZStepEvalRequestRaw>.offset(of: \\.factsJSON) ?? -1,
        MemoryLayout<SZStepEvalRequestRaw>.offset(of: \\.factsLen) ?? -1,
        MemoryLayout<SZStepEvalRequestRaw>.offset(of: \\.hostContext) ?? -1,
        MemoryLayout<SZStepEvalRequestRaw>.offset(of: \\.askFn) ?? -1,
    ]
    return parts.map(String.init).joined(separator: "/")
}
"""

/// A complete build-kind facts document — the snapshot is all-required by design (a silent
/// nil was the old architecture's favorite way to lie), so tests send every field.
private func buildFacts(workLeft: Int) -> String {
    let ids = "[" + (0..<workLeft).map { _ in "\"\(UUID().uuidString)\"" }.joined(separator: ", ") + "]"
    return #"{"message": "", "resuming": false, "pendingTasks": [], "runningTasks": [], "run": {"workSet": \#(ids), "round": 1, "roundCap": 2, "steers": [], "instruction": "", "unwired": []}}"#
}

private let chatFacts = #"{"message": "hey", "resuming": false, "pendingTasks": [], "runningTasks": []}"#

// MARK: - Tests

/// Serialized: each test drives a real swiftc; parallel compile storms help nobody.
@Suite(.serialized)
struct SZStepABISpikeTests {

    @Test func aSyncConditionCompilesLoadsAndAnswers() async throws {
        let loader = try loadStep(workLeftStep)

        // The one-line authoring surface declares itself: its outcomes, no sidecar.
        let declaration = try #require(loader.declaration)
        #expect(declaration == #"{"outcomes":["yes","no"]}"#)

        let noAsk: SZStepAskRunner = { _ in throw CancellationError() }
        #expect(await loader.evaluate(factsJSON: buildFacts(workLeft: 2), ask: noAsk) == .outcome("yes"))
        #expect(await loader.evaluate(factsJSON: buildFacts(workLeft: 0), ask: noAsk) == .outcome("no"))
        // A prose delivery carries no run — the gate answers its honest "no".
        #expect(await loader.evaluate(factsJSON: chatFacts, ask: noAsk) == .outcome("no"))
        // A document missing the REQUIRED fields refuses to start rather than silently
        // reading neutral values.
        guard case .failed(let reason) = await loader.evaluate(factsJSON: "{}", ask: noAsk) else {
            Issue.record("an incomplete facts document must refuse to start")
            return
        }
        #expect(reason.contains("could not start"))
    }

    @Test func anAskModelStepGetsATypedRulingThroughProse() async throws {
        let loader = try loadStep(classifyStep)
        let seen = Mutex<[String]>([])

        // The reply arrives fenced in chatter — the tolerant extractor's whole point.
        let result = await loader.evaluate(factsJSON: chatFacts) { request in
            seen.withLock { $0.append(request) }
            return "Sure! Here's the ruling:\n```json\n{\"kind\": \"build\"}\n```\nLet me know!"
        }
        #expect(result == .outcome("build"))

        let requests = seen.withLock { $0 }
        #expect(requests.count == 1)
        let ask = try decodeAsk(try #require(requests.first))
        #expect(ask.template == "classify-reply")
        #expect(ask.attempt == 0)
        #expect(ask.repair == nil)
    }

    @Test func aShapeMismatchTriggersOneRepairRetryCarryingTheError() async throws {
        let loader = try loadStep(classifyStep)
        let seen = Mutex<[String]>([])

        let result = await loader.evaluate(factsJSON: chatFacts) { request in
            let attempt = seen.withLock { $0.append(request); return $0.count }
            return attempt == 1 ? "I think the answer is probably fine." : #"{"kind": "answer"}"#
        }
        #expect(result == .outcome("answer"))

        let requests = seen.withLock { $0 }
        #expect(requests.count == 2)
        let retry = try decodeAsk(try #require(requests.last))
        #expect(retry.attempt == 1)
        let repair = try #require(retry.repair)
        #expect(repair.previousReply == "I think the answer is probably fine.")
        #expect(!repair.error.isEmpty)
    }

    @Test func exhaustedRepairsFailWithTheTemplateNamed() async throws {
        let loader = try loadStep(classifyStep)
        let calls = Mutex(0)
        let result = await loader.evaluate(factsJSON: chatFacts) { _ in
            calls.withLock { $0 += 1 }
            return "still just prose, no JSON anywhere"
        }
        guard case .failed(let reason) = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
        #expect(reason.contains("classify-reply"))
        #expect(reason.contains("never matched"))
        // The default retries: 1 means exactly two attempts — the exhaustion half of the contract.
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func braceyRepliesStillYieldTheirRuling() async throws {
        let loader = try loadStep(classifyStep)

        // A brace inside a JSON string must not derail the balanced scan…
        let inString = await loader.evaluate(factsJSON: chatFacts) { _ in
            #"Sure: {"kind": "a}b"} hope that helps!"#
        }
        #expect(inString == .outcome("a}b"))

        // …and a prose restatement of the requested format must not eat the real answer.
        let restated = await loader.evaluate(factsJSON: chatFacts) { _ in
            #"Answer in the form {json}. Here you go: {"kind": "build"}"#
        }
        #expect(restated == .outcome("build"))
    }

    @Test func aRedReloadNeverCostsTheGreenModule() async throws {
        let loader = try loadStep(workLeftStep)
        let noAsk: SZStepAskRunner = { _ in throw CancellationError() }

        // A step source that does not compile: the toolchain throws, the loader is untouched.
        let dir = try makeTempDir()
        let broken = dir.appending(path: "Step.swift")
        try "let step = SZStep(outcomes: [\"x\"]) {".write(to: broken, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            try SZToolchain().compile(stepSource: broken, into: dir.appending(path: "build"))
        }

        // A dylib that cannot be mapped: load() throws and the old module keeps answering.
        let garbage = dir.appending(path: "garbage.dylib")
        try Data("not a mach-o".utf8).write(to: garbage)
        #expect(throws: (any Error).self) {
            try loader.load(dylib: garbage, runtimeLoadsDir: dir.appending(path: "runtime-loads"))
        }
        #expect(await loader.evaluate(factsJSON: buildFacts(workLeft: 1), ask: noAsk) == .outcome("yes"))
    }

    @Test func aStepDeclaringNothingReadsAsNil() async throws {
        // Empty outcomes = the step declares nothing; the gate refuses to wire edges
        // from it, and the declaration channel honestly answers nil.
        let loader = try loadStep("""
        let step = SZStep(outcomes: []) { _ in "spoke" }
        """)
        #expect(loader.declaration == nil)
        let noAsk: SZStepAskRunner = { _ in throw CancellationError() }
        #expect(await loader.evaluate(factsJSON: chatFacts, ask: noAsk) == .outcome("spoke"))
    }

    @Test func cancellationMidAskSettlesAsCancelledNotDefect() async throws {
        let loader = try loadStep(blockingAskStep)
        let askEntered = Mutex(false)

        let evaluation = Task {
            await loader.evaluate(factsJSON: chatFacts) { _ in
                askEntered.withLock { $0 = true }
                try await Task.sleep(for: .seconds(300))   // parked until cancelled
                return "{}"
            }
        }
        try await eventually { askEntered.withLock { $0 } }
        evaluation.cancel()
        #expect(await evaluation.value == .cancelled)

        // The module settled cleanly: a fresh evaluation still runs on the same loader.
        let after = await loader.evaluate(factsJSON: chatFacts) { _ in #"{"kind": "x"}"# }
        #expect(after == .outcome("done"))
    }

    @Test func hotReloadSwapsForNewEvaluationsWhileTheOldDrains() async throws {
        let loader = try loadStep(blockingAskStep)
        let askEntered = Mutex(false)
        let released = Mutex(false)

        // Park one evaluation on the OLD module.
        let inFlight = Task {
            await loader.evaluate(factsJSON: chatFacts) { _ in
                askEntered.withLock { $0 = true }
                while !released.withLock({ $0 }) {
                    try await Task.sleep(for: .milliseconds(25))
                }
                return "{}"
            }
        }
        try await eventually { askEntered.withLock { $0 } }

        // Swap in a different step. The old module must retire, not die.
        _ = try loadStep(workLeftStep, into: loader)
        #expect(loader.drainingCount == 1)

        // New evaluations run the NEW code while the old evaluation is still parked.
        let noAsk: SZStepAskRunner = { _ in throw CancellationError() }
        #expect(await loader.evaluate(factsJSON: buildFacts(workLeft: 1), ask: noAsk) == .outcome("yes"))

        // Release the parked evaluation: it completes on the OLD code, then the old module closes.
        released.withLock { $0 = true }
        #expect(await inFlight.value == .outcome("done"))
        try await eventually { loader.drainingCount == 0 }
    }

    /// The rebuild's top-ranked risk: Swift runtime metadata surviving dlclose. Hammer the
    /// exact hazard — every swap happens while the outgoing module still runs an evaluation,
    /// so every dlclose is a drain-triggered close, and evaluations keep flowing after it.
    @Test func repeatedSwapsWhileInFlightNeverCorruptTheLoader() async throws {
        let loader = try loadStep(blockingAskStep)
        for round in 0..<4 {
            let askEntered = Mutex(false)
            let released = Mutex(false)
            let parked = Task {
                await loader.evaluate(factsJSON: chatFacts) { _ in
                    askEntered.withLock { $0 = true }
                    while !released.withLock({ $0 }) {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    return "{}"
                }
            }
            try await eventually { askEntered.withLock { $0 } }
            // Swap under it — alternate the incoming source so codepaths actually differ.
            _ = try loadStep(round.isMultiple(of: 2) ? workLeftStep : blockingAskStep, into: loader)
            released.withLock { $0 = true }
            #expect(await parked.value == .outcome("done"))
            try await eventually { loader.drainingCount == 0 }

            // The freshly swapped-in module answers sanely; re-park for the next round.
            if round.isMultiple(of: 2) {
                let noAsk: SZStepAskRunner = { _ in throw CancellationError() }
                #expect(await loader.evaluate(factsJSON: buildFacts(workLeft: 3), ask: noAsk) == .outcome("yes"))
                _ = try loadStep(blockingAskStep, into: loader)
            }
        }
    }

    /// The P0 demo's live half, gated so the ordinary suite spends no tokens: a REAL compiled
    /// step gets a typed ruling from a REAL model through the `claude` CLI. Run with
    /// `SZ_P0_LIVE_ASK=1 swift test --filter liveModel`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SZ_P0_LIVE_ASK"] == "1"))
    func liveModelReturnsATypedRulingThroughACompiledStep() async throws {
        let loader = try loadStep(classifyStep)
        let result = await loader.evaluate(factsJSON: chatFacts) { requestJSON in
            let ask = try decodeAsk(requestJSON)
            // Stand-in for the P2 QueryService: template name → a rendered prompt. The
            // repair loop rides `attempt`/`repair` exactly as production will.
            var prompt = """
            The user replied: "looks great, make it so". Classify the reply.
            Answer ONLY with JSON: {"kind": "answer"} or {"kind": "build"}.
            """
            if let repair = ask.repair {
                prompt += "\nYour previous reply (\(repair.previousReply)) failed to decode: \(repair.error). Answer with ONLY the JSON."
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["claude", "-p", prompt, "--output-format", "text"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        #expect(result == .outcome("build"))
    }

    @Test func theRequestStructLayoutMatchesAcrossTheBoundary() async throws {
        let loader = try loadStep(layoutProbeStep)
        let noAsk: SZStepAskRunner = { _ in throw CancellationError() }
        let result = await loader.evaluate(factsJSON: chatFacts, ask: noAsk)

        let hostParts = [
            MemoryLayout<SZStepEvalRequestRaw>.size,
            MemoryLayout<SZStepEvalRequestRaw>.alignment,
            MemoryLayout<SZStepEvalRequestRaw>.offset(of: \.apiVersion) ?? -1,
            MemoryLayout<SZStepEvalRequestRaw>.offset(of: \.factsJSON) ?? -1,
            MemoryLayout<SZStepEvalRequestRaw>.offset(of: \.factsLen) ?? -1,
            MemoryLayout<SZStepEvalRequestRaw>.offset(of: \.hostContext) ?? -1,
            MemoryLayout<SZStepEvalRequestRaw>.offset(of: \.askFn) ?? -1,
        ]
        #expect(result == .outcome(hostParts.map(String.init).joined(separator: "/")))
    }
}
