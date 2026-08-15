// SPDX-License-Identifier: AGPL-3.0-only
// The split/merge SEED prompts the host writes onto each new node — rendered through the
// production path (`SZBriefRenderer` + the shipped coding pack's `split-stage`/`merge`
// templates, exactly as SZHost+SplitMerge's `renderSeed` does). These are the only place a
// user's steer ("split it into a blur stage then a sharpen stage") survives the trip from
// the composer through the Director and `ui_split_node` into the Coding Agents — so it is
// asserted here, not just live. The defusing checks stand between a token-spelling steer
// and a hash-seed-dependent prompt.
import Foundation
import Testing
@testable import SZAI
@testable import SZCore

private let shippedPacksRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()   // SZAITests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // Modules
    .appending(path: "Sources/SZAI/Resources/Agents")

private func contract(_ title: String = "Blur") -> SZNodeContract {
    SZNodeContract(
        title: title, sfSymbol: "circle", summary: "blurs the input",
        inputs: [SZPort(name: "input", type: .texture),
                 SZPort(name: "radius", type: .float, ui: SZPortUI(kind: .slider, min: 0, max: 10, step: 0.1))],
        outputs: [SZPort(name: "output", type: .texture, display: true)])
}

private func renderSeed(_ template: String, _ graphOp: SZBriefExtras.GraphOp) -> String {
    try! SZBriefRenderer(packRoot: shippedPacksRoot).render(
        agent: "coding", template: template, message: "",
        world: SZWorld(), extras: SZBriefExtras(graphOp: graphOp))
}

private func splitStage(_ instruction: String?, stage: Int = 1, count: Int = 2) -> String {
    renderSeed("split-stage", SZBriefExtras.GraphOp(
        original: "Blur+Sharpen", intent: "blur then sharpen the image", stage: stage, count: count,
        source: "struct Node {}", contract: contract(), instruction: instruction))
}

private func merge(_ instruction: String?) -> String {
    renderSeed("merge", SZBriefExtras.GraphOp(
        count: 2,
        constituents: [.init(title: "Blur", intent: "blur it", source: "struct A {}"),
                       .init(title: "Sharpen", intent: "sharpen it", source: "struct B {}")],
        contract: contract("Blur+Sharpen"), instruction: instruction))
}

/// No `{{token}}` may survive rendering — a template typo is otherwise invisible until an agent reads it.
private func noUnrenderedTokens(_ rendered: String) -> Bool { !rendered.contains("{{") }

// MARK: - split

@Test func splitStageWeavesTheSteerIntoEveryStage() {
    for stage in 1...3 {
        let out = splitStage("a blur stage then a sharpen stage", stage: stage, count: 3)
        #expect(out.contains("a blur stage then a sharpen stage"))
        // Framed as HOW to split, so the agent can't read it as the node's own intent.
        #expect(out.contains("How the user asked for this split to be done"))
        #expect(noUnrenderedTokens(out))
    }
}

@Test func splitStageStillCarriesIntentBoundaryAndSource() {
    let out = splitStage("favour performance")
    #expect(out.contains("blur then sharpen the image"))   // intent, distinct from the steer
    #expect(out.contains("stage 1 of 2"))
    #expect(out.contains("`radius` — float"))              // boundary
    #expect(out.contains("struct Node {}"))                // source to divide
}

@Test func splitStageTellsTheAgentToPreserveBehaviourAndIgnoreTheLibrary() {
    // A split divides working code; the coding agent's system prompt otherwise sends it to the node
    // library, and it comes back with a reinterpretation instead of the same node in two pieces.
    let out = splitStage(nil)
    #expect(out.contains("PRESERVE BEHAVIOR"))
    #expect(out.contains("do NOT reach for the node library"))
}

@Test func mergeTellsTheAgentToPreserveBehaviourAndIgnoreTheLibrary() {
    let out = merge(nil)
    #expect(out.contains("PRESERVE BEHAVIOR"))
    #expect(out.contains("do NOT reach for the node library"))
}

@Test func splitStageWithoutASteerRendersNoSteerSection() {
    let out = splitStage(nil)
    #expect(!out.contains("How the user asked"))
    #expect(noUnrenderedTokens(out))
    #expect(out.contains("blur then sharpen the image"))
    // The empty steer collapses to a paragraph break, never a run-on or a triple newline.
    #expect(!out.contains("\n\n\n"))
    #expect(out.contains("blur then sharpen the image\n\nThe whole node's current source"))
}

@Test func splitStageTreatsAWhitespaceOnlySteerAsAbsent() {
    #expect(!splitStage("   \n  ").contains("How the user asked"))
}

@Test func aSteerCannotInjectATemplateToken() {
    // The steer is the only USER-authored value handed to the flat `{{token}}` replacer, which walks an
    // UNORDERED dictionary: a live token inside it would expand — or not — depending on the hash seed,
    // so the same instruction would render two different prompts on two runs.
    let out = splitStage("sharpen, but keep {{source}} untouched")
    #expect(out.contains("keep { {source}} untouched"))   // defused, and still legible to the agent
    #expect(noUnrenderedTokens(out))
    // The real `{{source}}` still rendered exactly once — the steer didn't smuggle in a second copy.
    #expect(out.components(separatedBy: "struct Node {}").count - 1 == 1)
}

@Test func aMergeSteerCannotInjectATemplateToken() {
    let out = merge("fuse them, {{constituents}} first")
    #expect(noUnrenderedTokens(out))
    #expect(out.contains("{ {constituents}}"))
}

// MARK: - merge

@Test func mergeWeavesTheSteerIn() {
    let out = merge("merge favouring performance")
    #expect(out.contains("merge favouring performance"))
    #expect(out.contains("How the user asked for this merge to be done"))
    #expect(noUnrenderedTokens(out))
}

@Test func mergeStillCarriesConstituentsAndBoundary() {
    let out = merge("keep it simple")
    #expect(out.contains("- Blur: blur it"))
    #expect(out.contains("struct B {}"))
    #expect(out.contains("`output` — texture, display"))
}

@Test func mergeWithoutASteerRendersNoSteerSection() {
    let out = merge(nil)
    #expect(!out.contains("How the user asked"))
    #expect(noUnrenderedTokens(out))
    #expect(!out.contains("\n\n\n"))
}

// MARK: - the shared boundary renderer (SZBoundaryPrompt — split/merge seeds AND item briefs)

/// The boundary names each port's TYPE and the exact live-read call, so the agent
/// preserves the typed contract AND reads scalar inputs instead of hardcoding them (the silent-no-op).
@Test func renderBoundaryDescribesTypesAndLiveReads() {
    let inputs = [
        SZPort(name: "input", type: .texture),
        SZPort(name: "mirror", type: .bool, ui: SZPortUI(kind: .toggle), def: .bool(true)),
        SZPort(name: "amount", type: .float, ui: SZPortUI(kind: .slider), def: .float(0.5)),
        SZPort(name: "camera", type: .enumeration, ui: SZPortUI(kind: .dropdown), def: .enumeration("default")),
    ]
    let outputs = [SZPort(name: "output", type: .texture, display: true)]
    let b = SZBoundaryPrompt.render(inputs: inputs, outputs: outputs, permissions: [.camera])

    #expect(b.contains("`mirror` — bool"))                 // type preserved, not flattened to texture
    #expect(b.contains(#"ctx.inputBool("mirror")"#))       // bool read live, through the bool accessor
    #expect(b.contains(#"ctx.inputFloat("amount")"#))      // float read live
    #expect(b.contains(#"ctx.inputTexture("input")"#))     // texture read
    #expect(b.contains(#"ctx.outputTexture("output")"#))   // output fill
    #expect(b.contains("default true"))                    // ui/default surfaced
    #expect(b.contains(#"ctx.inputString("camera")"#))     // enum delivered live via the v4 string ABI
    #expect(b.contains("camera"))                          // declared permission surfaced

    // A contract-less node derives texture-only ports → texture read guidance, no scalar reads.
    let textureOnly = SZBoundaryPrompt.render(
        inputs: [SZPort(name: "input", type: .texture)],
        outputs: [SZPort(name: "output", type: .texture, display: true)], permissions: [])
    #expect(textureOnly.contains(#"ctx.inputTexture("input")"#))
    #expect(!textureOnly.contains("inputFloat"))
}
