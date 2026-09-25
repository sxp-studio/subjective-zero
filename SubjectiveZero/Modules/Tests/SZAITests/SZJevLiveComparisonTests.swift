// SPDX-License-Identifier: AGPL-3.0-only
// Live, opt-in: the same sorting asks served twice through the app's own query service, once
// by the provider (the Sort slot's Claude CLI run) and once by Jev, recording request size,
// tokens and wall time. Skipped unless SZ_JEV_KEY is set; writes JSON lines to SZ_JEV_LIVE_OUT.
//   SZ_JEV_KEY=$(security find-generic-password -s studio.sxp.SubjectiveZero.jev -a api-key -w) \
//   SZ_JEV_LIVE_OUT=/path/out.jsonl swift test --filter SZJevLiveComparisonTests
import Foundation
import Synchronization
import Testing
@testable import SZAI
@testable import SZCore

private let env = ProcessInfo.processInfo.environment

private struct LiveCase: Sendable {
    var id: String
    var agent: String
    var message: String
    var world: SZWorld
    var gold: String
}

private func cases() -> [LiveCase] {
    let crt = SZTask(id: UUID(), title: "CRT look",
                     instruction: "make it look like an old CRT tv with scanlines and a bit of curvature",
                     state: .pending, workSet: [UUID(), UUID(), UUID()],
                     createdAt: Date(timeIntervalSinceReferenceDate: 1))
    let bloom = SZTask(id: UUID(), title: "Glow bloom",
                       instruction: "add a soft bloom glow, bright parts should bleed",
                       state: .running, workSet: [UUID(), UUID()],
                       createdAt: Date(timeIntervalSinceReferenceDate: 2))
    return [
        LiveCase(id: "new-build", agent: "director",
                 message: "make an animated gradient that slowly cycles through colors",
                 world: SZWorld(), gold: "implement"),
        LiveCase(id: "steer-running", agent: "director", message: "add a glow to the scanlines",
                 world: SZWorld(pendingTasks: [crt], runningTasks: [bloom]), gold: "amend"),
        LiveCase(id: "node-edit", agent: "coding", message: "can you expose the radius as a slider?",
                 world: SZWorld(), gold: "edit"),
    ]
}

/// What one served ask cost, whichever side served it.
private final class Capture: Sendable {
    let requestBytes = Mutex<Int?>(nil)
    let tokens = Mutex<(input: Int, cached: Int?, cost: Double?)?>(nil)
}

@MainActor
@Suite(.serialized, .enabled(if: env["SZ_JEV_KEY"] != nil))
struct SZJevLiveComparisonTests {

    @Test func sortingThroughTheProviderAndThroughJev() async throws {
        let key = try #require(env["SZ_JEV_KEY"])
        let root = try #require(SZAgentPackLoader.bundledRoot)
        let renderer = SZBriefRenderer(packRoot: root)
        let reps = Int(env["SZ_JEV_LIVE_REPS"] ?? "5") ?? 5
        // One working folder for every call, as the app's query lane has.
        let cache = FileManager.default.temporaryDirectory.appending(path: "sz-jev-live")
        let sort = SZIdentityRouter(choice: SZModelChoice(providerID: "claude", model: "claude-haiku-4-5",
                                                          reasoningEffort: "high"))
        let runner = SZSystemProcessRunner()
        var lines: [String] = []

        for rep in 1...reps {
            for c in cases() {
                for side in ["provider", "jev"] {
                    let capture = Capture()
                    let executor: SZQueryExecutor = { request, provider in
                        capture.requestBytes.withLock { $0 = request.prompt.utf8.count }
                        let result = try await provider.run(request, runner: runner)
                        let consumer = provider.makeStreamConsumer()
                        var reply = ""
                        var events: [SZAgentStreamEvent] = []
                        for line in result.process.output.split(whereSeparator: \.isNewline) {
                            events += consumer.consume(String(line))
                        }
                        events += consumer.finish()
                        for event in events {
                            switch event {
                            case .reply(let text): reply += text
                            case .usage(let u):
                                capture.tokens.withLock { $0 = (u.inputTokens, u.cachedInputTokens, u.costUSD) }
                            default: break
                            }
                        }
                        return reply
                    }
                    var decider: SZQueryDecider?
                    if side == "jev" {
                        let jev = SZJevClient(key: key).decider()
                        decider = { decision, state in
                            let body = try JSONEncoder().encode(
                                ["state": state, "model": SZJevClient.model])
                            let question = try JSONEncoder().encode(SZJevClient.Question(decision))
                            capture.requestBytes.withLock { $0 = body.count + question.count }
                            return try await jev(decision, state)
                        }
                    }
                    var records: [SZQueryRecord] = []
                    let service = SZQueryService(renderer: renderer, router: sort, cacheDirectory: cache,
                                                 executor: executor, decider: decider,
                                                 onRecord: { records.append($0) })
                    let started = Date()
                    let reply = try await service.serve(agent: c.agent, step: "door", message: c.message,
                                                        world: c.world,
                                                        requestJSON: #"{"template": "triage", "attempt": 0}"#)
                    let wall = Date().timeIntervalSince(started)
                    let record = records.last
                    let answer = reply.firstMatch(of: /"outcome"\s*:\s*"(\w[\w-]*)"/).map { String($0.1) }
                    let tokens = capture.tokens.withLock { $0 }
                    let row: [String: Any?] = [
                        "rep": rep, "case": c.id, "side": side, "servedBy": record?.providerID,
                        "gold": c.gold, "answer": answer, "wall_s": wall,
                        "request_bytes": capture.requestBytes.withLock { $0 },
                        "input_tokens": side == "jev" ? record?.inputTokens : tokens?.input,
                        "cached_tokens": tokens?.cached, "cost_usd": tokens?.cost,
                        "confidence": record?.confidence, "fallback": record?.deciderFailure,
                    ]
                    let data = try JSONSerialization.data(withJSONObject: row.compactMapValues { $0 },
                                                          options: .sortedKeys)
                    lines.append(String(decoding: data, as: UTF8.self))
                    print("[jev-live] \(lines.last!)")
                }
            }
        }
        if let out = env["SZ_JEV_LIVE_OUT"] {
            try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}
