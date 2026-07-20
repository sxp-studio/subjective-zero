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
}
