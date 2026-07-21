// SPDX-License-Identifier: AGPL-3.0-only
// The provider seam: one small protocol, one plain-Swift struct per agent CLI (see Providers/).
//
// Why code, not a JSON manifest: our providers are heterogeneous *agentic CLIs* (claude, codex)
// that share no common wire protocol — different argv, MCP-attach, output stream, and session
// semantics. A config DSL would just be encoding behaviour as data.
// opencode/AI-SDK make the same call: provider behaviour lives in per-provider adapter code,
// only metadata is data. So each provider builds its own argv in `launch()` and parses its own
// output in `parse()`; `run()` is a shared default below and the health tiers live in
// SZProviderHealth.swift.
//
// CLI-ONLY: every provider is a subprocess wrapper around its CLI via SZProcess. No HTTP APIs,
// no API keys. See docs/AI_PROVIDERS.md (the "static capability manifest" = these static values).
import Foundation
import SZCore

/// A resolved command for one agent spawn (executable + argv + env).
public struct SZLaunch: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(executable: String, arguments: [String], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

/// What the orchestrator hands a provider to spawn one agent turn. `model`/`reasoningEffort` are
/// nil → the provider's default; both are opaque strings the provider passes through to its CLI.
/// `fastMode` only reaches argv for a (provider, model) pair whose `supportsFastMode(for:)` is true —
/// `resolvedGenerationSettings` has already clamped it by the time a request is built.
public struct SZAgentRunRequest: Sendable {
    public var prompt: String
    public var workingDirectory: URL      // the agent's cwd — a node's staging dir
    public var packageDirectory: URL      // the .subz project dir (granted readable)
    public var cacheDirectory: URL        // swift/clang module caches
    public var mcpServerPort: UInt16?     // nil → no MCP attached
    /// The bare MCP tool names (no `mcp__subz__` prefix) this agent is permitted to call — the app's
    /// `SZHostBridge.agentCallableToolNames`, the single source of truth. A provider that enforces a
    /// per-tool allowlist (claude's `--allowedTools`) mirrors this; the others ignore it and reach
    /// whatever the bus advertises. Empty when no MCP is attached.
    public var allowedMCPTools: [String]
    public var resumeSessionID: String?   // non-nil → continue an existing session (chat), not a fresh spawn
    public var model: String?
    public var reasoningEffort: String?
    public var fastMode: Bool
    public var timeout: TimeInterval?
    /// Max SILENCE (seconds without output) before the turn is killed; every output chunk resets the
    /// clock. nil = no silence bound. Rides alongside `timeout`, which stays the wall-clock hard cap —
    /// a CLI that is still streaming is alive, but one can also wedge (or loop) while emitting forever.
    public var inactivityTimeout: TimeInterval?
    public var onOutput: (@Sendable (String) -> Void)?

    public init(
        prompt: String,
        workingDirectory: URL,
        packageDirectory: URL? = nil,
        cacheDirectory: URL,
        mcpServerPort: UInt16? = nil,
        allowedMCPTools: [String] = [],
        resumeSessionID: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        fastMode: Bool = false,
        timeout: TimeInterval? = nil,
        inactivityTimeout: TimeInterval? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) {
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.packageDirectory = packageDirectory ?? workingDirectory
        self.cacheDirectory = cacheDirectory
        self.mcpServerPort = mcpServerPort
        self.allowedMCPTools = allowedMCPTools
        self.resumeSessionID = resumeSessionID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.fastMode = fastMode
        self.timeout = timeout
        self.inactivityTimeout = inactivityTimeout
        self.onOutput = onOutput
    }
}

/// What a provider extracts from a finished run.
public struct SZAgentOutcome: Sendable, Equatable {
    public var sessionID: String?
    public var failed: Bool
    public var message: String?

    public init(sessionID: String?, failed: Bool, message: String? = nil) {
        self.sessionID = sessionID
        self.failed = failed
        self.message = message
    }
}

public struct SZAgentRunResult: Sendable {
    public var process: SZProcessResult
    public var outcome: SZAgentOutcome
}

/// A classified piece of a provider's output stream, for the chat transcript. `thinking` and
/// `toolCall` both land in the thinking section today, but are distinct cases so the seam carries
/// what the CLI actually said — tool-call presentation (the "→ " prefix) belongs to the host's
/// render site, not to consumers. (Provider notes/warnings still ride `.thinking` as prefixed
/// text; a `.notice` case is unearned while they render identically.)
public enum SZAgentStreamEvent: Sendable, Equatable {
    case reply(String)                // text of the final answer — shown in the transcript
    case thinking(String)             // reasoning / superseded narration / provider notes
    case toolCall(name: String)       // one tool invocation, by (de-namespaced) tool name
    case usage(SZTokenUsage)          // the turn's token usage, once, where the CLI reports it
}

/// A stateful, per-turn parser for one provider's output stream. The classification logic lives in the
/// provider impl (each agentic CLI shapes its stream differently — claude stream-json vs codex jsonl)
/// but is consumed through this common API, so the host stays provider-agnostic. `consume` is fed each
/// output line as it streams; `finish` flushes the finalized reply once the stream ends (both CLIs only
/// reveal which message is the *final* answer at the end, so reply emission is deferred to there).
public protocol SZAgentStreamConsumer: AnyObject {
    func consume(_ line: String) -> [SZAgentStreamEvent]
    func finish() -> [SZAgentStreamEvent]
}

public extension SZAgentStreamConsumer {
    func finish() -> [SZAgentStreamEvent] { [] }
}

/// Default consumer for providers that don't parse a structured stream (yields nothing).
public final class SZNullStreamConsumer: SZAgentStreamConsumer {
    public init() {}
    public func consume(_ line: String) -> [SZAgentStreamEvent] { [] }
}

/// One model a provider can launch with: the exact token argv passes (PINNED version ids, not
/// floating aliases — a version-labeled menu entry must never silently re-point; new models ship
/// via app updates, the Sparkle story) plus the human label the picker shows.
///
/// The three capability fields are nil when the model shares its provider's surface, and set only
/// where the CLI was OBSERVED to diverge — never where we merely suspect it, since an unmeasured
/// override is a fabricated fact. Each has an `SZProvider.…(for:)` reader that resolves the override
/// against the provider's fallback. What any given model advertises, and the evidence for it, belongs
/// next to that model in Providers/ — not here.
public struct SZProviderModel: Sendable, Equatable, Identifiable, Codable {
    public var id: String           // argv token, e.g. "claude-opus-4-8"
    public var displayName: String  // picker label, e.g. "Opus 4.8"
    public var supportedReasoningEfforts: [String]?
    public var defaultReasoningEffort: String?
    /// nil = inherit the provider's `supportsFastMode`. Set false on a model whose CLI accepts the
    /// fast-mode argv and then declines to enable it — accepting a flag is not acting on it.
    public var supportsFastMode: Bool?

    public init(
        id: String,
        displayName: String,
        supportedReasoningEfforts: [String]? = nil,
        defaultReasoningEffort: String? = nil,
        supportsFastMode: Bool? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportsFastMode = supportsFastMode
    }
}

/// A runtime-discovered model catalog snapshot — for a CLI whose served models depend on the
/// user's own account/configuration and are enumerable from the CLI itself, so a static manifest
/// cannot know them (a BYOK multi-provider harness). The snapshot is host-persisted (app-state)
/// and re-seeded at launch, so the picker works offline from last-known truth. Static-manifest
/// providers never produce one.
public struct SZProviderModelCatalog: Codable, Sendable, Equatable {
    public var models: [SZProviderModel]
    public var defaultModelID: String?
    public var fetchedAt: Date

    public init(models: [SZProviderModel], defaultModelID: String?, fetchedAt: Date = Date()) {
        self.models = models
        self.defaultModelID = defaultModelID
        self.fetchedAt = fetchedAt
    }
}

/// One agent backend. Concrete conformers live in Providers/. The orchestrator depends only on this
/// protocol (zero provider literals) — which is what the two-backend test enforces.
public protocol SZProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var models: [SZProviderModel] { get }
    var defaultModel: String { get }
    var defaultReasoningEffort: String { get }   // opaque token; "" if the CLI has no such concept
    /// Effort tokens this CLI maps to a flag, in menu order. `[]` = the CLI has no effort concept —
    /// the UI hides the dimension and argv never emits one. The fallback for models that don't
    /// override it: read `supportedReasoningEfforts(for:)`, never this, when a model is in hand.
    var supportedReasoningEfforts: [String] { get }
    /// True if `launch()` can express fast mode in argv at all. The fallback for models that don't
    /// override it: read `supportsFastMode(for:)`, never this, before showing a toggle or emitting a
    /// flag — a CLI can carry the flag for every model it serves and honour it on only some.
    var supportsFastMode: Bool { get }
    var healthArgs: [String] { get }             // e.g. ["claude","--version"], run via /usr/bin/env

    /// The CLI's own cheap auth-status command (run via /usr/bin/env; exit 0 = logged in).
    /// `[]` = the CLI has no such command; the probe tier is then the only auth truth.
    var authStatusArgs: [String] { get }
    /// Substrings identifying a logged-out state in the CLI's output — how the probe tier tells
    /// `authNeeded` from `healthFailed`, and how the auth tier catches a status command that
    /// reports logged-out without a nonzero exit (recorded from the CLI, see the health tests).
    var authFailureMarkers: [String] { get }
    /// Copy-paste shell command that installs the CLI — the setup sheet's `missingCLI` remedy.
    var installCommand: String { get }
    /// What the setup sheet's Terminal launcher runs for interactive login — the `authNeeded`
    /// remedy (auth is interactive by design; the app never attempts it headless).
    var loginCommand: String { get }

    /// True if the host mints a session UUID up front and passes it on the CLI (claude); false if
    /// the id is parsed back out of the run's output (codex).
    var usesPreallocatedSessionID: Bool { get }

    /// Stage per-run files for a CLI that reads run configuration from files it discovers in the
    /// working directory rather than from argv. Runs before every `launch()` — in `run()` and in the
    /// probe tier — so a stale file from a previous run is rewritten or removed each turn. Throwing
    /// aborts the turn loudly: a run whose staged config failed to land would look alive while
    /// silently missing its tools. Default: nothing.
    func prepare(_ request: SZAgentRunRequest) throws

    /// Build the launch command for one turn. `preallocatedSessionID` is non-nil only when
    /// `usesPreallocatedSessionID` is true.
    func launch(_ request: SZAgentRunRequest, preallocatedSessionID: String?) -> SZLaunch

    /// Resolve session id + success from a finished run.
    func parse(output: String, exitCode: Int32, preallocatedSessionID: String?) -> SZAgentOutcome

    /// A fresh stream consumer for one chat turn — parses this provider's output into chat events
    /// (`.reply` / `.thinking` / `.toolCall` / `.usage`). Provider-specific parsing, common API.
    /// Default: a no-op consumer.
    func makeStreamConsumer() -> any SZAgentStreamConsumer

    /// Fetch the current model catalog from the CLI, for a provider whose served models are
    /// user-account-dependent (see SZProviderModelCatalog). Token-free by contract — the host may
    /// call it whenever the cheap health status transitions to ready. Returns nil (the default)
    /// for a static-manifest provider; throws when the CLI could not be asked. A fetch that
    /// succeeds also updates what `models`/`defaultModel` serve.
    func refreshModelCatalog(runner: any SZProcessRunning) async throws -> SZProviderModelCatalog?

    /// Seed `models`/`defaultModel` from a persisted snapshot (launch, before any fetch), so the
    /// picker serves last-known truth offline. No-op (the default) for static-manifest providers.
    func seedModelCatalog(_ catalog: SZProviderModelCatalog)
}

public extension SZProvider {
    var displayName: String { id }
    var usesPreallocatedSessionID: Bool { false }
    var authStatusArgs: [String] { [] }
    var authFailureMarkers: [String] { [] }
    var supportedReasoningEfforts: [String] { [] }   // conservative for future providers; both shipped ones override
    var supportsFastMode: Bool { false }
    func prepare(_ request: SZAgentRunRequest) throws {}
    func makeStreamConsumer() -> any SZAgentStreamConsumer { SZNullStreamConsumer() }
    func refreshModelCatalog(runner: any SZProcessRunning) async throws -> SZProviderModelCatalog? { nil }
    func seedModelCatalog(_ catalog: SZProviderModelCatalog) {}

    func model(id modelID: String) -> SZProviderModel? {
        models.first { $0.id == modelID }
    }

    // The three capability readers below share one rule: answer from the model when it overrides,
    // else from the provider. An unknown id falls back to the provider rather than failing — a stored
    // selection can name a model that a later app version dropped.

    /// The effort menu for one model, in menu order. `[]` = this CLI has no effort concept.
    func supportedReasoningEfforts(for modelID: String) -> [String] {
        model(id: modelID)?.supportedReasoningEfforts ?? supportedReasoningEfforts
    }

    /// The effort a model lands on when nothing valid is stored.
    func defaultReasoningEffort(for modelID: String) -> String {
        model(id: modelID)?.defaultReasoningEffort ?? defaultReasoningEffort
    }

    /// Whether fast mode can be turned on for one model at all — ask this, not `supportsFastMode`,
    /// before showing a toggle or emitting a flag. A CLI can accept the fast-mode argv for every
    /// model it serves and enable it for only some.
    ///
    /// This answers *can it be enabled*, never *was the turn served fast*. The latter is an account
    /// entitlement the CLI reports per turn, so no model list can know it — don't encode it here.
    func supportsFastMode(for modelID: String) -> Bool {
        model(id: modelID)?.supportsFastMode ?? supportsFastMode
    }

    /// Clamp a stored (possibly stale) selection down to what this provider can actually run,
    /// returning concrete values ready for an `SZAgentRunRequest`:
    ///
    /// - unknown model → `defaultModel`
    /// - effort off the selected model's menu → that model's default (or the menu's first token, if
    ///   even the default isn't on it); nil when the CLI has no effort concept
    /// - fastMode → off unless the selected model honours it
    ///
    /// Every capability is read against the SELECTED model, so the same stored setting can be legal
    /// under one model and clamped under another. Clamping never rewrites the stored row: a setting
    /// this model rejects survives, and takes effect again once a model that accepts it is picked.
    ///
    /// This is the ONE clamp point. Every consumer — runs, Director turns, chats, telemetry — reads
    /// its output, which is why `launch()` may trust `request.fastMode` without rechecking the model.
    func resolvedGenerationSettings(from stored: SZProviderGenerationSettings?) -> SZProviderGenerationSettings {
        let modelIDs = models.map(\.id)
        let model = stored?.model.flatMap { modelIDs.contains($0) ? $0 : nil } ?? defaultModel
        // An EMPTY model list (a runtime catalog before its first fetch) resolves no effort either:
        // the provider-level menu is a fallback for a stale id AMONG known models, not a claim
        // about a CLI-default model we know nothing about — argv must not carry an effort flag
        // for a model that was never enumerated.
        let efforts = models.isEmpty ? [] : supportedReasoningEfforts(for: model)
        var effort: String?
        if !efforts.isEmpty {
            let fallback = defaultReasoningEffort(for: model)
            effort = stored?.reasoningEffort.flatMap { efforts.contains($0) ? $0 : nil }
                ?? (efforts.contains(fallback) ? fallback : efforts.first)
        }
        let fast = supportsFastMode(for: model) && (stored?.fastMode ?? false)
        return SZProviderGenerationSettings(model: model, reasoningEffort: effort, fastMode: fast)
    }

    /// Spawn one agent turn: mint a UUID if the provider wants one (and we're not resuming), launch,
    /// then parse. On a resume turn the session id is carried by `request.resumeSessionID`, so we don't
    /// mint a new one; if the provider's parse can't recover an id (a resumed run may not re-announce
    /// it), we fall back to the resume id so the host's session mapping stays stable.
    func run(_ request: SZAgentRunRequest, runner: any SZProcessRunning = SZSystemProcessRunner()) async throws -> SZAgentRunResult {
        let preallocated = (request.resumeSessionID == nil && usesPreallocatedSessionID) ? UUID().uuidString : nil
        try prepare(request)
        let launch = launch(request, preallocatedSessionID: preallocated)
        let result = try await runner.run(
            launch.executable, launch.arguments,
            environment: launch.environment, currentDirectoryURL: request.workingDirectory,
            input: nil, timeout: request.timeout, inactivityTimeout: request.inactivityTimeout,
            onOutput: request.onOutput
        )
        var outcome = parse(output: result.output, exitCode: result.exitCode, preallocatedSessionID: preallocated)
        if outcome.sessionID == nil { outcome.sessionID = request.resumeSessionID }
        return SZAgentRunResult(process: result, outcome: outcome)
    }

}

extension String {
    var szFirstLine: String {
        String(split(whereSeparator: \.isNewline).first ?? "").trimmingCharacters(in: .whitespaces)
    }
}
