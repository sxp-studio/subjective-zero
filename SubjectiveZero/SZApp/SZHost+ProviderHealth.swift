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
        seedProviderModelCatalogs()
        // A restored active provider that is user-disabled (possible only via a hand-edited
        // app-state.json — the mutator moves the active elsewhere first) clamps to the first
        // enabled one, BEFORE anything runs on it.
        if disabledProviderIDs.contains(activeProviderID),
           let fallback = enabledProviders.first {
            setActiveProvider(fallback.id)
        }
        Task { @MainActor in
            await refreshProviderHealthOnce()
            autoPresentProviderSetupIfNeeded()
        }
    }

    /// Hand each dynamic-catalog provider its persisted snapshot (no-op for static providers), so
    /// the model picker serves last-known truth before — and without — any live fetch.
    func seedProviderModelCatalogs() {
        for provider in SZProviderRegistry.shared.providers {
            if let catalog = providerModelCatalogs[provider.id] {
                provider.seedModelCatalog(catalog)
            }
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

    /// The escape hatch a failing card offers: the first enabled, displayed-ready provider that
    /// isn't `id` (registry order). nil = no ready alternative — the card's button hides.
    func fallbackProvider(insteadOf id: String) -> (any SZProvider)? {
        enabledProviders.first { $0.id != id && displayedProviderHealth($0.id)?.status == .ready }
    }

    /// A failing card's "Use X Instead": adopt the fallback as the default — Confirm's shape,
    /// aimed by the failing card instead of the radio. Setting a default also retires the
    /// first-run auto-present for good, which is what ends the launch-time nag. The failing
    /// provider stays enabled (still visible here, still recoverable) — disabling is a separate,
    /// deliberate act.
    func adoptFallbackProvider(insteadOf id: String) {
        guard let fallback = fallbackProvider(insteadOf: id),
              setActiveProvider(fallback.id) else { return }
        defaultProviderID = fallback.id
        persistAppState()
        status = "default provider: \(fallback.id) (\(id) left as-is)"
        providerSetupPresented = false
        stopProviderHealthPolling()
    }

    /// The card's Disable/Enable. Disable never strands work: the last enabled provider refuses,
    /// and disabling the ACTIVE provider first moves active to the fallback — which itself
    /// refuses while agents are busy (`setActiveProvider`'s guard), so a live run is never cut
    /// over or left on a disabled provider. Enable drops the stale verdicts so the card shows
    /// "Checking…" and then fresh truth from the next pass.
    @discardableResult
    func setProviderEnabled(_ id: String, _ enabled: Bool) -> Bool {
        guard SZProviderRegistry.shared.provider(id: id) != nil else { return false }
        if enabled {
            guard disabledProviderIDs.remove(id) != nil else { return true }   // already enabled
            providerHealth[id] = nil
            providerProbes[id] = nil
            persistAppState()
            status = "\(id) enabled"
            Task { @MainActor in await refreshProviderHealthOnce() }
            return true
        }
        guard !disabledProviderIDs.contains(id) else { return true }   // already disabled
        guard enabledProviders.contains(where: { $0.id != id }) else {
            status = "cannot disable \(id) — it is the last enabled provider"
            return false
        }
        if id == activeProviderID {
            let target = fallbackProvider(insteadOf: id) ?? enabledProviders.first { $0.id != id }
            guard let target, setActiveProvider(target.id) else {
                status = "cannot disable \(id) while agents are running"
                return false
            }
        }
        disabledProviderIDs.insert(id)
        providerHealth[id] = nil
        providerProbes[id] = nil
        persistAppState()
        status = "\(id) disabled"
        return true
    }

    /// Default-selection heuristic over the ENABLED providers (a disabled card is never the
    /// radio): keep a valid current selection → the active provider if ready → the first ready
    /// provider → the first enabled provider.
    private func defaultSetupSelection() -> String? {
        let ids = enabledProviders.map(\.id)
        if let current = selectedSetupProviderID, ids.contains(current) { return current }
        if displayedProviderHealth(activeProviderID)?.status == .ready { return activeProviderID }
        return ids.first { displayedProviderHealth($0)?.status == .ready } ?? ids.first
    }

    // MARK: - Health refresh (cheap tiers — token-free)

    /// Registry order minus user-disabled providers — the set health checks, probes, the picker's
    /// selectable rows, and the pre-flights operate on. The setup sheet still shows every provider
    /// (a disabled card is the re-enable affordance). Never empty: `setProviderEnabled` refuses to
    /// disable the last one.
    var enabledProviders: [any SZProvider] {
        SZProviderRegistry.shared.providers.filter { !disabledProviderIDs.contains($0.id) }
    }

    /// One install+auth pass over the enabled providers, concurrently (a disabled provider spawns
    /// nothing). Safe anywhere: launch, Refresh, the poll loop. Never probes.
    func refreshProviderHealthOnce() async {
        let reports = await withTaskGroup(of: SZProviderHealthReport.self) { group in
            for provider in enabledProviders {
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
            let transitioned = providerHealth[report.providerID]?.status != report.status
            if transitioned {
                providerProbes[report.providerID] = nil
            }
            providerHealth[report.providerID] = report
            if report.status == .ready {
                refreshProviderModelCatalogIfNeeded(report.providerID, transitioned: transitioned)
            }
        }
    }

    /// Re-fetch a dynamic provider's model catalog when its cheap status just transitioned to
    /// ready (login/install landing is exactly when the served catalog changes), when it's ready
    /// but serving nothing (first launch, or a fetch that failed), or when the snapshot is a day
    /// old. Static-manifest providers no-op (their `refreshModelCatalog` returns nil, no spawn).
    /// A failed fetch keeps the last-known catalog — never clobber cache with a failure; the poll
    /// loop retries while the sheet is open, the next launch/transition retries after that.
    func refreshProviderModelCatalogIfNeeded(_ id: String, transitioned: Bool) {
        guard let provider = SZProviderRegistry.shared.provider(id: id),
              !catalogRefreshesInFlight.contains(id) else { return }
        let staleAfter: TimeInterval = 24 * 3600
        let stale = providerModelCatalogs[id].map { Date().timeIntervalSince($0.fetchedAt) > staleAfter } ?? false
        guard transitioned || stale || provider.models.isEmpty else { return }
        catalogRefreshesInFlight.insert(id)
        Task { @MainActor in
            defer { catalogRefreshesInFlight.remove(id) }
            guard let snapshot = try? await provider.refreshModelCatalog(runner: SZSystemProcessRunner())
            else { return }   // static provider (nil) or failed fetch — keep last-known
            providerModelCatalogs[id] = snapshot
            try? SZProviderCatalogIO.save(providerModelCatalogs)
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
        for provider in enabledProviders
        where providerHealth[provider.id]?.status == .ready && providerProbes[provider.id] == nil {
            runProviderProbe(provider.id)
        }
    }

    /// One real one-shot prompt through the provider's launch path (the per-card Test button and
    /// the first-run auto-probe above). Disabled providers refuse — their card hides Test, this
    /// guard covers any other route in.
    func runProviderProbe(_ id: String) {
        guard let provider = SZProviderRegistry.shared.provider(id: id),
              !disabledProviderIDs.contains(id),
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
    /// failure still surfaces downstream. A user-disabled provider is never ready — that's a
    /// choice, not a fluke.
    func isProviderReadyForNewWork(_ id: String) -> Bool {
        guard !disabledProviderIDs.contains(id) else { return false }
        return displayedProviderHealth(id).map { $0.status == .ready } ?? true
    }

    /// Refuse-and-point — the visible "no provider" surface (roadmap Task 2): a status line that
    /// names the reason, plus the sheet with the remedy on the card. Callers still refuse the
    /// work themselves. Default = the active provider (what the pre-flights gate); a mid-turn
    /// death passes the provider the turn actually ran on — a chat resume continues on the
    /// session's provider, not necessarily the active one.
    func surfaceProviderNotReady(_ providerID: String? = nil) {
        let id = providerID ?? activeProviderID
        // A disabled provider carries no health entry (checks skip it) — name the real reason.
        let message = disabledProviderIDs.contains(id)
            ? "disabled — enable it in Agent Providers"
            : displayedProviderHealth(id)?.message ?? "set up Agent Providers"
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

    /// The sheet's cards, mapped from the merged health truth. Every registry provider appears —
    /// including disabled ones, whose card (Enable) is the way back in.
    var providerSetupCards: [SZProviderSetupCard] {
        let canDisableAnother = enabledProviders.count > 1
        return SZProviderRegistry.shared.providers.map { provider in
            if disabledProviderIDs.contains(provider.id) {
                return SZProviderSetupCard(
                    id: provider.id,
                    displayName: provider.displayName,
                    statusLabel: Self.cardStatusLabel(.disabled),
                    message: "Disabled — skipped by health checks and unavailable for runs.",
                    readiness: .disabled,
                    installCommand: provider.installCommand,
                    isSelectable: false)
            }
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
                isConfirmable: readiness == .ready || readiness == .verified,
                fallbackName: readiness == .failed
                    ? fallbackProvider(insteadOf: provider.id)?.displayName : nil,
                canDisable: canDisableAnother)
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
        case .disabled: "Disabled"
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
