// SPDX-License-Identifier: AGPL-3.0-only
// What a successful promote leaves behind. A promote proves "this source compiled against this contract"
// and nothing about the PROMPT — so a re-brief that landed after the agent was dispatched has to survive it,
// or the node ships built against the old intent while reading clean and current.
//
// Before this rule existed, `promoteStagedNode` cleared the flag unconditionally and a mid-run prompt edit
// (the Director's `ui_update_node` re-brief) vanished without trace.
import Testing
@testable import SZCore

@Suite struct SZRebuildAfterPromoteTests {

    /// The ordinary run: the agent built exactly the intent it was handed. Nothing outstanding.
    @Test func unchangedPromptDischargesTheFlag() {
        #expect(SZRebuildReason.afterPromote(
            existing: .contractChanged,
            dispatchedPrompt: .some("make it wobble"), currentPrompt: "make it wobble") == nil)
    }

    /// THE REGRESSION. The prompt moved while the agent was mid-implementation, so the code that just
    /// compiled implements the OLD intent. The node must stay dirty.
    @Test func promptMovedUnderTheAgentKeepsItDirty() {
        #expect(SZRebuildReason.afterPromote(
            existing: nil,
            dispatchedPrompt: .some("make it wobble"),
            currentPrompt: "make it wobble, and tint it green") == .intentChanged)
    }

    /// The rebuild-run sub-case, which comparing FLAGS would miss entirely: the node already carried
    /// `.contractChanged`, so `updateNode`'s "never downgrade a reason already raised" guard suppressed the
    /// `.intentChanged` raise. Only the prompt text records that anything happened.
    @Test func suppressedRaiseIsStillCaught() {
        #expect(SZRebuildReason.afterPromote(
            existing: .contractChanged,
            dispatchedPrompt: .some("draw a circle"), currentPrompt: "draw a square") == .intentChanged)
    }

    /// `.sourceMismatch` is the stronger claim and survives untouched — a promote can reach it (the port
    /// audit only runs when a staged contract exists), and softening a real fault into "needs a rebuild"
    /// would lose the diagnosis. Holds whether or not the prompt also moved.
    @Test func sourceMismatchIsNeverDowngraded() {
        #expect(SZRebuildReason.afterPromote(
            existing: .sourceMismatch,
            dispatchedPrompt: .some("draw a circle"), currentPrompt: "draw a square") == .sourceMismatch)
        #expect(SZRebuildReason.afterPromote(
            existing: .sourceMismatch,
            dispatchedPrompt: .some("draw a circle"), currentPrompt: "draw a circle") == .sourceMismatch)
        #expect(SZRebuildReason.afterPromote(
            existing: .sourceMismatch, dispatchedPrompt: nil, currentPrompt: "x") == .sourceMismatch)
    }

    /// No dispatch record — promoted outside a run (a node-scoped chat turn, a library instantiate).
    /// Nothing to compare against, so the pre-existing behaviour stands and the flag clears.
    @Test func noDispatchRecordClearsAsBefore() {
        #expect(SZRebuildReason.afterPromote(
            existing: .contractChanged, dispatchedPrompt: nil, currentPrompt: "anything at all") == nil)
    }

    /// A node dispatched with no prompt at all (a contract-first drawn node) is distinguishable from one
    /// that was never dispatched — `String??` carries that difference, and both nil layers must behave.
    @Test func dispatchedWithNoPromptIsNotTheSameAsNoRecord() {
        #expect(SZRebuildReason.afterPromote(
            existing: nil, dispatchedPrompt: .some(nil), currentPrompt: nil) == nil)
        #expect(SZRebuildReason.afterPromote(
            existing: nil, dispatchedPrompt: .some(nil),
            currentPrompt: "someone typed one mid-run") == .intentChanged)
    }

    /// The layer the cases above ASSUME: they hand-build `.some(nil)`, but production reads through a real
    /// `[SZNodeID: String?]`, where the difference between "recorded as no prompt" and "no record" is a
    /// Swift subtlety — assigning a nil *expression* stores `.some(nil)` while assigning a nil *literal*
    /// REMOVES the key. If that ever inverts, promote silently reverts to clearing every flag.
    @Test func dictionaryRoundTripPreservesTheTwoNilLayers() {
        var records: [SZNodeID: String?] = [:]
        let briefedWithNone = SZNodeID(), briefedWithText = SZNodeID(), neverBriefed = SZNodeID()

        let absentPrompt: String? = nil
        records[briefedWithNone] = absentPrompt        // nil EXPRESSION → stores .some(nil)
        records[briefedWithText] = "draw a circle"

        #expect(records.keys.contains(briefedWithNone))
        #expect(!records.keys.contains(neverBriefed))
        // The distinction survives into the decision: a briefed-with-nothing node that gained a prompt is
        // dirty; a never-briefed one clears.
        #expect(SZRebuildReason.afterPromote(existing: nil, dispatchedPrompt: records[briefedWithNone],
                                             currentPrompt: "typed later") == .intentChanged)
        #expect(SZRebuildReason.afterPromote(existing: nil, dispatchedPrompt: records[neverBriefed],
                                             currentPrompt: "typed later") == nil)

        // And the run-end filter (`dispatchPrompts.filter { hiddenPieces.contains($0.key) }`) must not
        // collapse a .some(nil) value on its way through.
        let kept = records.filter { $0.key == briefedWithNone }
        #expect(kept.keys.contains(briefedWithNone))
        #expect(SZRebuildReason.afterPromote(existing: nil, dispatchedPrompt: kept[briefedWithNone],
                                             currentPrompt: "typed later") == .intentChanged)

        records[briefedWithText] = nil                 // nil LITERAL → removes the key
        #expect(!records.keys.contains(briefedWithText))
    }
}
