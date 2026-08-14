// SPDX-License-Identifier: AGPL-3.0-only
// The AUTHORING.md "Ask the model from code" sample, compiled through the REAL toolchain
// and driven end to end — the doc and this test carry the same bytes, so if the SDK drifts
// the tutorial fails before a reader does. What the sample demonstrates is the whole ask
// contract from a step's side: ONE typed model question, awaited, the reply decoded into
// the step's own type (with the host's repair loop on a shape mismatch), and the answer
// routed as an outcome.
import Foundation
import Synchronization
import Testing
@testable import SZRuntime

/// The exact step the tutorial prints. The prompt template ("triage") is resolved and
/// rendered HOST-side at run time against the same facts this evaluation holds — the step
/// never sees a provider, never names a model, and never builds a prompt string.
private let tutorialStepSource = """
// director/steps/triage/Step.swift
struct Verdict: Codable {
    enum Call: String, Codable { case retry, park }
    let call: Call
}
let step = SZStep(outcomes: ["retry", "park"]) { ctx in
    let verdict = try await ctx.ask("triage", as: Verdict.self)
    return verdict.call.rawValue
}
"""

private func facts() -> String {
    #"{"message": "", "resuming": false}"#
}

/// Serialized like the other step suites: each test drives a real swiftc.
@Suite(.serialized) @MainActor
struct SZAskModelExampleTests {

    private func compiled() throws -> (loader: SZStepLoader, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sz-askmodel-example-\(UUID().uuidString)")
        let source = dir.appending(path: "Step.swift")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try tutorialStepSource.write(to: source, atomically: true, encoding: .utf8)
        let dylib = try SZToolchain().compile(stepSource: source,
                                              into: dir.appending(path: "build"))
        let loader = SZStepLoader()
        try loader.load(dylib: dylib, runtimeLoadsDir: dir.appending(path: "runtime-loads"))
        return (loader, dir)
    }

    @Test func theTutorialStepAsksOnceAndRoutesTheTypedReply() async throws {
        let (loader, dir) = try compiled()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The compiled module EXPORTS its declaration — the pack gate reads the outcomes
        // from here, so a wrong wiring is refused at load, not at runtime.
        #expect(loader.declaration == #"{"outcomes":["retry","park"]}"#)

        let asked = Mutex<[String]>([])
        let outcome = await loader.evaluate(factsJSON: facts()) { request in
            asked.withLock { $0.append(request) }
            return #"{"call": "retry"}"#   // what the routed provider replied
        }
        #expect(outcome == .outcome("retry"))
        // ONE completion, naming the pack template the host will render.
        let requests = asked.withLock { $0 }
        #expect(requests.count == 1)
        #expect(requests[0].contains(#""template":"triage""#))
    }

    @Test func aMalformedReplyIsRepairedOnceThenDecoded() async throws {
        let (loader, dir) = try compiled()
        defer { try? FileManager.default.removeItem(at: dir) }

        // First reply is prose; askModel re-asks with the decode error attached (the
        // repair loop), and the second, typed reply routes. The step's code never sees
        // the failure — the contract is "a typed value, or an honest throw".
        let replies = Mutex(["let me think about that…", #"{"call": "park"}"#])
        let asked = Mutex<[String]>([])
        let outcome = await loader.evaluate(factsJSON: facts()) { request in
            asked.withLock { $0.append(request) }
            return replies.withLock { $0.removeFirst() }
        }
        #expect(outcome == .outcome("park"))
        let requests = asked.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests[1].contains(#""attempt":1"#))
        #expect(requests[1].contains("repair"))
    }
}
