// SPDX-License-Identifier: AGPL-3.0-only
// Provider health — the truth behind the setup sheet, the HUD health dot, and the
// `--verify-agent-providers` self-check (docs/AI_PROVIDERS.md).
//
// Three tiers, cheapest first:
//   1. install — `<cli> --version` (proves installed + runnable, nothing more);
//   2. auth    — the CLI's own status command (`claude auth status` / `codex login status`),
//                still subprocess-cheap and token-free;
//   3. probe   — one real one-shot prompt through the provider's actual launch path
//                (`healthProbe()`, SZProviderProbe.swift) — the only tier that costs tokens,
//                so callers gate it (first-run setup + an explicit per-card Test).
// `healthReport()` below runs tiers 1–2. The six-status vocabulary matches the setup
// contract (docs/APP_SETUP.md): `invalidConfig`/`unsupported` are reserved — per-provider Swift can't
// produce a bad config today, but agents parsing the verifier JSON get the full stable set.
import Foundation

public enum SZProviderHealthStatus: String, Codable, Sendable {
    case ready          // installed, authed (and probe-verified when probeVerified is set)
    case missingCLI     // the CLI is not on the (augmented) search path
    case authNeeded     // installed but logged out — remedy is an interactive login
    case healthFailed   // installed but a check failed for a non-auth reason (timeout, nonzero exit)
    case invalidConfig  // reserved (verifier-contract parity; unreachable with Swift providers)
    case unsupported    // provider vends no health check

    /// The coarse severity axis the HUD dot renders (the old green/amber/red, now derived).
    /// missingCLI/authNeeded are amber — absent or logged-out is a setup task, not a malfunction.
    public var severity: SZProviderHealthSeverity {
        switch self {
        case .ready: .green
        case .missingCLI, .authNeeded: .amber
        case .healthFailed, .invalidConfig, .unsupported: .red
        }
    }
}

public enum SZProviderHealthSeverity: String, Codable, Sendable { case green, amber, red }

public enum SZProviderHealthTier: String, Codable, Sendable { case install, auth, probe }

/// One tier's raw evidence — what ran, how it exited, and (on failure) what it said. Carried on
/// the report so the setup sheet's detail popover and the verifier JSON can show the receipts.
/// `attemptedCommand` is the argv after `/usr/bin/env` — secret-free by construction (CLI-only
/// providers, no keys anywhere).
public struct SZProviderHealthDiagnostic: Codable, Sendable, Equatable {
    public var tier: SZProviderHealthTier
    public var attemptedCommand: [String]
    public var exitCode: Int32?          // nil when the process never launched
    public var timedOut: Bool
    public var outputExcerpt: String?    // last 1500 chars, failures only

    public init(tier: SZProviderHealthTier, attemptedCommand: [String], exitCode: Int32?,
                timedOut: Bool, outputExcerpt: String? = nil) {
        self.tier = tier
        self.attemptedCommand = attemptedCommand
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.outputExcerpt = outputExcerpt
    }

    /// Keep the tail — CLI errors put the useful line last (the head is banners/warnings).
    static func excerpt(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.suffix(1500))
    }
}

/// The merged verdict for one provider at one point in time.
public struct SZProviderHealthReport: Codable, Sendable, Equatable {
    public var providerID: String
    public var status: SZProviderHealthStatus
    public var message: String           // one human sentence for the card / verifier
    public var cliPath: String?          // resolved absolute path (the card's monospaced path line)
    public var version: String?          // `--version` first line
    public var probeVerified: Bool       // true only when tier 3 actually replied
    public var diagnostics: [SZProviderHealthDiagnostic]
    public var checkedAt: Date

    public init(providerID: String, status: SZProviderHealthStatus, message: String,
                cliPath: String? = nil, version: String? = nil, probeVerified: Bool = false,
                diagnostics: [SZProviderHealthDiagnostic] = [], checkedAt: Date = Date()) {
        self.providerID = providerID
        self.status = status
        self.message = message
        self.cliPath = cliPath
        self.version = version
        self.probeVerified = probeVerified
        self.diagnostics = diagnostics
        self.checkedAt = checkedAt
    }
}

public extension SZProvider {
    /// Tiers 1–2: install (`--version`) then auth status. Subprocess-cheap, token-free — safe for
    /// the sheet's poll loop and the launch check. Never runs the provider's agent loop.
    func healthReport(runner: any SZProcessRunning = SZSystemProcessRunner()) async -> SZProviderHealthReport {
        guard let cli = healthArgs.first else {
            return SZProviderHealthReport(providerID: id, status: .unsupported,
                                          message: "No health check for this provider.")
        }
        let cliPath = SZAgentEnvironment.resolveExecutable(cli)
        var diagnostics: [SZProviderHealthDiagnostic] = []

        func report(_ status: SZProviderHealthStatus, _ message: String, version: String? = nil) -> SZProviderHealthReport {
            SZProviderHealthReport(providerID: id, status: status, message: message,
                                   cliPath: cliPath, version: version, diagnostics: diagnostics)
        }

        // Tier 1 — install. `/usr/bin/env` always launches; a missing CLI is env's exit 127.
        let install: SZProcessResult
        do {
            install = try await runner.run("/usr/bin/env", healthArgs,
                                           environment: SZAgentEnvironment.base(),
                                           currentDirectoryURL: nil, timeout: 5, onOutput: nil)
        } catch {
            diagnostics.append(SZProviderHealthDiagnostic(
                tier: .install, attemptedCommand: healthArgs, exitCode: nil, timedOut: false,
                outputExcerpt: SZProviderHealthDiagnostic.excerpt("\(error)")))
            return report(.healthFailed, "Could not launch the version check.")
        }
        let installFailed = install.timedOut || install.exitCode != 0
        diagnostics.append(SZProviderHealthDiagnostic(
            tier: .install, attemptedCommand: healthArgs, exitCode: install.exitCode,
            timedOut: install.timedOut,
            outputExcerpt: installFailed ? SZProviderHealthDiagnostic.excerpt(install.output) : nil))
        if install.timedOut {
            return report(.healthFailed, "Version check timed out.")
        }
        if install.exitCode == 127 || Self.looksLikeMissingExecutable(install.output) {
            return report(.missingCLI, "The `\(cli)` CLI was not found.")
        }
        if install.exitCode != 0 {
            return report(.healthFailed, "Version check failed (exit \(install.exitCode)).")
        }
        let version = install.output.szFirstLine

        // Tier 2 — auth status. [] = the CLI has no cheap auth command; the probe is the arbiter.
        guard !authStatusArgs.isEmpty else {
            return report(.ready, "Installed — auth not checked (no status command).", version: version)
        }
        let auth: SZProcessResult
        do {
            auth = try await runner.run("/usr/bin/env", authStatusArgs,
                                        environment: SZAgentEnvironment.base(),
                                        currentDirectoryURL: nil, timeout: 10, onOutput: nil)
        } catch {
            diagnostics.append(SZProviderHealthDiagnostic(
                tier: .auth, attemptedCommand: authStatusArgs, exitCode: nil, timedOut: false,
                outputExcerpt: SZProviderHealthDiagnostic.excerpt("\(error)")))
            return report(.healthFailed, "Could not launch the auth check.", version: version)
        }
        let authFailed = auth.timedOut || auth.exitCode != 0
        diagnostics.append(SZProviderHealthDiagnostic(
            tier: .auth, attemptedCommand: authStatusArgs, exitCode: auth.exitCode,
            timedOut: auth.timedOut,
            outputExcerpt: authFailed ? SZProviderHealthDiagnostic.excerpt(auth.output) : nil))
        if auth.timedOut {
            return report(.healthFailed, "Auth check timed out.", version: version)
        }
        if auth.exitCode == 0 {
            return report(.ready, "Installed and \(Self.loggedInSummary(from: auth.output)).", version: version)
        }
        // An older CLI without the status subcommand isn't "logged out" — auth is unknown; stay
        // ready off the version check and let the probe tier be the arbiter.
        if Self.looksLikeUnknownSubcommand(auth.output) {
            return report(.ready, "Installed — auth status unknown (CLI predates the status command).",
                          version: version)
        }
        return report(.authNeeded, "Installed but not logged in.", version: version)
    }
}

extension SZProvider {
    /// env's own "not found" grammar, for runners that don't surface exit 127 faithfully.
    static func looksLikeMissingExecutable(_ output: String) -> Bool {
        output.contains("No such file or directory")
            || output.contains("command not found")
            || output.range(of: #"env: .*: not found"#, options: .regularExpression) != nil
    }

    /// A CLI complaining about the subcommand itself (e.g. "error: unknown command 'auth'") —
    /// distinct from a real logged-out exit.
    static func looksLikeUnknownSubcommand(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return lowered.contains("unknown command") || lowered.contains("unrecognized subcommand")
            || lowered.contains("unexpected argument") || lowered.contains("unknown option")
    }

    /// One human phrase from a successful auth-status output: claude prints JSON
    /// (`{"loggedIn": true, "authMethod": "claude.ai"}`), codex prints a sentence
    /// ("Logged in using ChatGPT"). Best-effort — falls back to "logged in".
    static func loggedInSummary(from output: String) -> String {
        if let data = output.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let method = obj["authMethod"] as? String, method != "none" {
                return "logged in (\(method))"
            }
            return "logged in"
        }
        let line = output.szFirstLine
        return line.lowercased().hasPrefix("logged in") ? line.prefix(1).lowercased() + line.dropFirst() : "logged in"
    }
}
