// SPDX-License-Identifier: AGPL-3.0-only
// The provider layer is per-provider Swift behind one protocol, and provider-agnostic.
// These tests prove the seam is not claude-shaped by exercising EVERY backend through the same
// protocol:
//  - the registry vends all providers;
//  - each provider's launch() builds the right argv for its distinct CLI grammar
//    (--mcp-config JSON + --session-id for claude; -c mcp_servers + trailing prompt for codex;
//    streaming-json + a prepare()-staged config file for grok);
//  - the session-id strategies resolve (claude/grok host-minted UUID; codex jsonl thread.started);
//  - all health checks pass on a machine with the CLIs installed (SZ_LIVE_PROVIDERS=1 only).
import Foundation
import Synchronization
import Testing
import SZCore
@testable import SZAI

/// Records the argv (and stdin payload) it was asked to run and returns canned output — no live CLI.
private final class StubRunner: SZProcessRunning {
    struct Call: Sendable { var launchPath: String; var arguments: [String]; var input: Data? }
    private let calls = Mutex<[Call]>([])   // Mutex.withLock is async-safe (NSLock.lock is not)
    let output: String
    let exitCode: Int32

    init(output: String = "", exitCode: Int32 = 0) {
        self.output = output
        self.exitCode = exitCode
    }

    var lastCall: Call? { calls.withLock { $0.last } }

    func run(
        _ launchPath: String, _ arguments: [String],
        environment: [String: String], currentDirectoryURL: URL?,
        input: Data?, timeout: TimeInterval?, inactivityTimeout: TimeInterval?, onOutput: (@Sendable (String) -> Void)?
    ) async throws -> SZProcessResult {
        calls.withLock { $0.append(Call(launchPath: launchPath, arguments: arguments, input: input)) }
        return SZProcessResult(exitCode: exitCode, output: output)
    }
}

private func request(
    port: UInt16?, allowedMCPTools: [String] = [],
    model: String? = nil, reasoningEffort: String? = nil, fastMode: Bool = false
) -> SZAgentRunRequest {
    let tmp = FileManager.default.temporaryDirectory
    return SZAgentRunRequest(
        prompt: "make it grayscale",
        workingDirectory: tmp.appending(path: "work"),
        packageDirectory: tmp.appending(path: "proj.subz"),
        cacheDirectory: tmp.appending(path: "cache"),
        mcpServerPort: port,
        allowedMCPTools: allowedMCPTools,
        model: model,
        reasoningEffort: reasoningEffort,
        fastMode: fastMode
    )
}

private extension Array where Element == String {
    func value(after flag: String) -> String? {
        guard let i = firstIndex(of: flag), i + 1 < count else { return nil }
        return self[i + 1]
    }
}

@Test func registryVendsAllProviders() {
    let reg = SZProviderRegistry.shared
    #expect(reg.providers.map(\.id).sorted() == ["claude", "codex", "grok", "pi"])
    #expect(reg.defaultProvider.id == "claude")
    #expect(reg.provider(id: "claude")?.defaultModel == "claude-opus-4-8")
    #expect(reg.provider(id: "codex")?.defaultModel == "gpt-5.6-terra")
    // grok's and pi's catalogs are runtime-enumerated (grok's backend re-points unversioned ids;
    // pi is BYOK — the user's pi decides): at rest they serve NOTHING, deliberately — no
    // hardcoded grok or pi model id exists anywhere in this codebase.
    #expect(reg.provider(id: "grok")?.models.isEmpty == true)
    #expect(reg.provider(id: "grok")?.defaultModel == "")
    #expect(reg.provider(id: "pi")?.models.isEmpty == true)
    #expect(reg.provider(id: "pi")?.defaultModel == "")
}

@Test func claudeLaunchBuildsArgvAndMintsSession() async throws {
    let claude = SZClaudeProvider()
    let stub = StubRunner()
    let result = try await claude.run(request(port: 42100), runner: stub)

    let call = try #require(stub.lastCall)
    #expect(call.launchPath == "/usr/bin/env")
    #expect(call.arguments.value(after: "--model") == "claude-opus-4-8")
    #expect(call.arguments.contains("--mcp-config"))
    #expect(call.arguments.joined().contains(#"["127.0.0.1","42100"]"#))
    // claude takes a host-minted UUID, echoed back as the session id.
    let sessionID = try #require(result.outcome.sessionID)
    #expect(call.arguments.value(after: "--session-id") == sessionID)
    #expect(UUID(uuidString: sessionID) != nil)
    #expect(result.outcome.failed == false)
}

@Test func claudeOmitsMCPWhenNoPort() {
    let launch = SZClaudeProvider().launch(request(port: nil), preallocatedSessionID: "x")
    #expect(!launch.arguments.contains("--mcp-config"))
}

@Test func codexLaunchUsesConfigFlagsAndParsesJsonlSession() async throws {
    let codex = SZCodexProvider()
    let stub = StubRunner(output: """
    {"type":"session.created"}
    {"type":"thread.started","thread_id":"T-abc-123"}
    {"type":"item.completed"}
    """)
    let result = try await codex.run(request(port: 42100), runner: stub)

    let call = try #require(stub.lastCall)
    #expect(call.arguments.prefix(3) == ["codex", "exec", "--json"])
    #expect(call.arguments.value(after: "-m") == "gpt-5.6-terra")
    #expect(call.arguments.contains(#"mcp_servers.subz.args=["127.0.0.1","42100"]"#))
    #expect(call.arguments.contains("mcp_servers.subz.required=true"))
    // exec has no per-tool allowlist; bypass is its only unattended-autonomy lever (else MCP calls cancel).
    #expect(call.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
    #expect(call.arguments.last == "make it grayscale")   // prompt is the trailing positional
    // codex's id is parsed from the jsonl stream, not minted.
    #expect(result.outcome.sessionID == "T-abc-123")
}

/// A chat turn continues an existing session. claude uses `--resume <id>` (not the
/// `--session-id` mint), and run() keeps the id stable so the host's session map stays addressable.
@Test func claudeResumeContinuesSessionInsteadOfMinting() async throws {
    let claude = SZClaudeProvider()
    var req = request(port: 42100)
    req.resumeSessionID = "S-existing"

    let argv = claude.launch(req, preallocatedSessionID: nil).arguments
    #expect(argv.value(after: "--resume") == "S-existing")
    #expect(!argv.contains("--session-id"))   // resume, not a fresh mint
    #expect(argv.value(after: "-p") == "make it grayscale")

    let result = try await claude.run(req, runner: StubRunner())
    #expect(result.outcome.sessionID == "S-existing")
}

/// codex continues a thread via `exec resume <id> … <prompt>` — no `--cd` (invalid on the
/// resume subcommand; the process cwd carries it), and run() falls back to the resume id when the
/// resumed stream doesn't re-announce a thread.started.
@Test func codexResumeUsesResumeSubcommand() async throws {
    let codex = SZCodexProvider()
    var req = request(port: 42100)
    req.resumeSessionID = "T-existing"

    let argv = codex.launch(req, preallocatedSessionID: nil).arguments
    #expect(argv.prefix(3) == ["codex", "exec", "resume"])
    #expect(!argv.contains("--cd"))                  // not valid on `exec resume`
    #expect(argv.contains("T-existing"))             // SESSION_ID positional
    #expect(argv.last == "make it grayscale")        // PROMPT trailing positional
    #expect(argv.contains("--dangerously-bypass-approvals-and-sandbox"))

    let result = try await codex.run(req, runner: StubRunner())   // empty output → no thread.started
    #expect(result.outcome.sessionID == "T-existing")
}

/// grok is claude-shaped on sessions (host-minted `--session-id`, echoed back) but attaches MCP
/// through a config FILE staged by `prepare()` — run() calls it before launch(), so after a run
/// with a port the file exists with the nc bridge, and a portless run removes the stale file
/// (a leftover entry would spend the CLI's 30s MCP startup timeout on a dead bridge).
@Test func grokLaunchBuildsArgvMintsSessionAndStagesMCPConfig() async throws {
    let grok = SZGrokProvider()
    let stub = StubRunner()
    let work = FileManager.default.temporaryDirectory.appending(path: "grok-mcp-\(UUID().uuidString)")
    var req = request(port: 42123)
    req.workingDirectory = work
    defer { try? FileManager.default.removeItem(at: work) }

    let result = try await grok.run(req, runner: stub)

    let call = try #require(stub.lastCall)
    #expect(call.launchPath == "/usr/bin/env")
    #expect(call.arguments.prefix(3) == ["grok", "-p", "make it grayscale"])
    // No catalog fetched yet → no `-m`: the CLI's own default carries the run (a pinned id is
    // exactly what broke when the backend re-pointed the served catalog — see the provider).
    #expect(!call.arguments.contains("-m"))
    #expect(call.arguments.value(after: "--output-format") == "streaming-json")
    #expect(call.arguments.contains("--always-approve"))
    // MCP rides the staged config file, never argv.
    #expect(!call.arguments.contains("--mcp-config"))
    let config = work.appending(path: ".grok/config.toml")
    let toml = try String(contentsOf: config, encoding: .utf8)
    #expect(toml.contains("[mcp_servers.subz]"))
    #expect(toml.contains(#"command = "/usr/bin/nc""#))
    #expect(toml.contains(#"args = ["127.0.0.1", "42123"]"#))
    // grok takes a host-minted UUID, echoed back as the session id (claude-style).
    let sessionID = try #require(result.outcome.sessionID)
    #expect(call.arguments.value(after: "--session-id") == sessionID)
    #expect(UUID(uuidString: sessionID) != nil)

    // A later run in the same staging dir WITHOUT a port removes the stale file.
    req.mcpServerPort = nil
    _ = try await grok.run(req, runner: stub)
    #expect(!FileManager.default.fileExists(atPath: config.path))
}

/// A grok chat turn continues with `--resume <id>` (not a fresh `--session-id` mint), and run()
/// keeps the id stable so the host's session map stays addressable.
@Test func grokResumeContinuesSessionInsteadOfMinting() async throws {
    let grok = SZGrokProvider()
    var req = request(port: nil)
    req.resumeSessionID = "S-existing"

    let argv = grok.launch(req, preallocatedSessionID: nil).arguments
    #expect(argv.value(after: "--resume") == "S-existing")
    #expect(!argv.contains("--session-id"))   // resume, not a fresh mint
    #expect(argv.value(after: "-p") == "make it grayscale")

    let result = try await grok.run(req, runner: StubRunner())
    #expect(result.outcome.sessionID == "S-existing")
}

/// grok 0.2.93 has no effort or fast-mode surface (measured — see the provider): the picker hides
/// both dimensions, the resolver clamps stored values away, and argv NEVER carries the flag — the
/// CLI would swallow it silently rather than reject it, so this is the only guard.
@Test func grokHasNoEffortOrFastSurface() {
    let grok = SZGrokProvider()
    grok.seedModelCatalog(SZProviderModelCatalog(
        models: [SZProviderModel(id: "grok-4.5", displayName: "Grok 4.5")],
        defaultModelID: "grok-4.5"))
    #expect(grok.supportedReasoningEfforts.isEmpty)
    #expect(!grok.supportsFastMode)
    for model in grok.models {
        #expect(grok.supportedReasoningEfforts(for: model.id).isEmpty)
        #expect(!grok.supportsFastMode(for: model.id))
    }

    // A stale stored id (the backend retired it) clamps to the catalog's default.
    let resolved = grok.resolvedGenerationSettings(
        from: SZProviderGenerationSettings(model: "grok-build", reasoningEffort: "high", fastMode: true))
    #expect(resolved == SZProviderGenerationSettings(model: "grok-4.5", reasoningEffort: nil, fastMode: false))

    // Even a request that (wrongly) carries an effort never puts the flag on argv.
    let argv = grok.launch(request(port: nil, reasoningEffort: "high"), preallocatedSessionID: "x").arguments
    #expect(!argv.contains("--reasoning-effort"))
    #expect(!argv.contains("--effort"))
}

// Recorded `grok models` outputs — the shapes the catalog parser must keep matching.
private let grokModelsSingle =   // grok 0.2.93, 2026-07-16: the backend re-pointed to one model
    "You are logged in with grok.com.\n\nDefault model: grok-4.5\n\nAvailable models:\n  * grok-4.5 (default)"
private let grokModelsPair =     // grok 0.2.93, 2026-07-12: the earlier two-model catalog
    "You are logged in with grok.com.\n\nDefault model: grok-composer-2.5-fast\n\n" +
    "Available models:\n  * grok-composer-2.5-fast (default)\n  - grok-build"
private let grokModelsLoggedOut =
    "You are not authenticated.\n\nDefault model: grok-4.5\n\nAvailable models:"

/// The catalog mapper against both recorded shapes: `*`/`-` bullets strip, "(default)" annotates,
/// the "Default model:" line wins, and display names derive from ids keeping the Grok brand
/// (these ids don't self-identify the way "Opus 4.8" does).
@Test func grokCatalogSnapshotMapsRecordedModelsOutput() throws {
    let single = try #require(SZGrokProvider.catalogSnapshot(fromModelsOutput: grokModelsSingle))
    #expect(single.models.map(\.id) == ["grok-4.5"])
    #expect(single.models.map(\.displayName) == ["Grok 4.5"])
    #expect(single.defaultModelID == "grok-4.5")

    let pair = try #require(SZGrokProvider.catalogSnapshot(fromModelsOutput: grokModelsPair))
    #expect(pair.models.map(\.id) == ["grok-composer-2.5-fast", "grok-build"])
    #expect(pair.models.map(\.displayName) == ["Grok Composer 2.5 Fast", "Grok Build"])
    #expect(pair.defaultModelID == "grok-composer-2.5-fast")

    // An empty list (the logged-out tail) is unparseable, not a zero-model catalog — grok's
    // served models are backend-global, so "no list" never means "no models".
    #expect(SZGrokProvider.catalogSnapshot(fromModelsOutput: grokModelsLoggedOut) == nil)
}

/// refreshModelCatalog is one token-free `grok models` spawn: the parsed snapshot becomes what
/// `models`/`defaultModel` serve, and a known model rides argv as `-m` again.
@Test func grokRefreshModelCatalogFetchesAndServes() async throws {
    let grok = SZGrokProvider()
    let stub = StubRunner(output: grokModelsSingle)
    let snapshot = try #require(try await grok.refreshModelCatalog(runner: stub))

    let call = try #require(stub.lastCall)
    #expect(call.arguments == ["grok", "models"])
    #expect(snapshot.models.map(\.id) == ["grok-4.5"])
    #expect(grok.models.map(\.id) == ["grok-4.5"])
    #expect(grok.defaultModel == "grok-4.5")

    let argv = grok.launch(request(port: nil), preallocatedSessionID: "x").arguments
    #expect(argv.value(after: "-m") == "grok-4.5")
}

/// A logged-out fetch throws (the host keeps the last-known catalog — grok's models are
/// backend-global, so yesterday's snapshot outranks a logged-out blank), and a seeded snapshot
/// restores service without a fetch (the offline relaunch story).
@Test func grokRefreshModelCatalogLoggedOutKeepsLastKnown() async throws {
    let grok = SZGrokProvider()
    grok.seedModelCatalog(SZProviderModelCatalog(
        models: [SZProviderModel(id: "grok-4.5", displayName: "Grok 4.5")],
        defaultModelID: "grok-4.5"))

    await #expect(throws: (any Error).self) {
        try await grok.refreshModelCatalog(runner: StubRunner(output: grokModelsLoggedOut))
    }
    #expect(grok.models.map(\.id) == ["grok-4.5"])   // seeded truth survives the failed fetch
    #expect(grok.defaultModel == "grok-4.5")
}

/// Generation-settings overrides ride through each provider's argv; fast mode expands to each
/// CLI's own flags only when requested. `launch` deliberately does NOT re-check the model — a
/// request arrives already clamped by `resolvedGenerationSettings`, the one clamp point — so this
/// names Opus 4.8 explicitly rather than leaning on it being today's default.
@Test func claudeFastModeTogglesSettingsBlob() {
    let claude = SZClaudeProvider()
    let fast = claude.launch(
        request(port: nil, model: "claude-opus-4-8", fastMode: true), preallocatedSessionID: nil).arguments
    #expect(fast.value(after: "--settings") == #"{"fastMode":true}"#)
    let normal = claude.launch(request(port: nil), preallocatedSessionID: nil).arguments
    #expect(!normal.contains("--settings"))
}

@Test func claudeEffortReachesArgv() {
    let claude = SZClaudeProvider()
    let argv = claude.launch(request(port: nil, reasoningEffort: "max"), preallocatedSessionID: nil).arguments
    #expect(argv.value(after: "--effort") == "max")
    // No override → the declared default rides (mirrors --model).
    let defaulted = claude.launch(request(port: nil), preallocatedSessionID: nil).arguments
    #expect(defaulted.value(after: "--effort") == "high")
}

@Test func codexFastModeAndOverridesReachArgv() {
    let codex = SZCodexProvider()
    let argv = codex.launch(
        request(port: nil, model: "gpt-5.6-terra", reasoningEffort: "max", fastMode: true),
        preallocatedSessionID: nil).arguments
    #expect(argv.value(after: "-m") == "gpt-5.6-terra")
    #expect(argv.contains(#"model_reasoning_effort="max""#))
    #expect(argv.contains(#"service_tier="fast""#))
    #expect(argv.contains("features.fast_mode=true"))

    let normal = codex.launch(request(port: nil), preallocatedSessionID: nil).arguments
    #expect(!normal.contains(#"service_tier="fast""#))
    #expect(!normal.contains("features.fast_mode=true"))
}

@Test func codexFastModeSurvivesResume() {
    var req = request(port: nil, fastMode: true)
    req.resumeSessionID = "T-existing"
    let argv = SZCodexProvider().launch(req, preallocatedSessionID: nil).arguments
    #expect(argv.prefix(3) == ["codex", "exec", "resume"])
    #expect(argv.contains(#"service_tier="fast""#))
}

/// The resolver clamps a stored (possibly stale) selection to the provider's real capabilities.
@Test func resolverClampsStaleSelections() {
    let codex = SZCodexProvider()
    // "bogus" is the unknown-effort probe, NOT "ultra": ultra is real on the default model (Terra),
    // so it would survive the clamp and quietly invert this assertion.
    let stale = codex.resolvedGenerationSettings(
        from: SZProviderGenerationSettings(model: "gpt-9-imaginary", reasoningEffort: "bogus", fastMode: true))
    #expect(stale.model == "gpt-5.6-terra")      // unknown model → default
    #expect(stale.reasoningEffort == "medium")   // unknown effort → default
    #expect(stale.fastMode == true)              // codex supports fast

    let kept = codex.resolvedGenerationSettings(
        from: SZProviderGenerationSettings(model: "gpt-5.4", reasoningEffort: "xhigh", fastMode: false))
    #expect(kept == SZProviderGenerationSettings(model: "gpt-5.4", reasoningEffort: "xhigh", fastMode: false))

    // `max` arrived with GPT-5.6: kept on luna, clamped on the 5.4 that never advertised it.
    let lunaMax = codex.resolvedGenerationSettings(
        from: SZProviderGenerationSettings(model: "gpt-5.6-luna", reasoningEffort: "max", fastMode: false))
    #expect(lunaMax == SZProviderGenerationSettings(model: "gpt-5.6-luna", reasoningEffort: "max", fastMode: false))

    let oldModelMax = codex.resolvedGenerationSettings(
        from: SZProviderGenerationSettings(model: "gpt-5.4", reasoningEffort: "max", fastMode: false))
    #expect(oldModelMax == SZProviderGenerationSettings(model: "gpt-5.4", reasoningEffort: "medium", fastMode: false))

    // `ultra` is Terra's alone — the one token that proves the list is per-model, not per-provider:
    // the SAME stored effort survives on Terra and clamps to the default on Luna.
    let terraUltra = codex.resolvedGenerationSettings(
        from: SZProviderGenerationSettings(model: "gpt-5.6-terra", reasoningEffort: "ultra", fastMode: false))
    #expect(terraUltra.reasoningEffort == "ultra")

    let lunaUltra = codex.resolvedGenerationSettings(
        from: SZProviderGenerationSettings(model: "gpt-5.6-luna", reasoningEffort: "ultra", fastMode: false))
    #expect(lunaUltra.reasoningEffort == "medium")

    let claude = SZClaudeProvider()
    let resolved = claude.resolvedGenerationSettings(
        from: SZProviderGenerationSettings(reasoningEffort: "max", fastMode: true))
    #expect(resolved.reasoningEffort == "max")
    // Survives only because the model this falls back to — the default, Opus 4.8 — honours fast mode.
    // Were the default ever a model that doesn't, this would clamp to false; see claudeFastModeIsOpusOnly.
    #expect(resolved.model == "claude-opus-4-8")
    #expect(resolved.fastMode == true)

    // nil stored = provider defaults across the board.
    let defaults = codex.resolvedGenerationSettings(from: nil)
    #expect(defaults == SZProviderGenerationSettings(model: "gpt-5.6-terra", reasoningEffort: "medium", fastMode: false))
}

/// claude's three models are live-verified against claude 2.1.206 and listed in the CLI's own
/// frontier-first alias order. Their EFFORT surface is uniform — no model overrides it — which is
/// the half that stays true even as fast mode diverges (see `claudeFastModeIsOpusOnly`). An added
/// model that does diverge on effort has to say so with an override, not inherit a list the CLI
/// never advertised for it.
@Test func claudeModelEffortSurfaceIsUniformAndDefaultsToOpus() {
    let claude = SZClaudeProvider()

    #expect(claude.models.map(\.id) == ["claude-fable-5", "claude-opus-4-8", "claude-sonnet-5"])
    #expect(claude.defaultModel == "claude-opus-4-8")
    // Fable is the frontier model and heads the menu, but the default is deliberately NOT it.
    #expect(claude.models.first?.id != claude.defaultModel)

    // No model overrides EFFORT: every one resolves to the provider's list and `high`.
    for model in claude.models {
        #expect(model.supportedReasoningEfforts == nil)
        #expect(model.defaultReasoningEffort == nil)
        #expect(claude.supportedReasoningEfforts(for: model.id) == ["low", "medium", "high", "xhigh", "max"])
        #expect(claude.defaultReasoningEffort(for: model.id) == "high")
    }

    // nil stored = Opus 4.8 at high, fast off. The end-to-end statement of "4.8 is the default".
    #expect(claude.resolvedGenerationSettings(from: nil)
        == SZProviderGenerationSettings(model: "claude-opus-4-8", reasoningEffort: "high", fastMode: false))

    // A selection stored before Fable shipped still resolves to a model that exists.
    let stale = claude.resolvedGenerationSettings(
        from: SZProviderGenerationSettings(model: "claude-opus-4-7", reasoningEffort: "max", fastMode: false))
    #expect(stale.model == "claude-opus-4-8")
    #expect(stale.reasoningEffort == "max")
}

/// Fast mode is per MODEL, not per provider. claude 2.1.206 accepts `--settings {"fastMode":true}`
/// for all three — it swallows unknown settings keys silently — but its own `result.fast_mode_state`
/// reads `on` only for Opus 4.8, and `off` for Fable 5 and Sonnet 5. Recorded from live runs; the two
/// the CLI won't enable it for declare it, so the composer stops offering an inert toggle. (Sonnet 5
/// was the default model until Opus 4.8 took over, so this shipped inert by default.)
///
/// What's asserted here is "can the CLI enable it", not "was the turn served fast" — the latter is an
/// account entitlement reported per turn as `usage.speed`, and is deliberately not modeled.
@Test func claudeFastModeIsOpusOnly() {
    let claude = SZClaudeProvider()

    // The CLI has the flag, so the provider-level fallback stays true…
    #expect(claude.supportsFastMode)
    // …and the two models that ignore it say so, rather than inheriting a capability they lack.
    #expect(claude.model(id: "claude-opus-4-8")?.supportsFastMode == nil)   // inherits
    #expect(claude.model(id: "claude-fable-5")?.supportsFastMode == false)
    #expect(claude.model(id: "claude-sonnet-5")?.supportsFastMode == false)

    #expect(claude.supportsFastMode(for: "claude-opus-4-8"))
    #expect(!claude.supportsFastMode(for: "claude-fable-5"))
    #expect(!claude.supportsFastMode(for: "claude-sonnet-5"))
    // A stale stored id falls back to the provider rather than an empty answer.
    #expect(claude.supportsFastMode(for: "claude-opus-4-7") == claude.supportsFastMode)

    // The resolver is the clamp: fast survives on opus, and is forced off on the other two.
    func resolvedFast(_ model: String) -> Bool? {
        claude.resolvedGenerationSettings(
            from: SZProviderGenerationSettings(model: model, reasoningEffort: nil, fastMode: true)).fastMode
    }
    #expect(resolvedFast("claude-opus-4-8") == true)
    #expect(resolvedFast("claude-fable-5") == false)
    #expect(resolvedFast("claude-sonnet-5") == false)
}

/// The stored fastMode bit is STICKY across a trip through a model that ignores it — clamped off at
/// read, never erased. Same contract as a stored `ultra` effort surviving a detour through luna, and
/// the reason switching model doesn't need to rewrite the stored row.
@Test func claudeFastModeStoredBitSurvivesAModelThatIgnoresIt() {
    let claude = SZClaudeProvider()
    let stored = SZProviderGenerationSettings(model: "claude-fable-5", reasoningEffort: nil, fastMode: true)

    #expect(claude.resolvedGenerationSettings(from: stored).fastMode == false)   // clamped under fable
    #expect(stored.fastMode == true)                                             // but not erased

    var backToOpus = stored
    backToOpus.model = "claude-opus-4-8"
    #expect(claude.resolvedGenerationSettings(from: backToOpus).fastMode == true)   // returns intact
}

/// codex's fast mode is untouched by the per-model refactor: no codex model overrides it, so every
/// one inherits the provider's `true` and argv keeps carrying `service_tier="fast"`. Its per-model
/// surface is UNMEASURED — that is precisely why nothing here claims otherwise. Encode a value only
/// when a live run reports one, as claude's did.
@Test func codexFastModeIsUnchangedAcrossEveryModel() {
    let codex = SZCodexProvider()
    #expect(codex.supportsFastMode)
    for model in codex.models {
        #expect(model.supportsFastMode == nil)                 // no override → no invented fact
        #expect(codex.supportsFastMode(for: model.id))         // …so all five still inherit true
        let resolved = codex.resolvedGenerationSettings(
            from: SZProviderGenerationSettings(model: model.id, reasoningEffort: nil, fastMode: true))
        #expect(resolved.fastMode == true)
    }
}

/// Both effort dimensions are per MODEL, and every token here is live-verified against codex-cli
/// 0.144.1 — a slug the ChatGPT backend won't serve dies with a 400 no in-process test can catch.
@Test func codexReasoningEffortsVaryByModel() {
    let codex = SZCodexProvider()
    #expect(codex.supportedReasoningEfforts(for: "gpt-5.6-sol") == ["low", "medium", "high", "xhigh", "max", "ultra"])
    #expect(codex.supportedReasoningEfforts(for: "gpt-5.6-terra") == ["low", "medium", "high", "xhigh", "max", "ultra"])
    #expect(codex.supportedReasoningEfforts(for: "gpt-5.6-luna") == ["low", "medium", "high", "xhigh", "max"])
    // No override → the provider list, verbatim.
    #expect(codex.supportedReasoningEfforts(for: "gpt-5.5") == codex.supportedReasoningEfforts)
    #expect(codex.supportedReasoningEfforts(for: "gpt-5.4") == codex.supportedReasoningEfforts)
    // A stale stored id resolves to the provider list instead of an empty menu.
    #expect(codex.supportedReasoningEfforts(for: "gpt-9-imaginary") == codex.supportedReasoningEfforts)

    // Sol is the only model that doesn't inherit the provider's `medium` — the whole reason
    // `SZProviderModel.defaultReasoningEffort` exists rather than being read off the provider.
    #expect(codex.defaultReasoningEffort(for: "gpt-5.6-sol") == "low")
    #expect(codex.defaultReasoningEffort(for: "gpt-5.6-terra") == "medium")
    #expect(codex.defaultReasoningEffort(for: "gpt-9-imaginary") == codex.defaultReasoningEffort)

    // Each model's own default is on its own menu, so the resolver's `efforts.first` tail never fires.
    #expect(codex.models.allSatisfy {
        codex.supportedReasoningEfforts(for: $0.id).contains(codex.defaultReasoningEffort(for: $0.id))
    })
    // `none` is accepted by the backend but advertised for no model, so it stays off every menu.
    #expect(codex.models.allSatisfy { !codex.supportedReasoningEfforts(for: $0.id).contains("none") })
}

/// Sol resolves to its OWN `low` default, not the provider's `medium` — a stale/absent stored effort
/// must not silently upgrade the model the vendor ships at low.
@Test func codexSolDefaultsToItsOwnLowEffort() {
    let codex = SZCodexProvider()
    let fresh = codex.resolvedGenerationSettings(
        from: SZProviderGenerationSettings(model: "gpt-5.6-sol", reasoningEffort: nil, fastMode: false))
    #expect(fresh.reasoningEffort == "low")

    let stale = codex.resolvedGenerationSettings(
        from: SZProviderGenerationSettings(model: "gpt-5.6-sol", reasoningEffort: "bogus", fastMode: false))
    #expect(stale.reasoningEffort == "low")

    // An explicit, supported pick still wins over the model's default.
    let picked = codex.resolvedGenerationSettings(
        from: SZProviderGenerationSettings(model: "gpt-5.6-sol", reasoningEffort: "ultra", fastMode: false))
    #expect(picked.reasoningEffort == "ultra")
}

/// fastMode stored true against a provider that doesn't support it resolves off — the argv can
/// never carry a flag the CLI lacks.
@Test func resolverClampsFastModeToCapability() {
    struct NoFastProvider: SZProvider {
        let id = "nofast"
        let models = [SZProviderModel(id: "m1", displayName: "M1")]
        let defaultModel = "m1"
        let defaultReasoningEffort = ""
        let healthArgs = ["nofast", "--version"]
        let installCommand = "echo install"
        let loginCommand = "echo login"
        func launch(_ request: SZAgentRunRequest, preallocatedSessionID: String?) -> SZLaunch {
            SZLaunch(executable: "/usr/bin/env", arguments: ["nofast"])
        }
        func parse(output: String, exitCode: Int32, preallocatedSessionID: String?) -> SZAgentOutcome {
            SZAgentOutcome(sessionID: nil, failed: exitCode != 0)
        }
    }
    let resolved = NoFastProvider().resolvedGenerationSettings(
        from: SZProviderGenerationSettings(fastMode: true))
    #expect(resolved.fastMode == false)
    #expect(resolved.reasoningEffort == nil)
}

/// Stateful stream consumers (provider-specific parsing, common API). The final answer is held and
/// emitted as `.reply` only at the end (never echoed into the trace); narration → `.thinking`,
/// tools → `.toolCall`, and the turn's reported tokens → `.usage`.
@Test func claudeStreamConsumerClassifiesReplyAndTrace() {
    let c = SZClaudeProvider().makeStreamConsumer()
    // narration text is held (reply candidate) — no event yet
    #expect(c.consume(#"{"type":"assistant","message":{"content":[{"type":"text","text":"working on it"}]}}"#).isEmpty)
    // a tool call flushes the prior narration → thinking, then the tool itself (real name)
    #expect(c.consume(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__subz__agent_compile_node"}]}}"#)
            == [.thinking("working on it"), .toolCall(name: "agent_compile_node")])
    // the result event is the final answer → reply (not echoed into the trace)
    #expect(c.consume(#"{"type":"result","result":"all done"}"#) == [.reply("all done")])
}

/// The result event's usage becomes one `.usage` — shape recorded verbatim from a live 2.1.207 run.
/// Anthropic reports cache traffic SEPARATELY from `input_tokens` (2 fresh + 14925 read + 6580
/// written here), so the total prompt side is the sum — reporting the bare `input_tokens` would
/// claim a 21.5k-token turn cost 2 — and the cached share (read + creation) is preserved beside it.
@Test func claudeStreamConsumerReportsUsage() {
    let c = SZClaudeProvider().makeStreamConsumer()
    #expect(c.consume(#"{"type":"result","result":"10","total_cost_usd":0.16683,"usage":{"input_tokens":2,"cache_creation_input_tokens":6580,"cache_read_input_tokens":14925,"output_tokens":393,"speed":"standard"}}"#)
            == [.usage(SZTokenUsage(inputTokens: 21507, outputTokens: 393, cachedInputTokens: 21505, costUSD: 0.16683)), .reply("10")])
}

/// A NON-empty thinking block must surface as `.thinking` without clobbering the held reply
/// candidate. Synthetic fixture: the CLI has only ever shipped empty blocks headless (see the
/// redaction note on the consumer), so this pins the surfacing branch for the day it starts.
@Test func claudeStreamConsumerSurfacesNonEmptyThinkingBlocks() {
    let c = SZClaudeProvider().makeStreamConsumer()
    #expect(c.consume(#"{"type":"assistant","message":{"content":[{"type":"text","text":"working on it"}]}}"#).isEmpty)
    #expect(c.consume(#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"weighing X vs Y","signature":"CAIS"}]}}"#)
            == [.thinking("weighing X vs Y")])
    #expect(c.finish() == [.reply("working on it")])
}

/// `thinking` blocks stream with EMPTY text in headless mode — recorded verbatim from live
/// `claude -p` runs (2.1.207: Fable 5 and Opus 4.8 both, aggregate events and
/// `--include-partial-messages` thinking_deltas alike; only the signature ships). An empty block
/// must stay invisible: no event, and no clobbering of the held reply candidate. A NON-empty block
/// would surface as `.thinking` — none has been observed yet.
@Test func claudeStreamConsumerIgnoresFableThinkingBlocks() {
    let c = SZClaudeProvider().makeStreamConsumer()
    #expect(c.consume(#"{"type":"assistant","message":{"content":[{"type":"text","text":"working on it"}]}}"#).isEmpty)
    // the thinking block passes through without emitting, and without dropping "working on it"
    #expect(c.consume(#"{"type":"assistant","message":{"model":"claude-fable-5","content":[{"type":"thinking","thinking":"","signature":"CAISkQIKiAEIDxgC"}]}}"#).isEmpty)
    // …so the held narration is still the reply candidate the stream ends on
    #expect(c.finish() == [.reply("working on it")])
}

/// A fast-mode turn can be downgraded — by the account's entitlement, or by fast mode's own rate
/// limit — so the trace says so once. The `result` event carries both halves and BOTH are needed:
/// `fast_mode_state` says the CLI turned fast mode on, `usage.speed` says what the API served.
/// Reading `usage.speed` alone would fire on every turn, because it reads "standard" whether or not
/// fast mode was ever requested (recorded live, on Sonnet 5 with no fast mode at all).
@Test func claudeStreamConsumerReportsADowngradedFastTurn() {
    // Enabled, served standard — the downgrade a user must be told about.
    let downgraded = SZClaudeProvider().makeStreamConsumer()
    #expect(downgraded.consume(#"{"type":"result","result":"done","fast_mode_state":"on","usage":{"speed":"standard"}}"#)
            == [.thinking("fast mode requested — served standard"), .reply("done")])

    // Enabled and served fast: nothing to report.
    let served = SZClaudeProvider().makeStreamConsumer()
    #expect(served.consume(#"{"type":"result","result":"done","fast_mode_state":"on","usage":{"speed":"fast"}}"#)
            == [.reply("done")])

    // Never asked, yet `speed` is still "standard" — the ordinary turn. The trace must stay clean,
    // or every single claude turn grows a spurious fast-mode line.
    let ordinary = SZClaudeProvider().makeStreamConsumer()
    #expect(ordinary.consume(#"{"type":"result","result":"done","fast_mode_state":"off","usage":{"speed":"standard"}}"#)
            == [.reply("done")])

    // Older/leaner result events carry neither key (usage with tokens still reports).
    let plain = SZClaudeProvider().makeStreamConsumer()
    #expect(plain.consume(#"{"type":"result","result":"done","usage":{"output_tokens":4}}"#)
            == [.usage(SZTokenUsage(inputTokens: 0, outputTokens: 4)), .reply("done")])
}

@Test func codexStreamConsumerClassifiesReplyAndTrace() {
    let c = SZCodexProvider().makeStreamConsumer()
    // a preamble agent_message is held; a tool call streams as a toolCall (real tool name)
    #expect(c.consume(#"{"type":"item.completed","item":{"type":"agent_message","text":"I'll do X"}}"#).isEmpty)
    #expect(c.consume(#"{"type":"item.completed","item":{"type":"mcp_tool_call","server":"subz","tool":"agent_compile_node"}}"#)
            == [.toolCall(name: "agent_compile_node")])
    // a reasoning summary is codex's actual thinking
    #expect(c.consume(#"{"type":"item.completed","item":{"type":"reasoning","text":"Considering X vs Y"}}"#)
            == [.thinking("Considering X vs Y")])
    // a second agent_message supersedes the preamble → preamble becomes narration
    #expect(c.consume(#"{"type":"item.completed","item":{"type":"agent_message","text":"done"}}"#) == [.thinking("I'll do X")])
    // finish flushes the final message as the reply
    #expect(c.finish() == [.reply("done")])
}

/// The final `turn.completed` event carries the turn's usage — shape recorded verbatim from a live
/// 0.144.1 run. `cached_input_tokens` is a SUBSET of `input_tokens` (OpenAI's convention, opposite
/// of Anthropic's), so input passes through unsummed; `reasoning_output_tokens` is reported even
/// when the turn emitted no `reasoning` summary item (this run: 46 reasoning tokens, zero items).
@Test func codexStreamConsumerReportsUsageFromTurnCompleted() {
    let c = SZCodexProvider().makeStreamConsumer()
    #expect(c.consume(#"{"type":"turn.completed","usage":{"input_tokens":13305,"cached_input_tokens":10496,"output_tokens":53,"reasoning_output_tokens":46}}"#)
            == [.usage(SZTokenUsage(inputTokens: 13305, outputTokens: 53, cachedInputTokens: 10496, reasoningOutputTokens: 46))])
    // A turn.completed with no usable usage stays silent instead of fabricating zeros.
    #expect(c.consume(#"{"type":"turn.completed"}"#).isEmpty)
    #expect(c.consume(#"{"type":"turn.completed","usage":{"input_tokens":5}}"#).isEmpty)
}

/// grok streams token-level chunks (recorded from grok 0.2.93 streaming-json), so the consumer
/// accumulates: thought chunks flush as ONE `.thinking` when text starts (per-token events would
/// spam the trace), text accumulates as the reply candidate, and a NEW thought block after text
/// demotes that text to narration — same reply/trace split as claude/codex.
@Test func grokStreamConsumerBatchesThoughtChunksAndAccumulatesReply() {
    let c = SZGrokProvider().makeStreamConsumer()
    #expect(c.consume(#"{"type":"thought","data":"The"}"#).isEmpty)
    #expect(c.consume(#"{"type":"thought","data":" user wants OK"}"#).isEmpty)
    // thought → text transition flushes the batched thought as one thinking event
    #expect(c.consume(#"{"type":"text","data":"hello"}"#) == [.thinking("The user wants OK")])
    #expect(c.consume(#"{"type":"text","data":" from grok"}"#).isEmpty)
    // the end event is metadata, not a flush point (finish() is)
    #expect(c.consume(#"{"type":"end","stopReason":"EndTurn","sessionId":"abc"}"#).isEmpty)
    #expect(c.finish() == [.reply("hello from grok")])
    #expect(c.finish().isEmpty)   // flushed exactly once
}

@Test func grokStreamConsumerDemotesSupersededTextToNarration() {
    let c = SZGrokProvider().makeStreamConsumer()
    #expect(c.consume(#"{"type":"text","data":"I'll check the file"}"#).isEmpty)
    // a new reasoning block after text → that text was narration, not the answer
    #expect(c.consume(#"{"type":"thought","data":"Now the real answer"}"#) == [.thinking("I'll check the file")])
    #expect(c.consume(#"{"type":"text","data":"42"}"#) == [.thinking("Now the real answer")])
    #expect(c.finish() == [.reply("42")])
}

/// grok emits RAW control characters inside JSON string values (verified 0.2.93 — strict parsers
/// throw). The consumer sanitizes per line, so the chunk survives instead of being dropped.
@Test func grokStreamConsumerSurvivesRawControlCharacters() {
    let c = SZGrokProvider().makeStreamConsumer()
    let rawTab = "{\"type\":\"thought\",\"data\":\"col1\tcol2\"}"   // literal 0x09 inside the value
    #expect(c.consume(rawTab).isEmpty)
    #expect(c.finish() == [.thinking("col1\tcol2")])

    // An error event surfaces in the trace (the run's failure still rides the exit code).
    let e = SZGrokProvider().makeStreamConsumer()
    #expect(e.consume(#"{"type":"error","message":"Couldn't start session"}"#)
            == [.thinking("⚠ Couldn't start session")])
}

// MARK: - pi (dynamic catalog + staged MCP bridge extension; fixtures recorded from pi 0.80.6)

/// A successful pi turn, trimmed from a recorded `pi -p --mode json` run: header first, the final
/// assistant message ends with stopReason "stop". `--mode json` exits 0 even on FAILED turns, so
/// these stopReason fixtures are what parse() classifies by.
private let piTurnOK = """
{"type":"session","version":3,"id":"019f5800-e9d9-7890-8449-bcff50ac032b","timestamp":"2026-07-12T20:24:42.713Z","cwd":"/tmp/work"}
{"type":"agent_start"}
{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"OK"}],"stopReason":"stop"}}
{"type":"agent_end","messages":[],"willRetry":false}
"""

/// Recorded: a bogus model id — pi warns on stderr, sends it anyway, the backend rejects it, and
/// the process still exits 0. The empty-content assistant message with stopReason "error" is the
/// only failure signal.
private let piTurnBackendError = """
{"type":"session","version":3,"id":"019f580d-b26b-7b6d-9a64-b63453215fa5","timestamp":"2026-07-12T20:38:40.491Z","cwd":"/tmp/work"}
{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"Codex error: The 'bogus-model-xyz' model is not supported when using Codex with a ChatGPT account."}}
{"type":"agent_end","messages":[],"willRetry":false}
"""

/// Recorded RPC catalog fetch (`--mode rpc` → get_state + get_available_models), trimmed to three
/// models. gpt-5.5's map advertises xhigh but no max; luna reaches max; ids arrive bare and are
/// qualified `provider/id` at mapping time. get_state carries the user's own configured default.
private let piRPCCatalog = """
{"id":"1","type":"response","command":"get_state","success":true,"data":{"model":{"id":"gpt-5.5","name":"GPT-5.5","api":"openai-codex-responses","provider":"openai-codex","reasoning":true,"thinkingLevelMap":{"xhigh":"xhigh","minimal":"low"},"input":["text","image"],"contextWindow":272000,"maxTokens":128000},"thinkingLevel":"medium","sessionId":"019f57b9-c419-7024-ad3b-2ff01ebc4dd2"}}
{"id":"2","type":"response","command":"get_available_models","success":true,"data":{"models":[{"id":"gpt-5.4-mini","name":"GPT-5.4 mini","api":"openai-codex-responses","provider":"openai-codex","reasoning":true,"thinkingLevelMap":{"xhigh":"xhigh","minimal":"low"},"input":["text","image"],"contextWindow":272000,"maxTokens":128000},{"id":"gpt-5.5","name":"GPT-5.5","api":"openai-codex-responses","provider":"openai-codex","reasoning":true,"thinkingLevelMap":{"xhigh":"xhigh","minimal":"low"},"input":["text","image"],"contextWindow":272000,"maxTokens":128000},{"id":"gpt-5.6-luna","name":"GPT-5.6 Luna","api":"openai-codex-responses","provider":"openai-codex","reasoning":true,"thinkingLevelMap":{"xhigh":"xhigh","max":"max","minimal":"low"},"input":["text","image"],"contextWindow":372000,"maxTokens":128000}]}}
"""

/// Recorded logged-out RPC: get_state degrades to a sentinel "unknown" model (ignored) and the
/// catalog is a clean empty array — the truthful zero-models state, not an error.
private let piRPCCatalogLoggedOut = """
{"id":"1","type":"response","command":"get_state","success":true,"data":{"model":{"id":"unknown","name":"unknown","api":"unknown","provider":"unknown","reasoning":false,"input":[],"contextWindow":0,"maxTokens":0},"thinkingLevel":"off"}}
{"id":"2","type":"response","command":"get_available_models","success":true,"data":{"models":[]}}
"""

/// pi mints claude/grok-style (`--session-id`, host UUID), stages the MCP bridge EXTENSION into
/// the working directory when the turn carries a port (pi has no built-in MCP — the bridge speaks
/// the host's TCP protocol from inside pi), and removes the stale file on a portless turn.
@Test func piLaunchBuildsArgvMintsSessionAndStagesBridge() async throws {
    let pi = SZPiProvider()
    let stub = StubRunner(output: piTurnOK)
    let work = FileManager.default.temporaryDirectory.appending(path: "pi-mcp-\(UUID().uuidString)")
    var req = request(port: 42123)
    req.workingDirectory = work
    defer { try? FileManager.default.removeItem(at: work) }

    let result = try await pi.run(req, runner: stub)

    let call = try #require(stub.lastCall)
    #expect(call.launchPath == "/usr/bin/env")
    #expect(call.arguments.prefix(5) == ["pi", "-p", "--mode", "json", "--offline"])
    #expect(call.arguments.last == "make it grayscale")   // prompt is the trailing positional
    // Empty catalog → NO --model (pi's own default serves); the pre-flights gate real turns.
    #expect(!call.arguments.contains("--model"))
    // The bridge rides an explicit --extension path and the staged file carries the turn's port.
    let bridge = work.appending(path: ".subz/mcp-bridge.mjs")
    #expect(call.arguments.value(after: "--extension") == bridge.path)
    let source = try String(contentsOf: bridge, encoding: .utf8)
    #expect(source.contains("const PORT = 42123"))
    #expect(source.contains("net.connect"))
    #expect(!source.contains("__SUBZ_MCP_PORT__"))   // template token fully substituted
    // pi takes a host-minted UUID, echoed back as the session id (claude-style).
    let sessionID = try #require(result.outcome.sessionID)
    #expect(call.arguments.value(after: "--session-id") == sessionID)
    #expect(UUID(uuidString: sessionID) != nil)
    #expect(result.outcome.failed == false)

    // A later run in the same staging dir WITHOUT a port removes the stale bridge.
    req.mcpServerPort = nil
    _ = try await pi.run(req, runner: stub)
    #expect(!FileManager.default.fileExists(atPath: bridge.path))
}

/// pi has ONE session flag: `--session-id` creates AND resumes ("creating it if missing"), so a
/// resume turn reuses it — there is no `--resume` grammar to diverge into. The resumed run's
/// header echoes the passed id (verified live), which is what keeps the host's session map stable.
@Test func piResumeReusesSessionIdFlag() async throws {
    let pi = SZPiProvider()
    var req = request(port: nil)
    req.resumeSessionID = "S-existing"

    let argv = pi.launch(req, preallocatedSessionID: nil).arguments
    #expect(argv.value(after: "--session-id") == "S-existing")
    #expect(!argv.contains("--resume"))

    let resumedTurn = piTurnOK.replacingOccurrences(
        of: "019f5800-e9d9-7890-8449-bcff50ac032b", with: "S-existing")   // the header echo
    let result = try await pi.run(req, runner: StubRunner(output: resumedTurn))
    #expect(result.outcome.sessionID == "S-existing")

    // Even a stream with NO header (killed early) keeps the id: run() falls back to the resume id.
    let headerless = try await pi.run(req, runner: StubRunner(output: "", exitCode: 1))
    #expect(headerless.outcome.sessionID == "S-existing")
}

/// The failure signal lives in the stream, not the exit code: `--mode json` exits 0 on a failed
/// turn (recorded — print-mode maps errors to exit 1 only in text mode). stopReason "error", a
/// missing assistant message, and a nonzero exit each fail; the header id is the parse fallback
/// when no id was minted (a resume turn).
@Test func piParseReadsStopReasonNotExitCode() {
    let pi = SZPiProvider()
    #expect(pi.parse(output: piTurnBackendError, exitCode: 0, preallocatedSessionID: nil).failed)
    #expect(pi.parse(output: "", exitCode: 0, preallocatedSessionID: nil).failed)       // died pre-reply
    #expect(pi.parse(output: piTurnOK, exitCode: 1, preallocatedSessionID: nil).failed) // exit still counts
    let ok = pi.parse(output: piTurnOK, exitCode: 0, preallocatedSessionID: nil)
    #expect(!ok.failed)
    #expect(ok.sessionID == "019f5800-e9d9-7890-8449-bcff50ac032b")   // header id (belt-and-braces)
    // A minted id outranks the header echo.
    #expect(pi.parse(output: piTurnOK, exitCode: 0, preallocatedSessionID: "minted").sessionID == "minted")
}

/// Effort → `--thinking`; model + effort overrides ride through argv. An empty effort (a CLI with
/// no concept never sends one, and pi's own default covers a nil) omits the flag.
@Test func piEffortAndModelReachArgv() {
    let pi = SZPiProvider()
    let argv = pi.launch(
        request(port: nil, model: "openai-codex/gpt-5.5", reasoningEffort: "xhigh"),
        preallocatedSessionID: "x").arguments
    #expect(argv.value(after: "--model") == "openai-codex/gpt-5.5")
    #expect(argv.value(after: "--thinking") == "xhigh")

    let defaulted = pi.launch(request(port: nil), preallocatedSessionID: "x").arguments
    #expect(!defaulted.contains("--thinking"))   // nil effort → pi's own default, no flag
}

/// The user's pi config is deliberately NOT silenced (pi users self-select for a customized
/// harness — their extensions/skills ARE their agent): no isolation flags ever reach argv. The
/// subz bridge composes additively via the explicit `--extension` path.
@Test func piNeverEmitsIsolationFlags() {
    let argv = SZPiProvider().launch(request(port: 42100), preallocatedSessionID: "x").arguments
    for flag in ["--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-tools"] {
        #expect(!argv.contains(flag), "pi argv must not carry \(flag)")
    }
}

/// The catalog mapper: bare ids qualify as `provider/id`, thinking menus derive from the
/// documented thinkingLevelMap tristate, and the default is the CLI's own (get_state — the
/// user's configured default, not our guess).
@Test func piCatalogSnapshotMapsRecordedRPCOutput() throws {
    let snapshot = try #require(SZPiProvider.catalogSnapshot(fromRPCOutput: piRPCCatalog))
    #expect(snapshot.models.map(\.id)
            == ["openai-codex/gpt-5.4-mini", "openai-codex/gpt-5.5", "openai-codex/gpt-5.6-luna"])
    #expect(snapshot.models.map(\.displayName) == ["GPT-5.4 mini", "GPT-5.5", "GPT-5.6 Luna"])
    #expect(snapshot.defaultModelID == "openai-codex/gpt-5.5")
    // gpt-5.5: standard levels + xhigh, no max (its map has no "max" entry).
    #expect(snapshot.models[1].supportedReasoningEfforts == ["minimal", "low", "medium", "high", "xhigh"])
    // luna's map adds max as a string → supported.
    #expect(snapshot.models[2].supportedReasoningEfforts == ["minimal", "low", "medium", "high", "xhigh", "max"])
    #expect(snapshot.models.allSatisfy { $0.defaultReasoningEffort == "medium" })
}

/// The documented tristate, corner by corner: omitted = standard-through-high supported; null =
/// hole (pi's docs use a model exposing only high and max); string = supported; reasoning:false =
/// no menu at all. `off` never appears — subz doesn't model a "no thinking" token.
@Test func piThinkingLevelDerivationFollowsTheDocumentedTristate() {
    #expect(SZPiProvider.thinkingLevels(reasoning: true, map: [:])
            == ["minimal", "low", "medium", "high"])
    #expect(SZPiProvider.thinkingLevels(
        reasoning: true,
        map: ["minimal": NSNull(), "low": NSNull(), "medium": NSNull(), "high": "high", "max": "max"])
            == ["high", "max"])
    #expect(SZPiProvider.thinkingLevels(reasoning: true, map: ["xhigh": "xhigh", "minimal": "low"])
            == ["minimal", "low", "medium", "high", "xhigh"])
    #expect(SZPiProvider.thinkingLevels(reasoning: false, map: ["max": "max"]).isEmpty)
    #expect(!SZPiProvider.thinkingLevels(reasoning: true, map: [:]).contains("off"))
}

/// refreshModelCatalog is one token-free RPC spawn: the two commands ride stdin, the parsed
/// snapshot becomes what `models`/`defaultModel` serve, and the resolver clamps against it —
/// xhigh survives on gpt-5.5, max clamps away (its map never advertised it).
@Test func piRefreshModelCatalogFetchesAndServes() async throws {
    let pi = SZPiProvider()
    let stub = StubRunner(output: piRPCCatalog)
    let snapshot = try #require(try await pi.refreshModelCatalog(runner: stub))

    let call = try #require(stub.lastCall)
    #expect(call.arguments == ["pi", "--mode", "rpc", "--no-session", "--offline"])
    let stdin = String(decoding: try #require(call.input), as: UTF8.self)
    #expect(stdin.contains(#""type":"get_state""#))
    #expect(stdin.contains(#""type":"get_available_models""#))

    #expect(pi.models.map(\.id) == snapshot.models.map(\.id))
    #expect(pi.defaultModel == "openai-codex/gpt-5.5")

    let kept = pi.resolvedGenerationSettings(
        from: SZProviderGenerationSettings(model: "openai-codex/gpt-5.5", reasoningEffort: "xhigh", fastMode: false))
    #expect(kept.reasoningEffort == "xhigh")
    let clamped = pi.resolvedGenerationSettings(
        from: SZProviderGenerationSettings(model: "openai-codex/gpt-5.5", reasoningEffort: "max", fastMode: true))
    #expect(clamped == SZProviderGenerationSettings(model: "openai-codex/gpt-5.5", reasoningEffort: "medium", fastMode: false))
}

/// Logged out, the fetch parses cleanly to ZERO models (recorded) — an empty catalog next to an
/// authNeeded status is the truthful state, and seeding a persisted snapshot restores service
/// without a fetch (the offline relaunch story).
@Test func piEmptyAndSeededCatalogs() async throws {
    let pi = SZPiProvider()
    let empty = try #require(try await pi.refreshModelCatalog(runner: StubRunner(output: piRPCCatalogLoggedOut)))
    #expect(empty.models.isEmpty)
    #expect(empty.defaultModelID == nil)   // the sentinel "unknown" default is ignored
    #expect(pi.models.isEmpty)

    let seeded = SZPiProvider()
    seeded.seedModelCatalog(SZProviderModelCatalog(
        models: [SZProviderModel(id: "openai-codex/gpt-5.5", displayName: "GPT-5.5",
                                 supportedReasoningEfforts: ["low", "medium"], defaultReasoningEffort: "medium")],
        defaultModelID: "openai-codex/gpt-5.5"))
    #expect(seeded.defaultModel == "openai-codex/gpt-5.5")
    #expect(seeded.resolvedGenerationSettings(from: nil)
            == SZProviderGenerationSettings(model: "openai-codex/gpt-5.5", reasoningEffort: "medium", fastMode: false))
}

/// pi streams complete messages (`message_end`) — the consumer classifies those, never the
/// token-level deltas. Assistant text is held as the reply candidate, thinking blocks carry REAL
/// reasoning text (no CLI-side redaction) → `.thinking`, tool starts carry the real tool name, and
/// a superseded text demotes to narration — the same reply/trace split as claude/codex/grok.
/// Fixture lines follow the recorded event shapes.
@Test func piStreamConsumerClassifiesReplyAndTrace() {
    let c = SZPiProvider().makeStreamConsumer()
    // header, lifecycle, user echo, and deltas are all silent
    #expect(c.consume(#"{"type":"session","version":3,"id":"abc"}"#).isEmpty)
    #expect(c.consume(#"{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#).isEmpty)
    #expect(c.consume(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"O"}}"#).isEmpty)
    // an intermediate assistant message: thinking text surfaces; its toolCall block is silent
    // (tool_execution_start carries the name)
    #expect(c.consume(#"{"type":"message_end","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"thinking","thinking":"need the graph"},{"type":"toolCall","id":"call_1","name":"agent_read_graph","arguments":{}}]}}"#)
            == [.thinking("need the graph")])
    #expect(c.consume(#"{"type":"tool_execution_start","toolCallId":"call_1","toolName":"agent_read_graph","args":{}}"#)
            == [.toolCall(name: "agent_read_graph")])
    #expect(c.consume(#"{"type":"message_end","message":{"role":"toolResult","content":[{"type":"text","text":"GRAPH"}]}}"#).isEmpty)
    // the final assistant text is held, and finish() flushes it exactly once
    #expect(c.consume(#"{"type":"message_end","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"done: 3 nodes"}]}}"#).isEmpty)
    #expect(c.finish() == [.reply("done: 3 nodes")])
    #expect(c.finish().isEmpty)
}

@Test func piStreamConsumerDemotesSupersededTextAndSurfacesErrors() {
    let c = SZPiProvider().makeStreamConsumer()
    #expect(c.consume(#"{"type":"message_end","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"text","text":"I'll check the file"}]}}"#).isEmpty)
    // a later assistant message supersedes the held text → narration
    #expect(c.consume(#"{"type":"message_end","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"42"}]}}"#)
            == [.thinking("I'll check the file")])
    #expect(c.finish() == [.reply("42")])

    // A failed turn's error surfaces in the trace; the run's failure rides parse(), not this.
    let e = SZPiProvider().makeStreamConsumer()
    #expect(e.consume(#"{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"Codex error: model not supported","content":[]}}"#)
            == [.thinking("⚠ Codex error: model not supported")])
    #expect(e.finish().isEmpty)

    // auto_retry_start (transient backend error, pi retries itself) is trace-worthy.
    let r = SZPiProvider().makeStreamConsumer()
    #expect(r.consume(#"{"type":"auto_retry_start","attempt":1,"errorMessage":"overloaded"}"#)
            == [.thinking("⚠ retrying: overloaded")])
    // stderr warnings interleave in the merged stream (e.g. the "creating a new session" notice) —
    // non-JSON lines must skip, never throw or leak into the trace.
    #expect(r.consume("Warning: No project session found with id 'x'; creating a new session with that id.").isEmpty)
}

/// Every assistant message_end carries usage (recorded verbatim from a live pi 0.80.6 run against
/// openai-codex/gpt-5.5) — and pi's `input` EXCLUDES the cache shares (pi-ai subtracts them from
/// OpenAI's inclusive input_tokens, per its source), so the total prompt side is input + cacheRead
/// + cacheWrite. A tool-use turn has several assistant messages: usage SUMS across them and emits
/// once in finish(), ahead of the reply.
@Test func piStreamConsumerSumsUsageAcrossTheTurn() {
    let c = SZPiProvider().makeStreamConsumer()
    #expect(c.consume(#"{"type":"message_end","message":{"role":"assistant","stopReason":"toolUse","usage":{"input":1129,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":1134,"cost":{"input":0.005645,"output":0.00015,"cacheRead":0,"cacheWrite":0,"total":0.005795}},"content":[{"type":"text","text":"checking"}]}}"#).isEmpty)
    #expect(c.consume(#"{"type":"message_end","message":{"role":"assistant","stopReason":"stop","usage":{"input":100,"output":20,"cacheRead":1000,"cacheWrite":50,"reasoning":8,"totalTokens":1170,"cost":{"total":0.001}},"content":[{"type":"text","text":"42"}]}}"#)
            == [.thinking("checking")])
    #expect(c.finish() == [
        // cost is a float SUM (0.005795 + 0.001) — spelled as the same addition, not a decimal
        // literal, so the expectation lands on the identical binary double.
        .usage(SZTokenUsage(inputTokens: 2279, outputTokens: 25, cachedInputTokens: 1050,
                            reasoningOutputTokens: 8, costUSD: 0.005795 + 0.001)),
        .reply("42"),
    ])
    #expect(c.finish().isEmpty)   // usage and reply both flush exactly once
}

/// pi's arg parser flag-parses a leading `-`/`--` (swallowing the next token) and eats a leading
/// `@` as a file attachment, with no `--` terminator (verified 0.80.6 cli/args.js) — and resumed
/// node chats pass the user's message RAW. A leading space defeats both checks; ordinary prompts
/// pass through untouched.
@Test func piPromptPositionalSurvivesFlagLikeLeadingCharacters() {
    let pi = SZPiProvider()
    var req = request(port: nil)
    req.prompt = "@State isn't updating — why?"
    #expect(pi.launch(req, preallocatedSessionID: "s").arguments.last == " @State isn't updating — why?")
    req.prompt = "--verbose please explain"
    #expect(pi.launch(req, preallocatedSessionID: "s").arguments.last == " --verbose please explain")
    req.prompt = "make it grayscale"
    #expect(pi.launch(req, preallocatedSessionID: "s").arguments.last == "make it grayscale")
}

/// A runtime-catalog provider with an EMPTY catalog resolves NO effort (not the provider-level
/// fallback): `--thinking` against a CLI-default model we never enumerated is an unrecorded
/// combination, so argv must omit both --model and the effort flag.
@Test func resolverEmitsNoEffortForAnEmptyModelCatalog() {
    let pi = SZPiProvider()   // fresh instance: catalog unseeded, models == []
    let resolved = pi.resolvedGenerationSettings(
        from: SZProviderGenerationSettings(model: nil, reasoningEffort: "high", fastMode: false))
    #expect(resolved.model == "")
    #expect(resolved.reasoningEffort == nil)
}

/// The coding prompt drives the 3-tier library browse, and keeps the agent's agency.
/// The browse now lives behind `node-compile`'s `{{reference}}` token — a split/merge piece swaps it for the
/// preserve-behavior section — so assert on the RENDERED ordinary prompt, not the bare template.
///
/// A library hit informs the implementation; it doesn't dictate it. The prompt frames a match as a
/// reference and leaves writing from scratch open, so a near-miss isn't adapted into a node that should
/// have been written fresh. `SZLibrarySearch` does the structural half (an empty shortlist when nothing
/// fits); the wording half is asserted here.
@Test func codingPromptBrowsesLibraryWithAgency() {
    let prompt = SZPromptTemplate.render(SZPrompts.nodeCompile, ["reference": SZPrompts.referenceLibrary])
    // the tiers: search narrows, index browses, card confirms, source commits
    for tool in ["agent_library_index", "agent_library_card", "agent_library_source"] {
        #expect(prompt.contains(tool), "coding prompt should mention \(tool)")
    }
    // reuse is a hint, and the agent chooses copy / adapt / original
    #expect(prompt.contains("guidance, not a rule"))
    #expect(prompt.contains("reference, not a template"))
    #expect(prompt.contains("write the node from scratch"))
    for mode in ["copy as-is", "copy and adapt", "write original"] {
        #expect(prompt.contains(mode), "coding prompt should offer the \(mode) path")
    }
}

/// The cold-start chat prompt loads (resource is bundled) and embeds the node id, the user
/// message, and the current source/contract so a fresh Coding Agent can edit an existing node.
@Test func nodeColdStartPromptEmbedsContext() {
    let prompt = SZChatPrompts.nodeColdStart(
        node: "NODE-123", userMessage: "make it invert color",
        currentContract: "{\"title\":\"Grayscale\"}", currentSource: "final class Node: SZNode {}")
    #expect(prompt.contains("NODE-123"))
    #expect(prompt.contains("make it invert color"))
    #expect(prompt.contains("\"title\":\"Grayscale\""))
    #expect(prompt.contains("final class Node: SZNode {}"))
    for tool in ["agent_write_node_staged", "agent_compile_node", "agent_report_status"] {
        #expect(prompt.contains(tool))
    }
}

/// claude is the only provider that gates per-tool, so it must MIRROR `request.allowedMCPTools`
/// (the app's `SZHostBridge.agentCallableToolNames`) into `--allowedTools`, prefixed — a tool it
/// isn't handed is denied in non-interactive -p mode. The app-side test target owns the guard that the
/// mirrored set is exactly the agent surface (incl. `agent_view_frame`) minus the withheld/debug tools;
/// here we only prove the provider forwards whatever it's given and adds its native file tools.
@Test func claudeMirrorsAllowedMCPToolsIntoAllowlist() {
    let mcp = ["agent_library_index", "agent_library_card", "agent_library_source",
               "agent_view_frame", "ui_run"]
    let argv = SZClaudeProvider().launch(request(port: 42100, allowedMCPTools: mcp),
                                         preallocatedSessionID: "x").arguments
    let allowed = try! #require(argv.value(after: "--allowedTools"))
    for tool in mcp {
        #expect(allowed.contains("mcp__subz__\(tool)"), "claude allowedTools should mirror \(tool)")
    }
    // Native file tools are claude's own, added regardless of the MCP set.
    for native in ["Read", "Write", "Edit"] { #expect(allowed.contains(native)) }
    // A tool NOT handed to the provider must not appear — the provider adds nothing on its own, so a
    // withheld tool (or a debug tool) can only reach the allowlist by being in `allowedMCPTools`.
    #expect(!allowed.contains("ui_stop"), "provider must not inject tools it wasn't given")
    #expect(!allowed.contains("debug_"), "claude allowedTools must not include any debug_* tool")
}

/// With no MCP attached (e.g. the health probe), the allowlist is native file tools only.
@Test func claudeAllowlistIsNativeOnlyWithoutMCP() {
    let argv = SZClaudeProvider().launch(request(port: nil), preallocatedSessionID: "x").arguments
    let allowed = try! #require(argv.value(after: "--allowedTools"))
    #expect(allowed == "Read,Write,Edit")
}

/// The box's acceptance criterion: health check passes. LIVE — it shells out to the real CLIs, so it
/// needs both installed AND logged in (tier 2 runs the CLI's own auth-status command). That makes it a
/// property of the machine, not of this code: on a fresh checkout it goes red for a reason no change
/// here caused. Gated behind `SZ_LIVE_PROVIDERS=1` so the default suite stays honest — the classification
/// logic it would otherwise cover is already pinned deterministically by SZProviderHealthTests' stubs.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SZ_LIVE_PROVIDERS"] != nil))
func allProvidersHealthReady() async {
    for provider in SZProviderRegistry.shared.providers {
        let report = await provider.healthReport()
        #expect(report.status == .ready, "\(provider.id) health: \(report.message)")
    }
}

/// Cancelling a run (the HUD Stop button → orchestrator Task cancel) must kill the subprocess and
/// return without crashing — guards against reading `terminationStatus` on a still-running task, which
/// throws an uncaught NSException.
@Test func cancellingARunKillsTheProcessWithoutCrashing() async throws {
    let runner = SZSystemProcessRunner()
    let task = Task {
        try await runner.run("/bin/sleep", ["30"], environment: [:],
                             currentDirectoryURL: nil, timeout: nil, onOutput: nil)
    }
    try await Task.sleep(for: .milliseconds(200))   // let sleep(1) start
    task.cancel()
    let result = try await task.value               // returns (no crash); sentinel/-1 exit code
    #expect(result.timedOut == false)
}
