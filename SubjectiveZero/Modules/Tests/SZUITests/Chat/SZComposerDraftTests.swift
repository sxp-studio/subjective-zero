// SPDX-License-Identifier: AGPL-3.0-only
// SZComposerDraft — canonical/plain forms and the leading-@project strip (redundant inside the
// Project tab; routing stays correct because the Project tab defaults to the Director).
import Testing
@testable import SZUI
import SZCore

private let blurID = SZNodeID(uuidString: "11111111-1111-1111-1111-111111111111")!

@Test func canonicalAndPlainForms() {
    let draft = SZComposerDraft(segments: [
        .mention(.node(blurID), display: "Blur"), .text(" soften it"),
    ])
    #expect(draft.canonicalText == "@[Blur](node:\(blurID.uuidString)) soften it")
    #expect(draft.plainText == "@Blur soften it")
    #expect(!draft.isEmpty)
}

@Test func stripLeadingProjectRemovesMentionAndSpace() {
    let draft = SZComposerDraft(segments: [.mention(.project, display: "project"),
                                           .text(" implement the 3 pending nodes")])
    let stripped = draft.strippingLeadingProjectMention()
    #expect(stripped.segments == [.text("implement the 3 pending nodes")])
}

@Test func stripLeadingProjectDropsEmptyTextRun() {
    let draft = SZComposerDraft(segments: [.mention(.project, display: "project"), .text(" ")])
    #expect(draft.strippingLeadingProjectMention().segments.isEmpty)
}

@Test func stripLeavesNonLeadingProjectAndOtherMentions() {
    // @all leads → untouched (it carries broadcast meaning, not "the project").
    let all = SZComposerDraft(segments: [.mention(.all, display: "all"), .text(" hi")])
    #expect(all.strippingLeadingProjectMention().segments == all.segments)
    // A merge draft: leading @project stripped, the node references kept.
    let merge = SZComposerDraft(segments: [
        .mention(.project, display: "project"), .text(" merge "),
        .mention(.node(blurID), display: "Blur")])
    #expect(merge.strippingLeadingProjectMention().segments == [
        .text("merge "), .mention(.node(blurID), display: "Blur")])
}
