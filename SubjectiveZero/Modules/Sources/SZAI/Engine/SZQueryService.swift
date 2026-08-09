// SPDX-License-Identifier: AGPL-3.0-only
// The query service — where a step's `askModel` becomes a real completion. One serve is the
// whole exchange: decode the SDK's ask request, render the named template exactly like a
// brief (same pack-relative resolution, same facts document the evaluation was pinned to),
// append the host-owned repair wrapper on a retry, route through the model-routing seam
// (`class: .query`), run ONE stateless completion — no MCP, no session, no tools — and
// journal the exchange. Steps never name a model and never see a provider; both live
// entirely on this side of the ABI.
import Foundation
import CryptoKit
import SZCore

/// One stateless query completion: the assembled request + the routed provider → the raw
/// reply text. Injected for tests (scripted replies); nil at construction = the service's
/// own `provider.run` path — production's.
public typealias SZQueryExecutor =
    @Sendable (SZAgentRunRequest, any SZProvider) async throws -> String

/// Everything serving one ask can refuse. `CancellationError` is never wrapped — it must
/// reach the step's ask as a cancellation, not a failure.
public enum SZQueryError: Error, CustomStringConvertible {
    /// The ask request JSON would not decode — an SDK/host drift, not a model failure.
    case unreadableRequest(detail: String)
    /// The provider ran and reported failure (its message attached when it left one).
    case completionFailed(String)

    public var description: String {
        switch self {
        case .unreadableRequest(let detail): "unreadable ask request: \(detail)"
        case .completionFailed(let detail): "the query completion failed: \(detail)"
        }
    }
}

/// Per-query budgets, tighter than a turn's: a step's ask is one small stateless completion,
/// so two minutes of wall clock (or silence) means something is wrong — fail the ask and let
/// the step's own error contract take over.
/// A step's question is one small stateless completion, not a turn: it must never hold a
/// scope's claim for a turn's patience. (The claim it rides is the delivery's — see the
/// delivery's, so a slow ruling delays the next message on that scope.)
public enum SZQueryBudgets {
    public static let timeout: TimeInterval = 45
    public static let inactivityTimeout: TimeInterval = 30
}

@MainActor
public final class SZQueryService {
    private let renderer: SZBriefRenderer
    private let router: any SZModelRouting
    private let registry: SZProviderRegistry
    private let cacheDirectory: URL
    private let executor: SZQueryExecutor
    private let onRecord: @MainActor @Sendable (SZQueryRecord) -> Void
    /// Every exchange this service ran, in order — the strategy's `onQuery` hook mirrors it
    /// live; the host can persist it later.
    public private(set) var journal: [SZQueryRecord] = []

    public init(renderer: SZBriefRenderer,
                router: any SZModelRouting,
                registry: SZProviderRegistry = .shared,
                cacheDirectory: URL,
                runner: any SZProcessRunning = SZSystemProcessRunner(),
                executor: SZQueryExecutor? = nil,
                onRecord: @escaping @MainActor @Sendable (SZQueryRecord) -> Void = { _ in }) {
        self.renderer = renderer
        self.router = router
        self.registry = registry
        self.cacheDirectory = cacheDirectory
        self.executor = executor ?? Self.providerRunExecutor(runner: runner)
        self.onRecord = onRecord
    }

    // MARK: - The request as the SDK sends it (mirror of the step SDK's SZAskRequest)

    private struct AskRequest: Decodable {
        struct Repair: Decodable {
            var error: String
            var previousReply: String
        }

        var template: String
        var attempt: Int
        var repair: Repair?
    }

    // MARK: - Serving

    /// Serve one step ask end to end. `kind` is the GRAPH's own kind (a settled re-entry
    /// traverses its build graph, so it renders as build by construction) and `factsJSON`
    /// is the SAME pinned document the evaluation was handed — the engine supplies both.
    /// Throwing `CancellationError` answers the ask as cancelled; any other throw as failed.
    public func serve(agent: String, graph: String?, step: String, kind: SZMessageKind,
                      factsJSON: String, requestJSON: String) async throws -> String {
        let request: AskRequest
        do {
            request = try JSONDecoder().decode(AskRequest.self, from: Data(requestJSON.utf8))
        } catch {
            throw SZQueryError.unreadableRequest(detail: String(describing: error))
        }

        // The named template, pack-relative, resolved and rendered EXACTLY like a brief —
        // one resolution, one token namespace, one facts document.
        var prompt = try renderer.render(agent: agent, template: Self.templatePath(request.template),
                                         kind: kind, factsJSON: factsJSON)
        // A retry carries the repair wrapper: the host-owned template, appended below the
        // re-rendered ask so the model sees the question and why its last answer failed.
        if request.attempt > 0, let repair = request.repair {
            prompt += "\n" + SZPromptTemplate.render(SZPrompts.askRepair, [
                // Defused: these are MODEL-controlled text, and render walks an unordered
                // dictionary — a live token inside a substituted value would expand or not
                // depending on the process hash seed.
                "error": SZPromptTemplate.defused(repair.error),
                "previousReply": SZPromptTemplate.defused(repair.previousReply),
            ])
        }

        let choice = router.resolve(SZModelCall(class: .query, agent: agent,
                                                graph: graph, step: step))
        guard let provider = registry.provider(id: choice.providerID) else {
            throw SZOrchestratorError.unknownProvider(choice.providerID)
        }

        // One stateless completion: no MCP port, no resume, no tools — a query is a
        // question, never an agent turn.
        let workingDirectory = cacheDirectory.appending(path: "query")
        try? FileManager.default.createDirectory(at: workingDirectory,
                                                 withIntermediateDirectories: true)
        let run = SZAgentRunRequest(
            prompt: prompt,
            workingDirectory: workingDirectory,
            cacheDirectory: cacheDirectory,
            model: choice.model,
            reasoningEffort: choice.reasoningEffort,
            timeout: SZQueryBudgets.timeout,
            inactivityTimeout: SZQueryBudgets.inactivityTimeout)
        let reply = try await executor(run, provider)

        let record = SZQueryRecord(step: step, attempt: request.attempt,
                                   template: request.template,
                                   promptHash: Self.hash(prompt), reply: reply)
        journal.append(record)
        onRecord(record)
        return reply
    }

    // MARK: - Pieces

    /// The pack-relative path an ask template name resolves to — the same `prompts/` home
    /// turn briefs live in. A name that already carries a path is taken as written.
    static func templatePath(_ name: String) -> String {
        name.contains("/") ? name : "prompts/\(name).md.mustache"
    }

    /// A stable short digest of the rendered prompt bytes.
    static func hash(_ prompt: String) -> String {
        SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }
            .joined().prefix(16).lowercased()
    }

    /// The production executor: run the routed provider once and return the reply text —
    /// the provider's own stream classification over the captured output, whole output as
    /// the honest fallback for a CLI whose consumer yields nothing.
    static func providerRunExecutor(runner: any SZProcessRunning) -> SZQueryExecutor {
        { request, provider in
            let result = try await provider.run(request, runner: runner)
            if result.outcome.failed {
                throw SZQueryError.completionFailed(
                    result.outcome.message ?? "the provider reported a failure with no message")
            }
            let consumer = provider.makeStreamConsumer()
            var reply: [String] = []
            func collect(_ events: [SZAgentStreamEvent]) {
                for event in events {
                    if case .reply(let text) = event { reply.append(text) }
                }
            }
            for line in result.process.output.split(whereSeparator: \.isNewline) {
                collect(consumer.consume(String(line)))
            }
            collect(consumer.finish())
            let joined = reply.joined()
            return joined.isEmpty ? result.process.output : joined
        }
    }
}
