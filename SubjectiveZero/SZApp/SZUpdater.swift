// SPDX-License-Identifier: AGPL-3.0-only
// Sparkle auto-update — the "Check for Updates…" app-menu item.
//
// The updater surface: SZApp owns an SPUStandardUpdaterController
// (started at init; SUEnableAutomaticChecks in Info.plist covers the scheduled checks, so
// there is no first-run permission prompt) and the menu item lives in a
// CommandGroup(after: .appInfo) hosting SZCheckForUpdatesView. SZUpdaterState, the one updater
// delegate, runs a silent check once per launch (Sparkle's own schedule only fires every 24 hours)
// and remembers an update the user was prompted about and dismissed, so the home screen can show
// a green "Update available" pill.
// No user-driver delegate — stock Sparkle UI throughout; delta updates stay disabled feed-side.
import Combine
import Observation
import Sparkle
import SwiftUI

/// The updater delegate: tracks a found-and-dismissed update for the home screen's green pill.
/// Sparkle calls its delegate on the main thread; the `nonisolated` hops are that promise, spelled.
@Observable @MainActor
final class SZUpdaterState: NSObject, SPUUpdaterDelegate {
    /// The version the user was prompted about and dismissed, still uninstalled. Nil until then;
    /// cleared when a later check finds nothing or the user skips the version.
    private(set) var dismissedUpdateVersion: String?
    /// The update the running cycle found; promoted to `dismissedUpdateVersion` once the cycle ends.
    @ObservationIgnored private var foundVersion: String?
    /// The once-per-launch check ran (or Sparkle's own overdue check stood in for it).
    @ObservationIgnored private var launchCheckDone = false

    /// Sparkle is free for the first time this launch: it refuses any check until its startup probe
    /// (is an installer already running?) answers, which takes tens of seconds, and this is the
    /// callback right after. Run the launch check then, silent unless a newer build exists (Sparkle's
    /// own schedule waits out its 24-hour interval). Deferred a hop so Sparkle finishes scheduling.
    /// When the schedule is overdue Sparkle checks immediately instead and never calls this first.
    nonisolated func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        MainActor.assumeIsolated {
            guard !launchCheckDone else { return }
            launchCheckDone = true
            Task { @MainActor in
                guard updater.canCheckForUpdates else { return }
                updater.checkForUpdatesInBackground()
            }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { foundVersion = item.displayVersionString }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        MainActor.assumeIsolated {
            foundVersion = nil
            dismissedUpdateVersion = nil
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                             forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        guard choice == .skip else { return }   // a skipped version is not one to keep offering
        MainActor.assumeIsolated {
            foundVersion = nil
            dismissedUpdateVersion = nil
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated {
            launchCheckDone = true
            if let foundVersion { dismissedUpdateVersion = foundVersion }
            foundVersion = nil
        }
    }
}

/// Mirrors Sparkle's `canCheckForUpdates` (false mid-update) into SwiftUI so the menu
/// item can disable itself — the KVO publisher is the Sparkle-documented bridge.
@MainActor
final class SZCheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct SZCheckForUpdatesView: View {
    @ObservedObject private var viewModel: SZCheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = SZCheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
