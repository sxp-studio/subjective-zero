// SPDX-License-Identifier: AGPL-3.0-only
// Contracts for the Routing pane's value structs: option ids join provider and model (the
// menu's stable identity, "provider/" for a catalog-less provider), row ids ARE the host's
// position tokens, and the effort labels keep unknown tokens legible instead of hiding them.
import Testing
@testable import SZUI

@Test func envelopeOptionIDJoinsProviderAndModel() {
    let paired = SZRoutingEnvelopeOption(providerID: "codex", modelID: "gpt-5.6-terra",
                                         label: "Codex · GPT-5.6 Terra")
    #expect(paired.id == "codex/gpt-5.6-terra")
    // A catalog-less provider still gets a stable id — the trailing slash is the "no model" spelling.
    let bare = SZRoutingEnvelopeOption(providerID: "pi", modelID: nil, label: "Pi")
    #expect(bare.id == "pi/")
}

@Test func positionRowIdentityIsTheHostToken() {
    let row = SZRoutingPositionRow(id: "duty:director/plan", label: "Plan",
                                   selectionLabel: "Default", isSet: false)
    #expect(row.id == "duty:director/plan")
    // Defaults keep the unset row honest: no options preselected, no effort/fast surface.
    #expect(row.effortOptions.isEmpty && !row.supportsFastMode && !row.fastModeEnabled)
}

@Test func effortLabelsCoverKnownTokensAndPassUnknownThrough() {
    #expect(SZGenerationLabels.effort("low") == "Low")
    #expect(SZGenerationLabels.effort("xhigh") == "Extra High")
    #expect(SZGenerationLabels.effort("ultra") == "Ultra")
    // Unknown tokens stay visible raw — still legible, still re-pickable.
    #expect(SZGenerationLabels.effort("mystery") == "mystery")
}

@Test func profileRowIdentityIsItsName() {
    let row = SZRoutingProfileRow(name: "Fast Fleet", isActive: true)
    #expect(row.id == "Fast Fleet" && row.isActive)
}
