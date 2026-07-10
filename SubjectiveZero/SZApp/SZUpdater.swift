// SPDX-License-Identifier: AGPL-3.0-only
// Sparkle auto-update — the "Check for Updates…" app-menu item.
//
// The updater surface: SZApp owns an SPUStandardUpdaterController
// (started at init; SUEnableAutomaticChecks in Info.plist covers the scheduled checks, so
// there is no first-run permission prompt) and the menu item lives in a
// CommandGroup(after: .appInfo) hosting SZCheckForUpdatesView. No updater/user-driver
// delegates — stock Sparkle behavior throughout; delta updates stay disabled feed-side.
import Combine
import Sparkle
import SwiftUI

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
