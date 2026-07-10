// SPDX-License-Identifier: AGPL-3.0-only
// Provider health + the Agent Providers setup sheet — the host-side intents behind roadmap
// Task 2, following the SZHost+Chat.swift sibling pattern. The SZAI tiers (SZProviderHealth /
// SZProviderProbe) are the checks; this file owns WHEN they run (launch pass, sheet poll loop,
// first-run auto-probe, per-card Test), how cheap and probe verdicts merge into one displayed
// status, and the remedies that need AppKit (the Terminal login launcher).
import AppKit
import Foundation
import SZAI
import SZCore
import SZUI

extension SZHost {
    // MARK: - Launch

    /// Non-blocking launch check: one cheap pass so the HUD dot is truthful from the start, then the
    /// first-run auto-present (decided 2026-07-03: first-run only; afterwards the app menu, the HUD
    /// dot, and the run/chat pre-flights are the way back). On a welcome-routed launch the present is
    /// a no-op and `switchProject` retries it on the way out — but the refresh above still runs, so
    /// the sheet opens onto warm health either way.
    func checkProviderSetupOnLaunch() {
        Task { @MainActor in
            await refreshProviderHealthOnce()
            autoPresentProviderSetupIfNeeded()
        }
    }

    /// The first-run sheet, from whichever moment comes first: launch (welcome bypassed) or the exit
    /// from welcome into a live project. Silent unless it's genuinely first-run, and at most once per
    /// launch — a Skip for Now must not be undone by a Help ▸ Welcome round-trip. While welcome is up
    /// this returns WITHOUT consuming the once-per-launch flag, leaving the retry for switchProject.
    func autoPresentProviderSetupIfNeeded() {
        guard defaultProviderID == nil, !providerSetupAutoPresented, !welcomePresented else { return }
        providerSetupAutoPresented = true
        presentProviderSetup()
    }

    // MARK: - Sheet lifecycle

    /// Open the sheet (first-run, app menu ⌘,, HUD dot, or a failed pre-flight) and start the
    /// re-check loop so remedies flip cards green the moment they land.
    func presentProviderSetup() {
        // Never stack over the welcome/home surface (they're mutually-exclusive branches): ⌘, from the
        // home screen is a no-op until the user is in the workspace. Mirrors presentWelcome's guard.
        guard !welcomePresented else { return }
        selectedSetupProviderID = defaultSetupSelection()
        providerSetupPresented = true
        startProviderHealthPolling()
    }

    /// Dismiss without confirming (Skip for Now / sheet swipe-down). On a first-run launch the
    /// sheet simply returns next launch — the gate is the persisted default, not a "seen it" flag.
    func skipProviderSetup() {
        providerSetupPresented = false
        stopProviderHealthPolling()
    }

    /// Confirm the selected card as the default provider: activate it, persist it (which also
    /// retires the first-run auto-present), and dismiss. Only a `ready` card confirms — the sheet
    /// disables the button otherwise; this guard is the model-side belt.
    func confirmDefaultProvider() {
        guard let id = selectedSetupProviderID,
              displayedProviderHealth(id)?.status == .ready,
              setActiveProvider(id) else { return }
        defaultProviderID = id
        persistAppState()
        status = "default provider: \(id)"
        providerSetupPresented = false
        stopProviderHealthPolling()
    }

    /// Select a card (radio). Reserved statuses aside, every card is selectable — Confirm, not
    /// selection, is where readiness gates.
    func selectSetupProvider(_ id: String) {
        guard SZProviderRegistry.shared.provider(id: id) != nil else { return }
        selectedSetupProviderID = id
    }

    /// Default-selection heuristic: keep a valid current
    /// selection → the active provider if ready → the first ready provider → the first provider.
    private func defaultSetupSelection() -> String? {
        let ids = SZProviderRegistry.shared.providers.map(\.id)
        if let current = selectedSetupProviderID, ids.contains(current) { return current }
        if displayedProviderHealth(activeProviderID)?.status == .ready { return activeProviderID }
        return ids.first { displayedProviderHealth($0)?.status == .ready } ?? ids.first
    }

    // MARK: - Health refresh (cheap tiers — token-free)

    /// One install+auth pass over all providers, concurrently. Safe anywhere: launch, Refresh,
    /// the poll loop. Never probes.
    func refreshProviderHealthOnce() async {
        let reports = await withTaskGroup(of: SZProviderHealthReport.self) { group in
            for provider in SZProviderRegistry.shared.providers {
                group.addTask { await provider.healthReport() }
            }
            var collected: [SZProviderHealthReport] = []
            for await report in group { collected.append(report) }
            return collected
        }
        for report in reports {
            // A cheap-status TRANSITION drops the sticky probe verdict — the world changed
            // (install landed, login landed/expired), so the deeper truth must be re-earned.
            // This is also what re-arms the first-run auto-probe, bounding token spend by
            // user-visible state changes, never by the poll timer.
            if providerHealth[report.providerID]?.status != report.status {
                providerProbes[report.providerID] = nil
            }
            providerHealth[report.providerID] = report
        }
    }

    /// While the sheet is open: re-check every 3s (cheap tiers only) + first-run auto-probe.
    func startProviderHealthPolling() {
        guard providerHealthPollTask == nil else { return }
        providerHealthPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshProviderHealthOnce()
                self.autoProbeProvidersIfFirstRun()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopProviderHealthPolling() {
        providerHealthPollTask?.cancel()
        providerHealthPollTask = nil
    }

    // MARK: - Probe (tier 3 — the only token-coster)

    /// First-run flow only (no confirmed default): probe each provider that passes the cheap
    /// tiers and holds no probe verdict. A held verdict — pass or fail — blocks re-probing until
    /// the cheap status transitions, so this fires at most once per provider per state change.
    func autoProbeProvidersIfFirstRun() {
        guard defaultProviderID == nil else { return }
        for provider in SZProviderRegistry.shared.providers
        where providerHealth[provider.id]?.status == .ready && providerProbes[provider.id] == nil {
            runProviderProbe(provider.id)
        }
    }

    /// One real one-shot prompt through the provider's launch path (the per-card Test button and
    /// the first-run auto-probe above).
    func runProviderProbe(_ id: String) {
        guard let provider = SZProviderRegistry.shared.provider(id: id),
              !probingProviders.contains(id) else { return }
        probingProviders.insert(id)
        Task { @MainActor in
            let report = await provider.healthProbe()
            probingProviders.remove(id)
            providerProbes[id] = report
        }
    }

    // MARK: - Merged truth + pre-flights

    /// The status the UI and the pre-flights act on: a cheap-tier regression (missing / logged
    /// out / failing) always wins — it is the world as of seconds ago; otherwise a held probe
    /// verdict beats a bare cheap `ready` (deeper truth); otherwise the cheap report.
    func displayedProviderHealth(_ id: String) -> SZProviderHealthReport? {
        guard let cheap = providerHealth[id] else { return providerProbes[id] }
        if cheap.status != .ready { return cheap }
        return providerProbes[id] ?? cheap
    }

    /// Pre-flight for NEW work (a run, a first-turn chat). Unknown health — no pass finished
    /// yet — stays permissive: a fluke must never block what worked yesterday; the CLI's own
    /// failure still surfaces downstream.
    func isProviderReadyForNewWork(_ id: String) -> Bool {
        displayedProviderHealth(id).map { $0.status == .ready } ?? true
    }

    /// Refuse-and-point — the visible "no provider" surface (roadmap Task 2): a status line that
    /// names the reason, plus the sheet with the remedy on the card. Callers still refuse the
    /// work themselves. Default = the active provider (what the pre-flights gate); a mid-turn
    /// death passes the provider the turn actually ran on — a chat resume continues on the
    /// session's provider, not necessarily the active one.
    func surfaceProviderNotReady(_ providerID: String? = nil) {
        let id = providerID ?? activeProviderID
        let message = displayedProviderHealth(id)?.message ?? "set up Agent Providers"
        status = "\(id) not ready — \(message)"
        presentProviderSetup()
    }

    /// Classify a FAILED turn after the fact — the mid-turn counterpart of the pre-flights,
    /// which only cover a turn's START: a CLI that dies mid-turn comes back as
    /// a bare non-zero exit with no message, not a thrown error. Re-runs the cheap health tiers
    /// and, when the turn's provider is no longer ready, opens the Agent Providers sheet and
    /// returns the actionable line for the caller's transcript. A signal death on a
    /// still-healthy provider gets honest copy but NO sheet — pointing a one-off kill at setup
    /// would be wrong advice. nil = ordinary agent failure; the caller keeps its own copy.
    /// The guards live here so every `deliver` caller applies the same rules: a user stop is a
    /// choice, not a death, and a timeout already has dedicated copy.
    func providerFailureDetail(result: SZAgentRunResult, provider: any SZProvider) async -> String? {
        guard result.outcome.failed, !result.process.timedOut, !Task.isCancelled else { return nil }
        await refreshProviderHealthOnce()
        if !isProviderReadyForNewWork(provider.id) {
            surfaceProviderNotReady(provider.id)
            var reason = displayedProviderHealth(provider.id)?.message ?? "its CLI is no longer available"
            if reason.hasSuffix(".") { reason.removeLast() }   // health messages end sentences; this one runs on
            // Durable copy — no "(just opened)" style claims about transient UI state: this line
            // outlives the moment in transcripts and the error-pill popover.
            return "\(provider.id) stopped working mid-turn — \(reason). Fix it in Agent Providers, then try again."
        }
        if let signal = result.process.uncaughtSignal {
            return "the \(provider.id) process died mid-turn (killed or crashed, signal \(signal)) — its CLI still checks out healthy, so this looks one-off; try again"
        }
        return nil
    }

    // MARK: - Remedies

    /// The authNeeded remedy: open Terminal running the provider's interactive login. Auth is
    /// interactive by design — the app never attempts it headless. Mechanism: a `.command` file
    /// handed to Terminal.app directly (no osascript — that's an Apple-Events automation TCC
    /// prompt inside the must-never-fail screen; explicit Terminal also sidesteps a remapped
    /// `.command` default handler). PATH is exported so the CLI resolves exactly the way the app
    /// itself launches it (incl. the Codex.app bundled binary).
    func openProviderLoginTerminal(_ id: String) {
        guard let provider = SZProviderRegistry.shared.provider(id: id) else { return }
        let script = """
        #!/bin/zsh
        export PATH="\(SZAgentEnvironment.searchPath())"
        \(provider.loginCommand)
        """
        do {
            let dir = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "SubjectiveZero")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appending(path: "sz-login-\(id).command")
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            let terminal = URL(filePath: "/System/Applications/Utilities/Terminal.app")
            if FileManager.default.fileExists(atPath: terminal.path) {
                NSWorkspace.shared.open([file], withApplicationAt: terminal,
                                        configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(file)   // pre-Catalina layout / exotic setups
            }
        } catch {
            status = "could not open Terminal: \(error.localizedDescription)"
        }
    }

    /// The missingCLI remedy's Copy button target (the card shows the command inline too).
    func providerInstallCommand(_ id: String) -> String? {
        SZProviderRegistry.shared.provider(id: id)?.installCommand
    }

    // MARK: - SZAI → SZUI mapping (SZUI can't import SZAI; it gets dumb value structs)

    /// The sheet's cards, mapped from the merged health truth.
    var providerSetupCards: [SZProviderSetupCard] {
        SZProviderRegistry.shared.providers.map { provider in
            let report = displayedProviderHealth(provider.id)
            let readiness = Self.cardReadiness(report)
            return SZProviderSetupCard(
                id: provider.id,
                displayName: provider.displayName,
                statusLabel: Self.cardStatusLabel(readiness),
                message: report.map { r in r.version.map { "\(r.message)  ·  \($0)" } ?? r.message }
                    ?? "Checking…",
                readiness: readiness,
                detail: report.flatMap(Self.diagnosticsDetail),
                cliPath: report?.cliPath,
                installCommand: provider.installCommand,
                isTesting: probingProviders.contains(provider.id),
                isSelectable: readiness != .unavailable,
                isConfirmable: readiness == .ready || readiness == .verified)
        }
    }

    private static func cardReadiness(_ report: SZProviderHealthReport?) -> SZProviderSetupCard.Readiness {
        guard let report else { return .checking }
        switch report.status {
        case .ready: return report.probeVerified ? .verified : .ready
        case .missingCLI: return .needsInstall
        case .authNeeded: return .needsLogin
        case .healthFailed: return .failed
        case .invalidConfig, .unsupported: return .unavailable
        }
    }

    private static func cardStatusLabel(_ readiness: SZProviderSetupCard.Readiness) -> String {
        switch readiness {
        case .checking: "Checking…"
        case .ready: "Ready"
        case .verified: "Verified"
        case .needsInstall: "Not Installed"
        case .needsLogin: "Login Needed"
        case .failed: "Failing"
        case .unavailable: "Unavailable"
        }
    }

    /// The failing card's Details popover: each tier's receipts, tail-first readable.
    private static func diagnosticsDetail(_ report: SZProviderHealthReport) -> String? {
        guard !report.diagnostics.isEmpty else { return nil }
        return report.diagnostics.map { diag in
            var lines = ["[\(diag.tier.rawValue)] \(diag.attemptedCommand.joined(separator: " "))"]
            lines.append("exit: \(diag.exitCode.map(String.init) ?? "never launched")\(diag.timedOut ? " (timed out)" : "")")
            if let excerpt = diag.outputExcerpt { lines.append(excerpt) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// The sheet's Setup Guide button — the canonical agent-readable guide, published from
    /// docs/APP_SETUP.md to the website by the release pipeline.
    func openProviderSetupGuide() {
        NSWorkspace.shared.open(URL(string: "https://sxp.studio/apps/subjectivezero/app-setup.md")!)
    }
}
