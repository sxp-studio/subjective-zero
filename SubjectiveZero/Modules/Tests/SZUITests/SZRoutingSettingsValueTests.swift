// SPDX-License-Identifier: AGPL-3.0-only
// Contracts for the Routing pane's value structs: option ids join provider and model (the
// menu's stable identity, "provider/" for a catalog-less provider), rows are keyed by their
// (agent, slot) position, grade variants derive their inherit from the graph's grade table,
// and the effort labels keep unknown tokens legible instead of hiding them.
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

@Test func positionRowIdentityIsItsAgentSlotPair() {
    let row = SZRoutingPositionRow(position: SZRoutingPosition(agent: "director", slot: "planner"),
                                   label: "Planner", caption: "Plans the graph",
                                   selectionLabel: "Default",
                                   clearLabel: "Default — Claude · Opus 5", isSet: false)
    #expect(row.id == SZRoutingPosition(agent: "director", slot: "planner"))
    // Same slot word under different agents is a different position — the key is the pair.
    #expect(SZRoutingPosition(agent: "director", slot: "sorter")
        != SZRoutingPosition(agent: "coding", slot: "sorter"))
    // Defaults keep the unset row honest: no options preselected, no effort/fast surface.
    #expect(row.effortOptions.isEmpty && !row.supportsFastMode && !row.fastModeEnabled)
}

@Test func gradeVariantsFallToTheStandardSlotAndNothingElseDoes() {
    let grades = ["light": "builder-light", "standard": "builder-default", "heavy": "builder-heavy"]
    #expect(SZRoutingInheritance.standardSlot(for: "builder-light", grades: grades) == "builder-default")
    #expect(SZRoutingInheritance.standardSlot(for: "builder-heavy", grades: grades) == "builder-default")
    // The standard slot itself and slots outside the table inherit the app default instead.
    #expect(SZRoutingInheritance.standardSlot(for: "builder-default", grades: grades) == nil)
    #expect(SZRoutingInheritance.standardSlot(for: "sorter", grades: grades) == nil)
    #expect(SZRoutingInheritance.standardSlot(for: "builder-light", grades: nil) == nil)
    // A grade table with no standard names nothing to fall to — the app default catches it.
    #expect(SZRoutingInheritance.standardSlot(for: "builder-light",
                                              grades: ["light": "builder-light"]) == nil)
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

@Test func agentCardIdentityIsItsAgentID() {
    let card = SZRoutingAgentCard(id: "coding", title: "Coding", symbol: "hammer")
    #expect(card.id == "coding" && card.rows.isEmpty)
}
