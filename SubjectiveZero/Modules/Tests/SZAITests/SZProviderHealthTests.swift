// SPDX-License-Identifier: AGPL-3.0-only
// The health tiers (SZProviderHealth.swift): six-status vocabulary, install + auth checks, and the
// classification grammar — driven by outputs RECORDED from the real CLIs (claude 2.1.200,
// codex-cli 0.141.0, logged-out variants captured via HOME-override runs on 2026-07-03), so the
// fixtures are the CLI contract we detect against, not invented strings.
import Foundation
import Synchronization
import Testing
@testable import SZAI

/// A per-command stub: each script entry matches an argv prefix and returns its canned result.
/// (The single-result StubRunner in SZProviderTests can't express "version passes, auth fails".)
/// An unscripted call returns a sentinel failure so the mismatch surfaces in status expectations.
private final class ScriptedStubRunner: SZProcessRunning {
    struct Script: Sendable {
        var argvPrefix: [String]
        var result: SZProcessResult
    }
    private let scripts: [Script]
    private let calls = Mutex<[[String]]>([])

    init(_ scripts: [Script]) { self.scripts = scripts }

    var recordedCalls: [[String]] { calls.withLock { $0 } }

    func run(
        _ launchPath: String, _ arguments: [String],
        environment: [String: String], currentDirectoryURL: URL?,
        timeout: TimeInterval?, onOutput: (@Sendable (String) -> Void)?
    ) async throws -> SZProcessResult {
        calls.withLock { $0.append(arguments) }
        for script in scripts where arguments.starts(with: script.argvPrefix) {
            return script.result
        }
        return SZProcessResult(exitCode: 86, output: "unscripted call: \(arguments)")
    }
}

// Recorded fixtures — the real outputs the classifiers must keep matching.
private let claudeVersionOK = SZProcessResult(exitCode: 0, output: "2.1.200 (Claude Code)")
private let claudeAuthLoggedIn = SZProcessResult(
    exitCode: 0,
    output: #"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": "x@example.com"}"#)
private let claudeAuthLoggedOut = SZProcessResult(
    exitCode: 1,
    output: #"{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}"#)
private let codexVersionOK = SZProcessResult(exitCode: 0, output: "codex-cli 0.141.0")
private let codexAuthLoggedIn = SZProcessResult(exitCode: 0, output: "Logged in using ChatGPT")
private let codexAuthLoggedOut = SZProcessResult(exitCode: 1, output: "Not logged in")

@Test func readyWhenVersionAndAuthPass() async {
    let claude = await SZClaudeProvider().healthReport(runner: ScriptedStubRunner([
        .init(argvPrefix: ["claude", "--version"], result: claudeVersionOK),
        .init(argvPrefix: ["claude", "auth", "status"], result: claudeAuthLoggedIn),
    ]))
    #expect(claude.status == .ready)
    #expect(claude.version == "2.1.200 (Claude Code)")
    #expect(claude.message.contains("claude.ai"))   // auth method surfaced from the status JSON
    #expect(claude.diagnostics.map(\.tier) == [.install, .auth])
    #expect(claude.diagnostics.allSatisfy { $0.outputExcerpt == nil })   // successes carry no excerpt

    let codex = await SZCodexProvider().healthReport(runner: ScriptedStubRunner([
        .init(argvPrefix: ["codex", "--version"], result: codexVersionOK),
        .init(argvPrefix: ["codex", "login", "status"], result: codexAuthLoggedIn),
    ]))
    #expect(codex.status == .ready)
    #expect(codex.version == "codex-cli 0.141.0")
}

@Test func missingCLIWhenEnvExits127() async {
    let report = await SZClaudeProvider().healthReport(runner: ScriptedStubRunner([
        .init(argvPrefix: ["claude", "--version"],
              result: SZProcessResult(exitCode: 127, output: "env: claude: No such file or directory")),
    ]))
    #expect(report.status == .missingCLI)
    #expect(report.diagnostics.map(\.tier) == [.install])   // tier 2 never ran
    #expect(report.diagnostics[0].outputExcerpt?.contains("No such file") == true)
}

@Test func authNeededWhenClaudeLoggedOut() async {
    let report = await SZClaudeProvider().healthReport(runner: ScriptedStubRunner([
        .init(argvPrefix: ["claude", "--version"], result: claudeVersionOK),
        .init(argvPrefix: ["claude", "auth", "status"], result: claudeAuthLoggedOut),
    ]))
    #expect(report.status == .authNeeded)
    #expect(report.version == "2.1.200 (Claude Code)")   // install tier's finding survives
}

@Test func authNeededWhenCodexLoggedOut() async {
    let report = await SZCodexProvider().healthReport(runner: ScriptedStubRunner([
        .init(argvPrefix: ["codex", "--version"], result: codexVersionOK),
        .init(argvPrefix: ["codex", "login", "status"], result: codexAuthLoggedOut),
    ]))
    #expect(report.status == .authNeeded)
}

@Test func healthFailedOnVersionTimeout() async {
    let report = await SZCodexProvider().healthReport(runner: ScriptedStubRunner([
        .init(argvPrefix: ["codex", "--version"],
              result: SZProcessResult(exitCode: 124, output: "", timedOut: true)),
    ]))
    #expect(report.status == .healthFailed)
    #expect(report.diagnostics[0].timedOut)
}

/// An older CLI without the auth-status subcommand isn't "logged out" — auth is unknown; the
/// report stays ready off the version check and the probe tier is the arbiter.
@Test func authUnknownOnOldCLIStaysReady() async {
    let report = await SZClaudeProvider().healthReport(runner: ScriptedStubRunner([
        .init(argvPrefix: ["claude", "--version"], result: claudeVersionOK),
        .init(argvPrefix: ["claude", "auth", "status"],
              result: SZProcessResult(exitCode: 1, output: "error: unknown command 'auth'")),
    ]))
    #expect(report.status == .ready)
    #expect(report.message.contains("auth status unknown"))
}

@Test func diagnosticExcerptKeepsTheTail() {
    let long = String(repeating: "x", count: 2000) + "THE ACTUAL ERROR"
    let excerpt = SZProviderHealthDiagnostic.excerpt(long)
    #expect(excerpt?.count == 1500)
    #expect(excerpt?.hasSuffix("THE ACTUAL ERROR") == true)
    #expect(SZProviderHealthDiagnostic.excerpt("   \n ") == nil)
}

@Test func searchPathHonorsSZPathOverride() {
    let overridden = SZAgentEnvironment.searchPath(processEnvironment: [
        "PATH": "/somewhere/else", "SZ_PATH_OVERRIDE": "/usr/bin:/bin",
    ])
    #expect(overridden == "/usr/bin:/bin")
    let normal = SZAgentEnvironment.searchPath(processEnvironment: ["PATH": "/somewhere/else"])
    #expect(normal.hasPrefix("/somewhere/else:"))   // no override → synthesized path as before
}

// Tier 3 — the probe (SZProviderProbe.swift). Classification rides parse() + authFailureMarkers.

@Test func probeReadyOnCleanExit() async {
    let stub = ScriptedStubRunner([
        .init(argvPrefix: ["claude"], result: SZProcessResult(exitCode: 0, output: #"{"type":"result","result":"OK"}"#)),
    ])
    let report = await SZClaudeProvider().healthProbe(runner: stub)
    #expect(report.status == .ready)
    #expect(report.probeVerified)
    #expect(report.diagnostics.map(\.tier) == [.probe])
}

/// The probe is a REAL run through launch(): a logged-out CLI fails it with its login message,
/// and the recorded markers turn that into authNeeded instead of a generic failure.
@Test func probeAuthNeededOnLoggedOutOutput() async {
    let claude = await SZClaudeProvider().healthProbe(runner: ScriptedStubRunner([
        .init(argvPrefix: ["claude"],
              result: SZProcessResult(exitCode: 1, output: "Not logged in · Please run /login")),
    ]))
    #expect(claude.status == .authNeeded)
    #expect(claude.probeVerified == false)

    let codex = await SZCodexProvider().healthProbe(runner: ScriptedStubRunner([
        .init(argvPrefix: ["codex"], result: SZProcessResult(exitCode: 1, output: "Not logged in")),
    ]))
    #expect(codex.status == .authNeeded)
}

@Test func probeHealthFailedOnUnrecognizedFailure() async {
    let report = await SZCodexProvider().healthProbe(runner: ScriptedStubRunner([
        .init(argvPrefix: ["codex"], result: SZProcessResult(exitCode: 2, output: "segfault or whatever")),
    ]))
    #expect(report.status == .healthFailed)
    #expect(report.diagnostics[0].outputExcerpt == "segfault or whatever")
}

@Test func probeHealthFailedOnTimeout() async {
    let report = await SZClaudeProvider().healthProbe(runner: ScriptedStubRunner([
        .init(argvPrefix: ["claude"], result: SZProcessResult(exitCode: 124, output: "", timedOut: true)),
    ]))
    #expect(report.status == .healthFailed)
    #expect(report.message.contains("timed out"))
}

/// The probe must stay tiny and self-contained: no MCP wiring, the provider's default model, and
/// the probe prompt — for both providers' distinct argv grammars.
@Test func probeArgvOmitsMCPAndUsesDefaultModel() async {
    let claudeStub = ScriptedStubRunner([
        .init(argvPrefix: ["claude"], result: SZProcessResult(exitCode: 0, output: "")),
    ])
    _ = await SZClaudeProvider().healthProbe(runner: claudeStub)
    let claudeArgv = try! #require(claudeStub.recordedCalls.first)
    #expect(!claudeArgv.contains("--mcp-config"))
    #expect(claudeArgv.contains("Reply with exactly: OK"))
    #expect(claudeArgv[claudeArgv.firstIndex(of: "--model")! + 1] == SZClaudeProvider().defaultModel)

    let codexStub = ScriptedStubRunner([
        .init(argvPrefix: ["codex"], result: SZProcessResult(exitCode: 0, output: "")),
    ])
    _ = await SZCodexProvider().healthProbe(runner: codexStub)
    let codexArgv = try! #require(codexStub.recordedCalls.first)
    #expect(!codexArgv.joined().contains("mcp_servers"))
    #expect(codexArgv.last == "Reply with exactly: OK")
    #expect(codexArgv[codexArgv.firstIndex(of: "-m")! + 1] == SZCodexProvider().defaultModel)
}

// The verifier (SZProviderVerifier.swift) — what `--verify-agent-providers --json` prints.

@Test func verifierReportOkSemanticsAndJSONShape() async throws {
    // claude healthy, codex missing → ok (≥1 ready), both listed with receipts.
    let runner = ScriptedStubRunner([
        .init(argvPrefix: ["claude", "--version"], result: claudeVersionOK),
        .init(argvPrefix: ["claude", "auth", "status"], result: claudeAuthLoggedIn),
        .init(argvPrefix: ["codex", "--version"],
              result: SZProcessResult(exitCode: 127, output: "env: codex: No such file or directory")),
    ])
    let report = await SZProviderVerifier.run(defaultProviderID: "claude", appVersion: "0.2.1",
                                              appBuild: "42", probe: false, runner: runner)
    #expect(report.ok)
    #expect(report.providers.map(\.status) == [.ready, .missingCLI])

    // The printed JSON must round-trip: it's a machine contract (APP_SETUP.md), not a log line.
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SZProviderVerificationReport.self,
                                     from: Data(SZProviderVerifier.json(report).utf8))
    #expect(decoded.ok && decoded.appVersion == "0.2.1" && decoded.defaultProviderID == "claude")
    #expect(decoded.providers.count == 2)
    // Failure receipts survive the round-trip (the excerpt is what a setup agent acts on).
    #expect(decoded.providers[1].diagnostics.first?.outputExcerpt?.contains("No such file") == true)
}

@Test func verifierNotOkWhenNoProviderReady() async {
    let runner = ScriptedStubRunner([
        .init(argvPrefix: ["claude", "--version"], result: claudeVersionOK),
        .init(argvPrefix: ["claude", "auth", "status"], result: claudeAuthLoggedOut),
        .init(argvPrefix: ["codex", "--version"],
              result: SZProcessResult(exitCode: 127, output: "env: codex: No such file or directory")),
    ])
    let report = await SZProviderVerifier.run(defaultProviderID: nil, appVersion: "dev",
                                              appBuild: "dev", probe: false, runner: runner)
    #expect(!report.ok)
    #expect(report.providers.map(\.status) == [.authNeeded, .missingCLI])
}

/// --probe upgrades a cheap-ready provider with the real prompt probe, keeping both tiers'
/// receipts in one entry.
@Test func verifierProbeUpgradesCheapReady() async {
    let runner = ScriptedStubRunner([
        .init(argvPrefix: ["claude", "--version"], result: claudeVersionOK),
        .init(argvPrefix: ["claude", "auth", "status"], result: claudeAuthLoggedIn),
        .init(argvPrefix: ["claude", "-p"], result: SZProcessResult(exitCode: 0, output: "OK")),
        .init(argvPrefix: ["codex", "--version"],
              result: SZProcessResult(exitCode: 127, output: "env: codex: No such file or directory")),
    ])
    let report = await SZProviderVerifier.run(defaultProviderID: nil, appVersion: "dev",
                                              appBuild: "dev", probe: true, runner: runner)
    let claude = report.providers[0]
    #expect(claude.probeVerified)
    #expect(claude.diagnostics.map(\.tier) == [.install, .auth, .probe])
    #expect(report.providers[1].diagnostics.map(\.tier) == [.install])   // missing → never probed
}

/// The remedies the setup sheet shows are provider data, not UI prose — both providers must vend
/// the full set (install command, login command, auth-status argv, logged-out markers).
@Test func bothProvidersVendSetupRemedies() {
    for provider in SZProviderRegistry.shared.providers {
        #expect(!provider.installCommand.isEmpty, "\(provider.id) needs installCommand")
        #expect(!provider.loginCommand.isEmpty, "\(provider.id) needs loginCommand")
        #expect(!provider.authStatusArgs.isEmpty, "\(provider.id) needs authStatusArgs")
        #expect(!provider.authFailureMarkers.isEmpty, "\(provider.id) needs authFailureMarkers")
        #expect(provider.authStatusArgs.first == provider.healthArgs.first,
                "\(provider.id) auth check should exercise the same CLI")
    }
}
