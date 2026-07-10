// SPDX-License-Identifier: AGPL-3.0-only
// SZHost+Welcome — the welcome/home window's launch gating.
//
// The home overlay is the FIRST view of every cold launch, including the very first one: it is where
// a new user meets the app. Provider setup is not skipped, only deferred — it auto-presents on the way
// OUT of welcome, once a project is live (SZHost+ProviderHealth's autoPresentProviderSetupIfNeeded),
// so the two surfaces still never overlap. Reopen the window any time from Help ▸ Welcome. Persisted
// state (`showWelcomeAtStartup`) rides the same app-state.json single-writer (persistAppState) as the
// other prefs.
import Foundation

@MainActor
extension SZHost {
    /// Launch routing decision: is the welcome/home surface the FIRST view this cold launch (so no
    /// project opens yet — nothing touches the camera/mic until the user picks one)? Only when enabled,
    /// and never when launched by opening a `.subz` (the user already has intent). A first run routes
    /// here too — the provider sheet follows on the way out rather than pre-empting the greeting.
    func shouldRouteToWelcomeOnLaunch(launchedWithFile: Bool) -> Bool {
        showWelcomeAtStartup && !launchedWithFile
    }

    /// Help ▸ Welcome / gear ▸ Welcome — return to the home screen from the editor (guarded against the
    /// provider sheet so the two never stack). Going Home means leaving the current work, so an unsaved
    /// UNTITLED project is rescued NOW (Save… / Discard) rather than surprising the user with the prompt
    /// at quit; Cancel keeps them in the editor.
    func presentWelcome() {
        guard !providerSetupPresented else { return }
        guard isUntitledProject, !isBusyForProjectOps else { welcomePresented = true; return }
        Task { @MainActor in
            if await confirmSaveOrDiscardIfUnsaved(actionName: "returning to Home") {
                welcomePresented = true
            }
        }
    }

    /// Leave the home screen for the workspace (Esc / the window's implicit "continue"). If launch
    /// routed here, no project is loaded yet — open the last (or a fresh sample) one NOW; that
    /// `switchProject` is what finally requests the camera, on the user's action rather than at launch.
    /// If a project is already live (manual reopen via Help ▸ Welcome), just hide.
    func continueFromWelcome() {
        guard welcomePresented else { return }
        // `loadedProjectURL == nil` covers both a launch with nothing opened yet AND an untitled
        // project just Discarded on the way to Home — in either case open the last/sample project.
        if loadedProjectURL == nil {
            Task { await openInitialProject() }   // switchProject dismisses welcome on success
        } else {
            welcomePresented = false
        }
    }

    /// The "Show this window at startup" checkbox.
    func setShowWelcomeAtStartup(_ on: Bool) {
        guard showWelcomeAtStartup != on else { return }
        showWelcomeAtStartup = on
        persistAppState()
    }
}
