// SPDX-License-Identifier: AGPL-3.0-only
// SZHost+Links — community/support links opened from the HUD gear menu (Website, Discord, Feedback).
// Plain NSWorkspace.open calls; the destinations live in one private enum so they're easy to retarget.
// The website base mirrors the existing setup-guide URL (SZHost+ProviderHealth) — sxp.studio/apps/subjectivezero.
import AppKit

@MainActor
extension SZHost {
    private enum SZLinks {
        static let website = URL(string: "https://sxp.studio/apps/subjectivezero")!
        static let github = URL(string: "https://github.com/sxp-studio/subjective-zero")!
        static let discord = URL(string: "https://discord.gg/Y3JZxpXExs")!
        static let feedbackEmail = "subz@sxp.studio"
        // The download page carries the telemetry disclaimer (what's sent, with a sample payload).
        static let privacyInfo = URL(string: "https://sxp.studio/apps/subjectivezero/download")!
    }

    /// Open the SubjectiveZero website in the default browser.
    func openWebsite() { NSWorkspace.shared.open(SZLinks.website) }

    /// Open the SubjectiveZero source repository on GitHub.
    func openGitHub() { NSWorkspace.shared.open(SZLinks.github) }

    /// Open the community Discord invite in the default browser.
    func joinDiscord() { NSWorkspace.shared.open(SZLinks.discord) }

    /// Open the telemetry disclosure (the welcome screen's ⓘ beside "Share anonymous usage data").
    func openPrivacyInfo() { NSWorkspace.shared.open(SZLinks.privacyInfo) }

    /// Compose a feedback email (default mail client) with a pre-filled subject.
    func sendFeedbackEmail() {
        let subject = "SubjectiveZero Feedback"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "mailto:\(SZLinks.feedbackEmail)?subject=\(subject)") else { return }
        NSWorkspace.shared.open(url)
    }
}
