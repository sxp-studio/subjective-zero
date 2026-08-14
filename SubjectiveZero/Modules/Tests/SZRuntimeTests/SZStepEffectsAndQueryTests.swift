// SPDX-License-Identifier: AGPL-3.0-only
// P6's two wires, proven through REAL compiled steps (swiftc → codesign → dlopen):
// - EFFECTS on the success payload: an effect-emitting answer rides the additive JSON
//   envelope while every bare-outcome spelling stays byte-identical to before;
// - askModel SERVED: the SZAI query service is the loader's ask runner end to end — render,
//   repair retry, route, journal — with only the completion executor scripted.
import Foundation
import Synchronization
import Testing
@testable import SZAI
@testable import SZRuntime

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "sz-step-p6-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func loadStep(_ source: String) throws -> SZStepLoader {
    let dir = try makeTempDir()
    let stepURL = dir.appending(path: "Step.swift")
    try source.write(to: stepURL, atomically: true, encoding: .utf8)
    let dylib = try SZToolchain().compile(stepSource: stepURL, into: dir.appending(path: "build"))
    let loader = SZStepLoader()
    try loader.load(dylib: dylib, runtimeLoadsDir: dir.appending(path: "runtime-loads"))
    return loader
}

private let chatFacts = #"{"sentMessage": "hey", "resuming": false, "draftedWork": false}"#

/// An effect-emitting router, still one line — the authoring bar the wire had to clear.
private let effectRouter = """
let step = SZMessageRouter("answer", "build") { _ in .outcome("build", effects: ["requestBuild"]) }
"""

/// The mixed closure: a bare string literal in one branch, an effect answer in the other —
/// both spellings at home in ONE body (`SZAnswer`'s string-literal conformance).
private let mixedRouter = """
let step = SZMessageRouter("answer", "build") { ctx in
    if ctx.resuming { return "answer" }
    return .outcome("build", effects: ["requestBuild"])
}
"""

/// The spike's askModel router, unchanged — the QueryService integration drives it.
private let classifyRouter = """
struct Ruling: Codable { let kind: String }
let step = SZMessageRouter("answer", "build") { ctx in
    try await ctx.askModel(template: "classify-reply", as: Ruling.self).kind
}
"""

/// Serialized: each test drives a real swiftc.
@Suite(.serialized)
struct SZStepEffectsAndQueryTests {

    @Test func anEffectAnswerRidesTheJSONEnvelope() async throws {
        let loader = try loadStep(effectRouter)
        let noAsk: SZStepAskRunner = { _ in throw CancellationError() }
        let result = await loader.evaluate(factsJSON: chatFacts, ask: noAsk)
        // Deterministic envelope bytes (.sortedKeys): effects before outcome.
        #expect(result == .outcome(#"{"effects":["requestBuild"],"outcome":"build"}"#))
    }

    @Test func aMixedBodyKeepsBareStringsBareAndEnvelopesEffects() async throws {
        let loader = try loadStep(mixedRouter)
        let noAsk: SZStepAskRunner = { _ in throw CancellationError() }
        // resuming=false takes the effect branch…
        #expect(await loader.evaluate(factsJSON: chatFacts, ask: noAsk)
            == .outcome(#"{"effects":["requestBuild"],"outcome":"build"}"#))
        // …resuming=true the bare-literal branch: the payload is the outcome string, no
        // envelope — the additive-wire guarantee, on the SAME compiled step.
        let resumed = #"{"sentMessage": "hey", "resuming": true, "draftedWork": false}"#
        #expect(await loader.evaluate(factsJSON: resumed, ask: noAsk) == .outcome("answer"))
    }

    @MainActor
    @Test func aCompiledAskModelStepIsServedByTheQueryService() async throws {
        let loader = try loadStep(classifyRouter)

        // The real query service as the ask runner; only the completion is scripted —
        // garbage prose first, the ruling on the repair retry, so the SDK's repair loop and
        // the service's repair wrapper are proven together.
        let prompts = Mutex<[String]>([])
        let service = SZQueryService(
            renderer: SZBriefRenderer { _, path in
                guard path == "prompts/classify-reply.md.mustache" else {
                    throw SZBriefRenderError.missingTemplate(agent: "coding", path: path)
                }
                return "CLASSIFY: {{message}}"
            },
            router: SZIdentityRouter(choice: SZModelChoice(providerID: "claude",
                                                           model: "routed-model",
                                                           reasoningEffort: nil)),
            cacheDirectory: FileManager.default.temporaryDirectory
                .appending(path: "sz-query-int-\(UUID().uuidString)"),
            executor: { request, provider in
                #expect(provider.id == "claude")
                #expect(request.mcpServerPort == nil)
                #expect(request.resumeSessionID == nil)
                #expect(request.allowedMCPTools.isEmpty)
                let attempt = prompts.withLock { $0.append(request.prompt); return $0.count }
                return attempt == 1 ? "hmm, probably build?" : #"{"kind": "build"}"#
            })

        let result = await loader.evaluate(factsJSON: chatFacts) { requestJSON in
            try await service.serve(agent: "coding", graph: "message", step: "classify",
                                    kind: .message, factsJSON: chatFacts,
                                    requestJSON: requestJSON)
        }
        #expect(result == .outcome("build"))

        // Two exchanges: the rendered ask, then the SAME ask with the repair wrapper below
        // it carrying the decode error and the previous reply.
        let sent = prompts.withLock { $0 }
        #expect(sent.count == 2)
        #expect(sent[0] == "CLASSIFY: hey")
        #expect(sent[1].hasPrefix("CLASSIFY: hey\n"))
        #expect(sent[1].contains("hmm, probably build?"))
        #expect(sent[1].contains("did not decode"))

        // Both exchanges journaled, keyed to the step and its attempts.
        #expect(service.journal.map(\.attempt) == [0, 1])
        #expect(service.journal.map(\.step) == ["classify", "classify"])
        #expect(service.journal.last?.reply == #"{"kind": "build"}"#)
    }
}
