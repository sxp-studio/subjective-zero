// SPDX-License-Identifier: AGPL-3.0-only
// Tier 3 of provider health (see SZProviderHealth.swift): one real one-shot prompt through the
// provider's OWN launch()/parse() path — the "actually works" check that `--version` and an auth
// status can't give (model access, quota, a functioning agent loop). This is the only tier that
// costs tokens, so callers gate it: the first-run setup flow probes each healthy provider once,
// the setup sheet's per-card Test button probes on demand, and the poll loop never probes.
import Foundation

public extension SZProvider {
    /// One tiny prompt ("Reply with exactly: OK"), default model, no MCP, fresh temp cwd/cache.
    /// Mirrors `run()`'s spawn (mint → launch → run → parse) inline so the diagnostic can carry
    /// the exact argv that ran.
    func healthProbe(runner: any SZProcessRunning = SZSystemProcessRunner()) async -> SZProviderHealthReport {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "sz-provider-probe-\(id)-\(UUID().uuidString)")
        let work = root.appending(path: "work")
        let cache = root.appending(path: "cache")
        try? fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        // mcpServerPort nil → both providers omit their MCP wiring; model nil → provider default.
        let request = SZAgentRunRequest(prompt: "Reply with exactly: OK",
                                        workingDirectory: work, cacheDirectory: cache,
                                        timeout: 90)
        let preallocated = usesPreallocatedSessionID ? UUID().uuidString : nil
        let cliPath = SZAgentEnvironment.resolveExecutable(healthArgs.first ?? "")

        func report(_ status: SZProviderHealthStatus, _ message: String,
                    diagnostic: SZProviderHealthDiagnostic) -> SZProviderHealthReport {
            SZProviderHealthReport(providerID: id, status: status, message: message,
                                   cliPath: cliPath, probeVerified: status == .ready,
                                   diagnostics: [diagnostic])
        }

        // Same order as run(): stage the working directory, then build argv.
        do {
            try prepare(request)
        } catch {
            return report(.healthFailed, "Probe could not stage the working directory.",
                          diagnostic: SZProviderHealthDiagnostic(
                              tier: .probe, attemptedCommand: [], exitCode: nil, timedOut: false,
                              outputExcerpt: SZProviderHealthDiagnostic.excerpt("\(error)")))
        }
        let launch = launch(request, preallocatedSessionID: preallocated)
        let startedAt = Date()

        let result: SZProcessResult
        do {
            result = try await runner.run(launch.executable, launch.arguments,
                                          environment: launch.environment,
                                          currentDirectoryURL: work,
                                          timeout: request.timeout, onOutput: nil)
        } catch {
            return report(.healthFailed, "Probe could not launch.",
                          diagnostic: SZProviderHealthDiagnostic(
                              tier: .probe, attemptedCommand: launch.arguments, exitCode: nil,
                              timedOut: false,
                              outputExcerpt: SZProviderHealthDiagnostic.excerpt("\(error)")))
        }
        let outcome = parse(output: result.output, exitCode: result.exitCode,
                            preallocatedSessionID: preallocated)
        let succeeded = !outcome.failed && !result.timedOut
        let diagnostic = SZProviderHealthDiagnostic(
            tier: .probe, attemptedCommand: launch.arguments, exitCode: result.exitCode,
            timedOut: result.timedOut,
            outputExcerpt: succeeded ? nil : SZProviderHealthDiagnostic.excerpt(result.output))

        if succeeded {
            let seconds = Int(Date().timeIntervalSince(startedAt).rounded())
            return report(.ready, "Verified — replied in \(seconds)s.", diagnostic: diagnostic)
        }
        // Markers outrank the timeout: a CLI that answers a logged-out run by WAITING for an
        // interactive login never exits, so the killed run's output showing the login wall is
        // authNeeded — reporting it as a timeout would send the user to debugging instead of login.
        if authFailureMarkers.contains(where: result.output.contains) {
            return report(.authNeeded, "Probe hit a login wall — not logged in.",
                          diagnostic: diagnostic)
        }
        if result.timedOut {
            return report(.healthFailed, "Probe timed out after \(Int(request.timeout ?? 0))s.",
                          diagnostic: diagnostic)
        }
        return report(.healthFailed, "Probe failed (exit \(result.exitCode)).", diagnostic: diagnostic)
    }
}
