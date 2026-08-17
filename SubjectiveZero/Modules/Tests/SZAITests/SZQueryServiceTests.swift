// SPDX-License-Identifier: AGPL-3.0-only
// The query service, piece by piece against a scripted executor: request decode, brief-grade
// template resolution + rendering against the pinned snapshot, the repair wrapper on a
// retry, routing through the model seam, the stateless-request shape (no MCP, no session,
// no tools), and the journal every exchange leaves behind.
import Foundation
import Synchronization
import Testing
@testable import SZAI
@testable import SZCore

/// A template source that records what was asked of it — the resolution proof.
private final class ScriptedTemplates: Sendable {
    let paths = Mutex<[String]>([])
    let templates: [String: String]

    init(templates: [String: String]) {
        self.templates = templates
    }

    func source() -> SZBriefRenderer.TemplateSource {
        { agent, path in
            self.paths.withLock { $0.append("\(agent)/\(path)") }
            guard let text = self.templates[path] else {
                throw SZBriefRenderError.missingTemplate(agent: agent, path: path)
            }
            return text
        }
    }
}

/// One captured executor call: the assembled run request + the routed provider's id.
private final class ExecutorLog: @unchecked Sendable {
    let lock = NSLock()
    private(set) var calls: [(request: SZAgentRunRequest, providerID: String)] = []
    func record(_ request: SZAgentRunRequest, _ providerID: String) {
        lock.lock(); calls.append((request, providerID)); lock.unlock()
    }
}

@MainActor
private func makeService(
    templates: [String: String],
    providerID: String = "claude",
    model: String? = "routed-model",
    effort: String? = "high",
    reply: String = "scripted reply",
    log: ExecutorLog = ExecutorLog(),
    onRecord: @escaping @MainActor @Sendable (SZQueryRecord) -> Void = { _ in }
) -> (service: SZQueryService, log: ExecutorLog, templateSource: ScriptedTemplates) {
    let scripted = ScriptedTemplates(templates: templates)
    let service = SZQueryService(
        renderer: SZBriefRenderer(templates: scripted.source()),
        router: SZIdentityRouter(choice: SZModelChoice(providerID: providerID, model: model,
                                                       reasoningEffort: effort)),
        cacheDirectory: FileManager.default.temporaryDirectory
            .appending(path: "sz-query-test-\(UUID().uuidString)"),
        executor: { request, provider in
            log.record(request, provider.id)
            return reply
        },
        onRecord: onRecord)
    return (service, log, scripted)
}

/// The pinned snapshot the asks render against: a live run at round 2 of 3.
private let roundWorld = SZWorld(run: SZRun(workSet: [], round: 2, roundCap: 3,
                                            steers: [], instruction: ""))

/// MainActor mailbox for the onRecord hook (a @Sendable closure cannot capture a local var).
@MainActor
private final class RecordBox {
    var records: [SZQueryRecord] = []
}

@MainActor
struct SZQueryServiceTests {

    @Test func aFirstAskRendersRoutesCompletesAndJournals() async throws {
        let seen = RecordBox()
        let (service, log, templates) = makeService(
            templates: ["prompts/classify-reply.md.mustache": "CLASSIFY r{{round}}/{{cap}}"],
            onRecord: { seen.records.append($0) })

        let reply = try await service.serve(
            agent: "director", step: "work-left", message: "", world: roundWorld,
            requestJSON: #"{"template": "classify-reply", "attempt": 0}"#)
        #expect(reply == "scripted reply")

        // The NAME resolved like a brief: pack-relative, under prompts/, .md.mustache.
        #expect(templates.paths.withLock { $0 } == ["director/prompts/classify-reply.md.mustache"])

        // One stateless completion: rendered prompt, routed model/effort, NO MCP port,
        // NO session resume, NO tools, and the tight query budgets.
        let call = try #require(log.calls.first)
        #expect(call.providerID == "claude")
        #expect(call.request.prompt == "CLASSIFY r2/3")
        #expect(call.request.model == "routed-model")
        #expect(call.request.reasoningEffort == "high")
        #expect(call.request.mcpServerPort == nil)
        #expect(call.request.resumeSessionID == nil)
        #expect(call.request.allowedMCPTools.isEmpty)
        #expect(call.request.timeout == SZQueryBudgets.timeout)
        #expect(call.request.inactivityTimeout == SZQueryBudgets.inactivityTimeout)

        // The exchange journaled, and mirrored through the hook.
        #expect(service.journal.count == 1)
        let record = try #require(service.journal.first)
        #expect(record.step == "work-left")
        #expect(record.attempt == 0)
        #expect(record.template == "classify-reply")
        #expect(record.promptHash == SZQueryService.hash("CLASSIFY r2/3"))
        #expect(record.reply == "scripted reply")
        #expect(seen.records == service.journal)
    }

    @Test func aRetryAppendsTheRepairWrapperBelowTheReRenderedAsk() async throws {
        let (service, log, _) = makeService(
            templates: ["prompts/classify-reply.md.mustache": "CLASSIFY"])
        _ = try await service.serve(
            agent: "director", step: "work-left", message: "", world: roundWorld,
            requestJSON: #"""
            {"template": "classify-reply", "attempt": 1,
             "repair": {"error": "missing key 'outcome'", "previousReply": "just prose"}}
            """#)
        let prompt = try #require(log.calls.first?.request.prompt)
        #expect(prompt.hasPrefix("CLASSIFY\n"))
        // The wrapper is the host-owned template with both tokens substituted.
        #expect(prompt.contains("missing key 'outcome'"))
        #expect(prompt.contains("just prose"))
        #expect(prompt.contains("did not decode"))
        #expect(service.journal.first?.attempt == 1)
    }

    @Test func templateNamesCarryingAPathAreTakenAsWritten() {
        #expect(SZBriefRenderer.templatePath("classify-reply") == "prompts/classify-reply.md.mustache")
        #expect(SZBriefRenderer.templatePath("prompts/classify-reply.md.mustache")
            == "prompts/classify-reply.md.mustache")
    }

    @Test func anUnknownRoutedProviderRefusesTheAsk() async throws {
        let (service, log, _) = makeService(
            templates: ["prompts/t.md.mustache": "T"], providerID: "no-such-provider")
        await #expect(throws: SZQueryError.self) {
            _ = try await service.serve(agent: "director", step: "s", message: "",
                                        world: roundWorld,
                                        requestJSON: #"{"template": "t", "attempt": 0}"#)
        }
        #expect(log.calls.isEmpty)
        #expect(service.journal.isEmpty)
    }

    @Test func anUnreadableRequestIsItsOwnHonestError() async throws {
        let (service, _, _) = makeService(templates: [:])
        await #expect(throws: SZQueryError.self) {
            _ = try await service.serve(agent: "director", step: "s", message: "",
                                        world: roundWorld, requestJSON: "not json")
        }
    }

    @Test func aMissingTemplateSurfacesAsTheRendererRefusal() async throws {
        let (service, _, _) = makeService(templates: [:])
        await #expect(throws: SZBriefRenderError.self) {
            _ = try await service.serve(agent: "director", step: "s", message: "",
                                        world: roundWorld,
                                        requestJSON: #"{"template": "ghost", "attempt": 0}"#)
        }
    }

    // MARK: - What a failed completion says

    @Test func aSpentBudgetSaysWhichDeadlineFired() {
        // This lane runs the provider itself, so nothing upstream stamps the timeout — an
        // unexplained "no message" is exactly the bug.
        let request = queryRequest()
        #expect(SZQueryService.failureDetail(failedResult(timeout: .wallClock), request: request)
                    .contains("timed out after 45s"))
        #expect(SZQueryService.failureDetail(failedResult(timeout: .silence), request: request)
                    .contains("went silent for 30s"))
    }

    @Test func theProvidersOwnWordsAlwaysWin() {
        var result = failedResult(timeout: .wallClock)
        result.outcome.message = "usage limit reached"
        #expect(SZQueryService.failureDetail(result, request: queryRequest()) == "usage limit reached")
    }

    @Test func aFailureWithNoBudgetAndNoWordsStaysHonest() {
        #expect(SZQueryService.failureDetail(failedResult(timeout: nil), request: queryRequest())
                    == "the provider reported a failure with no message")
    }
}

/// The query lane's own request shape — the budgets are what the sentence quotes.
private func queryRequest() -> SZAgentRunRequest {
    SZAgentRunRequest(prompt: "ask", workingDirectory: FileManager.default.temporaryDirectory,
                      cacheDirectory: FileManager.default.temporaryDirectory,
                      timeout: SZQueryBudgets.timeout,
                      inactivityTimeout: SZQueryBudgets.inactivityTimeout)
}

private func failedResult(timeout: SZProcessTimeout?) -> SZAgentRunResult {
    SZAgentRunResult(process: SZProcessResult(exitCode: 124, output: "", timeout: timeout),
                     outcome: SZAgentOutcome(sessionID: nil, failed: true))
}
