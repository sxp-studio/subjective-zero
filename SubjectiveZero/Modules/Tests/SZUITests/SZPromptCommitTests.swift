// SPDX-License-Identifier: AGPL-3.0-only
// The blur-commit guard on a prompt card (SZPromptNodeView). A lock arriving mid-edit flips
// `.disabled` on the focused field, which resigns first responder on its own — so an unconditional
// blur-commit made the ACT OF LOCKING write the user's stale text onto a node an agent had just
// claimed. These pin the guard that drops such an edit before it reaches the host funnel.
import Testing
@testable import SZUI

@Suite struct SZPromptCommitTests {

    /// The ordinary case: the user clicks away from an unlocked card and their edit is kept.
    @Test func unlockedBlurCommits() {
        #expect(SZPromptNodeView.shouldCommitOnBlur(locked: false))
    }

    /// The regression. A run claiming the node (or a chat turn landing on it) locks the card while the
    /// field is focused; the induced blur must NOT write. The host's `updateNodeContent` fence would
    /// refuse a user-origin write here anyway — this keeps the edit from travelling that far, so the
    /// user sees a clean revert instead of a refusal status for something they never chose to commit.
    @Test func lockedBlurDropsTheEdit() {
        #expect(!SZPromptNodeView.shouldCommitOnBlur(locked: true))
    }

    /// The live-report path that closes the lost-edit race: while the user is actively typing into an
    /// unlocked field, each keystroke is reported to the host so a run started mid-edit can flush it
    /// before it locks the node. The blur-only commit alone is what dropped "make the input texture glow".
    @Test func activeUnlockedEditReportsLive() {
        #expect(SZPromptNodeView.shouldReportLiveEdit(editing: true, focused: true, locked: false))
    }

    /// It must NOT report otherwise: a locked node (would be a write behind the fence), or a non-active
    /// field — the programmatic `text =` seed/revert both fire while `focused` is false and must not be
    /// mistaken for a keystroke.
    @Test func onlyAnActiveUnlockedEditReportsLive() {
        #expect(!SZPromptNodeView.shouldReportLiveEdit(editing: true, focused: true, locked: true))
        #expect(!SZPromptNodeView.shouldReportLiveEdit(editing: true, focused: false, locked: false))
        #expect(!SZPromptNodeView.shouldReportLiveEdit(editing: false, focused: true, locked: false))
    }
}
