// SPDX-License-Identifier: AGPL-3.0-only
// Apple's developer tools on this Mac: probed at launch before anything can pick a project, shown
// as a requirement of the Mac target where targets are picked (the New Project sheet, the Target
// Platform pane), re-probed every few seconds while a sheet shows it. The chat and run pre-flight
// and the tools-landed rebuild live here; the other refusals (project open, retarget, agent compile
// check, card mounts) sit at their call sites and read `toolchainMissing`. Browser projects never
// need the tools: their nodes are JavaScript and the shipped agent steps are prebuilt.
import AppKit
import Foundation
import SZCore
import SZRuntime
import SZUI

extension SZHost {
    /// The Terminal line that does what the Install button does.
    static let developerToolsCommand = "xcode-select --install"
    /// The refusal for a build on a Mac project without the tools.
    static let toolsMissingMessage =
        "Building for this Mac needs Apple's developer tools. Install them in Settings, or switch the project to run in a browser."

    var toolchainMissing: Bool { toolchainAvailability == .missing }

    /// What the Mac target still needs, for the sheets; nil when the tools are present.
    var nativeRequirement: SZTargetRequirement? {
        guard toolchainMissing else { return nil }
        return SZTargetRequirement(
            title: "Needs Apple's developer tools",
            message: "Mac projects are compiled with Apple's Xcode Command Line Tools, which are not installed on this Mac. Install opens Apple's installer. This sheet checks again on its own.",
            command: Self.developerToolsCommand)
    }

    /// Probe off the main thread and publish. Missing-to-ready rebuilds a Mac project that waited
    /// for the tools. The launch probe's funnel event fires from `start()`, once telemetry is up.
    func refreshToolchainAvailability() async {
        let before = toolchainAvailability
        let now = await Task.detached(priority: .userInitiated) { SZToolchain.availability() }.value
        toolchainAvailability = now
        guard now != .missing, before == .missing else { return }
        if toolchainPollTask != nil {
            stopToolchainPolling()
            status = "Apple's developer tools installed"
        }
        await toolchainBecameAvailable()
    }

    /// The Install button: Apple's installer, then the re-check sees it land.
    func installDeveloperTools() {
        SZToolchain.openInstallDialog()
        status = "Apple's developer tools: install dialog opened"
        startToolchainPolling()
    }

    /// The New Project sheet is up: the browser library downloads now so the first picture does
    /// not wait on it, and the requirement re-checks while it stands.
    func prepareTargetPick() {
        Task.detached(priority: .utility) { _ = try? await SZWebLibraryStore.ensure(SZProjectWeb.currentThreeVersion) }
        startToolchainPolling()
    }

    /// Re-probe every 3 s while a sheet shows the requirement, until the tools land.
    func startToolchainPolling() {
        guard toolchainMissing, toolchainPollTask == nil else { return }
        toolchainPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                await self.refreshToolchainAvailability()
                if !self.toolchainMissing { return }
            }
        }
    }

    func stopToolchainPolling() {
        toolchainPollTask?.cancel()
        toolchainPollTask = nil
    }

    /// The chat and run pre-flight: nil when the work may proceed, else the refusal line, with
    /// the requirement opened on Target Platform so the fix and the browser switch are one click away.
    func toolchainRefusal() -> String? {
        guard projectTarget == .native, toolchainMissing else { return nil }
        status = "this Mac needs Apple's developer tools"
        presentTargetPlatformSettings()
        return Self.toolsMissingMessage
    }

    /// The tools landed: a Mac project mounted with nothing built goes through the same prepare,
    /// commit and mount as a platform switch, busy for the duration like that switch, so no open
    /// or turn interleaves with the compile.
    private func toolchainBecameAvailable() async {
        guard nativeProjectAwaitingTools, let url = loadedProjectURL, let project = store.project,
              !isBusyForProjectSwitch else { return }
        nativeProjectAwaitingTools = false
        openingProject = project.name
        defer { openingProject = nil }
        await remountBackend(at: url)
        rewatchNodeSources()
        classifyRebuildsAfterLoad()
        cardHost.recompileAll()
    }
}
