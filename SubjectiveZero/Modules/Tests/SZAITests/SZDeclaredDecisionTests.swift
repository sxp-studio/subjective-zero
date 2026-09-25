// SPDX-License-Identifier: AGPL-3.0-only
// Declared decisions: the query service hands an ask with a `.decision.json` to the decider,
// falls back to the completion when the decider fails, and leaves undeclared asks alone. Plus
// the Jev client's wire shapes and the shipped declarations.
import Foundation
import Synchronization
import Testing
@testable import SZAI
@testable import SZCore

private let triageDecision = """
{"key": "outcome", "state": "triage-state", "instructions": "sort it",
 "choices": {"answer": "words", "implement": "build", "amend": "steer"}}
"""

private let templates: [String: String] = [
    "prompts/triage.md.mustache": "CLASSIFY {{message}}",
    "prompts/triage-state.md.mustache": "MSG {{message}}",
    "prompts/triage.decision.json": triageDecision,
]

@MainActor
private final class Calls {
    var completions = 0
    var states: [String] = []
    var records: [SZQueryRecord] = []
}

@MainActor
private func makeService(templates: [String: String], calls: Calls,
                         decider: SZQueryDecider?) -> SZQueryService {
    SZQueryService(
        renderer: SZBriefRenderer { _, path in
            guard let text = templates[path] else {
                throw SZBriefRenderError.missingTemplate(agent: "director", path: path)
            }
            return text
        },
        router: SZIdentityRouter(choice: SZModelChoice(providerID: "claude", model: "m")),
        cacheDirectory: FileManager.default.temporaryDirectory.appending(path: "sz-decision-\(UUID().uuidString)"),
        executor: { _, _ in
            await MainActor.run { calls.completions += 1 }
            return #"{"outcome": "answer"}"#
        },
        decider: decider,
        onRecord: { calls.records.append($0) })
}

private struct Refused: Error {}

@MainActor
struct SZDeclaredDecisionTests {

    @Test func aDeclaredAskIsAnsweredByTheDeciderAlone() async throws {
        let calls = Calls()
        let service = makeService(templates: templates, calls: calls) { decision, state in
            await MainActor.run { calls.states.append(state) }
            #expect(decision.choices?.keys.sorted() == ["amend", "answer", "implement"])
            return SZDecisionAnswer(value: "amend", confidence: 0.9, deciderID: "test",
                                    inputTokens: 42, latency: 0.2)
        }
        let reply = try await service.serve(agent: "director", step: "door", message: "and slower",
                                            world: SZWorld(), requestJSON: #"{"template": "triage", "attempt": 0}"#)
        #expect(reply == #"{"outcome":"amend"}"#)
        #expect(calls.completions == 0)
        #expect(calls.states == ["MSG and slower"])
        let record = try #require(calls.records.first)
        #expect(record.providerID == "test")
        #expect(record.inputTokens == 42)
        #expect(record.confidence == 0.9)
    }

    @Test func aFailingDeciderFallsBackToTheCompletion() async throws {
        let calls = Calls()
        let service = makeService(templates: templates, calls: calls) { _, _ in throw Refused() }
        let reply = try await service.serve(agent: "director", step: "door", message: "hi",
                                            world: SZWorld(), requestJSON: #"{"template": "triage", "attempt": 0}"#)
        #expect(reply == #"{"outcome": "answer"}"#)
        #expect(calls.completions == 1)
        #expect(calls.records.first?.deciderFailure != nil)
        #expect(calls.records.first?.providerID == "claude")
    }

    @Test func anUndeclaredAskNeverReachesTheDecider() async throws {
        let calls = Calls()
        var bare = templates
        bare["prompts/triage.decision.json"] = nil
        let service = makeService(templates: bare, calls: calls) { _, _ in
            Issue.record("the decider ran for an undeclared ask")
            return SZDecisionAnswer(value: "amend", deciderID: "test", latency: 0)
        }
        _ = try await service.serve(agent: "director", step: "door", message: "hi",
                                    world: SZWorld(), requestJSON: #"{"template": "triage", "attempt": 0}"#)
        #expect(calls.completions == 1)
        #expect(calls.records.first?.deciderFailure == nil)
    }

    @Test func aRepairRetrySkipsTheDecider() async throws {
        let calls = Calls()
        let service = makeService(templates: templates, calls: calls) { _, _ in
            Issue.record("the decider ran on a retry")
            return SZDecisionAnswer(value: "amend", deciderID: "test", latency: 0)
        }
        _ = try await service.serve(
            agent: "director", step: "door", message: "hi", world: SZWorld(),
            requestJSON: #"{"template": "triage", "attempt": 1, "repair": {"error": "e", "previousReply": "x"}}"#)
        #expect(calls.completions == 1)
    }

    // MARK: - Jev wire shapes

    @Test func declarationsBecomeJevQuestions() throws {
        let choice = try JSONDecoder().decode(SZDeclaredDecision.self, from: Data(triageDecision.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let choiceJSON = String(decoding: try encoder.encode(SZJevClient.Question(choice)), as: UTF8.self)
        #expect(choiceJSON == #"{"criteria":{"amend":"steer","answer":"words","implement":"build"},"instructions":"sort it","type":"choice"}"#)

        let scale = SZDeclaredDecision(key: "complexity", state: "s", instructions: "rate",
                                       levels: ["light", "standard", "heavy"])
        let scaleJSON = String(decoding: try encoder.encode(SZJevClient.Question(scale)), as: UTF8.self)
        #expect(scaleJSON == #"{"criteria":["light","standard","heavy"],"instructions":"rate","type":"score"}"#)
    }

    @Test func jevAnswersMapToDeclaredNames() throws {
        let choice = try JSONDecoder().decode(SZDeclaredDecision.self, from: Data(triageDecision.utf8))
        #expect(try SZJevClient.value(of: .init(choice: "amend"), for: choice) == "amend")
        #expect(throws: SZJevError.self) { try SZJevClient.value(of: .init(choice: "delete"), for: choice) }

        let scale = SZDeclaredDecision(key: "k", state: "s", instructions: "i", levels: ["light", "standard", "heavy"])
        #expect(try SZJevClient.value(of: .init(score: 1.4), for: scale) == "standard")
        #expect(try SZJevClient.value(of: .init(score: 7), for: scale) == "heavy")
    }

    @Test func jevStatusesMapToErrors() async throws {
        for (status, expected) in [(401, SZJevError.keyRejected), (402, .noBalance), (429, .rateLimited)] {
            JevStub.respond.withLock { $0 = (status, Data("{}".utf8)) }
            await #expect(throws: expected) { try await JevStub.client().verify() }
        }
        JevStub.respond.withLock {
            $0 = (200, Data(#"{"model":"jev-latest","answers":{"outcome":{"type":"choice","choice":"edit","confidence":0.8}},"usage":{"input_tokens":120,"output_tokens":9}}"#.utf8))
        }
        let decision = SZDeclaredDecision(key: "outcome", state: "s", instructions: "i",
                                          choices: ["edit": "e", "chat": "c"])
        let answer = try await JevStub.client().decider()(decision, "MSG")
        #expect(answer.value == "edit")
        #expect(answer.inputTokens == 120)
        #expect(answer.confidence == 0.8)
        #expect(answer.deciderID == "jev")
    }

    // MARK: - The shipped declarations

    @Test func shippedDeclarationsDecodeAndMatchTheirSteps() throws {
        let root = try #require(SZAgentPackLoader.bundledRoot)
        let expected = ["director": ["amend", "answer", "implement"], "coding": ["chat", "edit"]]
        for (agent, outcomes) in expected {
            let prompts = root.appending(path: agent).appending(path: "prompts")
            let data = try Data(contentsOf: prompts.appending(path: "triage.decision.json"))
            let decision = try JSONDecoder().decode(SZDeclaredDecision.self, from: data)
            #expect(decision.key == "outcome")
            #expect(decision.choices?.keys.sorted() == outcomes)
            #expect(FileManager.default.fileExists(
                atPath: prompts.appending(path: "\(decision.state).md.mustache").path))
        }
    }
}

/// A URLProtocol answering every request with one scripted status + body.
private final class JevStub: URLProtocol {
    static let respond = Mutex<(Int, Data)>((200, Data()))

    static func client() -> SZJevClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JevStub.self]
        return SZJevClient(key: "jv_live_test", session: URLSession(configuration: config))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.respond.withLock { $0 }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
