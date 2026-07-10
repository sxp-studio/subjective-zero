// SPDX-License-Identifier: AGPL-3.0-only
// The `--verify-agent-providers --json` self-check (docs/APP_SETUP.md): the machine-readable
// report a setup agent parses to prove the install actually works. Lives in SZAI (not the app
// entry point) so the report assembly is unit-testable; SZMain owns the flag parse + exit codes.
import Foundation

public struct SZProviderVerificationReport: Codable, Sendable {
    public var appVersion: String
    public var appBuild: String
    public var defaultProviderID: String?     // the confirmed setup-sheet default; nil = never confirmed
    public var ok: Bool                       // ≥1 provider ready
    public var generatedAt: Date
    public var providers: [SZProviderHealthReport]

    public init(appVersion: String, appBuild: String, defaultProviderID: String?,
                ok: Bool, generatedAt: Date = Date(), providers: [SZProviderHealthReport]) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.defaultProviderID = defaultProviderID
        self.ok = ok
        self.generatedAt = generatedAt
        self.providers = providers
    }
}

public enum SZProviderVerifier {
    /// Cheap tiers for every registered provider; `probe: true` (the `--probe` flag) upgrades each
    /// cheap-ready provider with one real prompt probe — opt-in because it costs tokens.
    public static func run(registry: SZProviderRegistry = .shared, defaultProviderID: String?,
                           appVersion: String, appBuild: String, probe: Bool,
                           runner: any SZProcessRunning = SZSystemProcessRunner()) async -> SZProviderVerificationReport {
        var reports: [SZProviderHealthReport] = []
        for provider in registry.providers {
            var report = await provider.healthReport(runner: runner)
            if probe, report.status == .ready {
                let probed = await provider.healthProbe(runner: runner)
                // The probe verdict is the deeper truth; keep the cheap tiers' receipts + findings.
                report.status = probed.status
                report.message = probed.message
                report.probeVerified = probed.probeVerified
                report.diagnostics += probed.diagnostics
                report.checkedAt = probed.checkedAt
            }
            reports.append(report)
        }
        return SZProviderVerificationReport(appVersion: appVersion, appBuild: appBuild,
                                            defaultProviderID: defaultProviderID,
                                            ok: reports.contains { $0.status == .ready },
                                            providers: reports)
    }

    public static func json(_ report: SZProviderVerificationReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) else {
            return #"{"ok": false, "error": "report encoding failed"}"#   // never expected; keeps stdout parseable
        }
        return text
    }
}
