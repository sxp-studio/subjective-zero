// SPDX-License-Identifier: AGPL-3.0-only
// `SZNode.rebuildReason` is DERIVED from the build stamp, never stored. A promote writes the stamp from what
// the compile consumed (the merged surface, the brief the agent was given); every read since compares the
// node's current contract + prompt against it. So a promote proves "this source compiled against this
// contract" and nothing about the PROMPT — a re-brief that landed after dispatch reads `.intentChanged` — and
// an edit that is undone heals by construction, because there is no flag left behind to go stale.
import Foundation
import Testing
@testable import SZCore

@Suite struct SZRebuildAfterPromoteTests {

    private static let surfaceA: Set<SZNodeContract.PortSignature> =
        [.init(direction: .input, name: "input", type: .texture), .init(direction: .output, name: "output", type: .texture)]
    private static let surfaceB: Set<SZNodeContract.PortSignature> =
        surfaceA.union([.init(direction: .input, name: "audioDrive", type: .float)])

    private static func contract(_ surface: Set<SZNodeContract.PortSignature>) -> SZNodeContract {
        SZNodeContract(title: "N", sfSymbol: "circle", summary: "",
                       inputs: surface.filter { $0.direction == .input }.map { SZPort(name: $0.name, type: $0.type) },
                       outputs: surface.filter { $0.direction == .output }.map { SZPort(name: $0.name, type: $0.type) })
    }

    /// A built node as a promote leaves it: `stampSurface`/`stampPrompt` is what the compile consumed,
    /// `surface`/`prompt` is the node NOW.
    private static func built(surface: Set<SZNodeContract.PortSignature>, prompt: String?,
                              stampSurface: Set<SZNodeContract.PortSignature>, stampPrompt: String?) -> SZNode {
        SZNode(kind: .generated, title: "N", prompt: prompt, contract: contract(surface), position: SZPoint(x: 0, y: 0),
               buildStamp: SZBuildStamp(portSurface: stampSurface, prompt: stampPrompt))
    }

    /// The promote rule, as `promoteStagedNode` applies it: the stamp's prompt is the DISPATCHED brief when a
    /// coding turn ran for the node (`String??` = present), else the node's current prompt.
    private static func promoted(surface: Set<SZNodeContract.PortSignature>, prompt: String?,
                                 dispatchedPrompt: String??) -> SZNode {
        built(surface: surface, prompt: prompt, stampSurface: surface, stampPrompt: dispatchedPrompt ?? prompt)
    }

    // MARK: The derivation matrix — (surface moved / prompt moved / both / neither)

    @Test func nothingMovedReadsClean() {
        let n = Self.built(surface: Self.surfaceA, prompt: "wobble", stampSurface: Self.surfaceA, stampPrompt: "wobble")
        #expect(n.rebuildReason == nil)
        #expect(n.needsRebuild == false)
        #expect(n.needsImplementation == false)
    }

    @Test func surfaceMovedReadsContractChanged() {
        let n = Self.built(surface: Self.surfaceB, prompt: "wobble", stampSurface: Self.surfaceA, stampPrompt: "wobble")
        #expect(n.rebuildReason == .contractChanged)
        #expect(n.needsImplementation)
    }

    @Test func promptMovedReadsIntentChanged() {
        let n = Self.built(surface: Self.surfaceA, prompt: "wobble, tinted green", stampSurface: Self.surfaceA, stampPrompt: "wobble")
        #expect(n.rebuildReason == .intentChanged)
    }

    /// Both moved: the surface is the more actionable claim (new ports to implement) and is reported first.
    @Test func bothMovedReadsContractChanged() {
        let n = Self.built(surface: Self.surfaceB, prompt: "new", stampSurface: Self.surfaceA, stampPrompt: "old")
        #expect(n.rebuildReason == .contractChanged)
    }

    /// The audit fault outranks both — it is the only *fault* state, and it is ephemeral host evidence.
    @Test func sourceMismatchOutranksTheStampAndIsNotStored() throws {
        var n = Self.built(surface: Self.surfaceB, prompt: "new", stampSurface: Self.surfaceA, stampPrompt: "old")
        n.sourceMismatch = true
        #expect(n.rebuildReason == .sourceMismatch)
        // Never persisted: a round-trip drops it, and the stamp-derived reason surfaces again.
        let back = try JSONDecoder().decode(SZNode.self, from: JSONEncoder().encode(n))
        #expect(back.sourceMismatch == false)
        #expect(back.rebuildReason == .contractChanged)
        n.sourceMismatch = false                    // the host's re-audit came back clean → fully cleared
        #expect(n.rebuildReason == .contractChanged)
    }

    /// Edit-and-revert heals by construction: add a port, remove it again → the surface equals the stamp again.
    @Test func editAndRevertHeals() {
        var n = Self.built(surface: Self.surfaceA, prompt: "wobble", stampSurface: Self.surfaceA, stampPrompt: "wobble")
        n.contract = Self.contract(Self.surfaceB)
        #expect(n.rebuildReason == .contractChanged)
        n.contract = Self.contract(Self.surfaceA)
        #expect(n.rebuildReason == nil)
        n.prompt = "something else"
        #expect(n.rebuildReason == .intentChanged)
        n.prompt = "wobble"
        #expect(n.rebuildReason == nil)
    }

    /// Never built → nothing to be out of date; a built node with no stamp is trusted (load seeds one).
    @Test func promptNodesAndUnstampedBuildsReadClean() {
        var n = SZNode(kind: .prompt, title: "N", prompt: "x", contract: Self.contract(Self.surfaceB), position: SZPoint(x: 0, y: 0),
                       buildStamp: SZBuildStamp(portSurface: Self.surfaceA, prompt: "y"))
        #expect(n.rebuildReason == nil)
        #expect(n.needsImplementation)             // still pending — it was never built
        n = SZNode(kind: .generated, title: "N", prompt: "x", contract: Self.contract(Self.surfaceB), position: SZPoint(x: 0, y: 0))
        #expect(n.rebuildReason == nil)
        #expect(n.needsImplementation == false)
    }

    // MARK: The promote rule — × (dispatched prompt equal / different / absent)

    /// The ordinary run: the agent built exactly the intent it was handed. Nothing outstanding.
    @Test func promotedWithTheSameBriefReadsClean() {
        #expect(Self.promoted(surface: Self.surfaceB, prompt: "make it wobble",
                              dispatchedPrompt: .some("make it wobble")).rebuildReason == nil)
    }

    /// THE REGRESSION. The prompt moved while the agent was mid-implementation, so the code that just
    /// compiled implements the OLD intent. The node must read dirty — from the stamp, not a flag anyone
    /// had to remember to raise (a rebuild run used to suppress the raise entirely).
    @Test func promotedMidRebriefReadsIntentChanged() {
        #expect(Self.promoted(surface: Self.surfaceB, prompt: "make it wobble, and tint it green",
                              dispatchedPrompt: .some("make it wobble")).rebuildReason == .intentChanged)
    }

    /// No dispatch record — promoted outside a run (a node-scoped chat turn, an off-run compile). Nothing to
    /// compare against: the current prompt IS the brief, and the node reads clean.
    @Test func promotedWithNoDispatchRecordReadsClean() {
        #expect(Self.promoted(surface: Self.surfaceB, prompt: "anything at all", dispatchedPrompt: nil).rebuildReason == nil)
    }

    /// A node dispatched with no prompt at all (a contract-first drawn node) is distinguishable from one
    /// that was never dispatched — `String??` carries that difference, and both nil layers must behave.
    @Test func dispatchedWithNoPromptIsNotTheSameAsNoRecord() {
        #expect(Self.promoted(surface: Self.surfaceA, prompt: nil, dispatchedPrompt: .some(nil)).rebuildReason == nil)
        #expect(Self.promoted(surface: Self.surfaceA, prompt: "someone typed one mid-run",
                              dispatchedPrompt: .some(nil)).rebuildReason == .intentChanged)
    }

    /// The layer the cases above ASSUME: they hand-build `.some(nil)`, but production reads through a real
    /// `[SZNodeID: String?]`, where the difference between "recorded as no prompt" and "no record" is a
    /// Swift subtlety — assigning a nil *expression* stores `.some(nil)` while assigning a nil *literal*
    /// REMOVES the key. If that ever inverts, promote silently stamps every build with the current prompt.
    @Test func dictionaryRoundTripPreservesTheTwoNilLayers() {
        var records: [SZNodeID: String?] = [:]
        let briefedWithNone = SZNodeID(), briefedWithText = SZNodeID(), neverBriefed = SZNodeID()

        let absentPrompt: String? = nil
        records[briefedWithNone] = absentPrompt        // nil EXPRESSION → stores .some(nil)
        records[briefedWithText] = "draw a circle"

        #expect(records.keys.contains(briefedWithNone))
        #expect(!records.keys.contains(neverBriefed))
        // A briefed-with-nothing node that gained a prompt is dirty; a never-briefed one is clean.
        #expect(Self.promoted(surface: Self.surfaceA, prompt: "typed later",
                              dispatchedPrompt: records[briefedWithNone]).rebuildReason == .intentChanged)
        #expect(Self.promoted(surface: Self.surfaceA, prompt: "typed later",
                              dispatchedPrompt: records[neverBriefed]).rebuildReason == nil)

        // And the run-end filter (`dispatchPrompts.filter { hiddenPieces.contains($0.key) }`) must not
        // collapse a .some(nil) value on its way through.
        let kept = records.filter { $0.key == briefedWithNone }
        #expect(kept.keys.contains(briefedWithNone))
        #expect(Self.promoted(surface: Self.surfaceA, prompt: "typed later",
                              dispatchedPrompt: kept[briefedWithNone]).rebuildReason == .intentChanged)

        records[briefedWithText] = nil                 // nil LITERAL → removes the key
        #expect(!records.keys.contains(briefedWithText))
    }

    /// The stamp rides `project.json` with the node, in a stable port order.
    @Test func stampRoundTripsAndEncodesInStableOrder() throws {
        let n = Self.built(surface: Self.surfaceB, prompt: "p", stampSurface: Self.surfaceB, stampPrompt: "p")
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let a = try enc.encode(n)
        let back = try JSONDecoder().decode(SZNode.self, from: a)
        #expect(back.buildStamp == n.buildStamp)
        #expect(back.rebuildReason == nil)
        var shuffled = n
        shuffled.buildStamp = SZBuildStamp(portSurface: Set(Self.surfaceB.shuffled()), prompt: "p")
        #expect(try enc.encode(shuffled) == a)
    }
}
