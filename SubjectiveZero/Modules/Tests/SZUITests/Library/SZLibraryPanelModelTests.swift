// SPDX-License-Identifier: AGPL-3.0-only
// The Library panel's list logic, pinned headlessly: grouping order, search ranking, the keyboard
// highlight, the empty states, the footer, the source chips rule, and the drag payload round trip.
import Foundation
import Testing
import SZCore
@testable import SZUI

private func item(_ id: String, title: String, inputs: [SZPortType] = [.texture], outputs: [SZPortType] = [.texture],
                  tags: [String] = [], purpose: String? = nil, permissions: [SZEntitlement]? = nil,
                  source: SZLibrarySourceID = .builtIn) -> SZLibraryItem {
    let contract = SZNodeContract(
        title: title, sfSymbol: "circle", summary: "\(title) summary.",
        inputs: inputs.enumerated().map { SZPort(name: "in\($0.offset)", type: $0.element) },
        outputs: outputs.enumerated().map { SZPort(name: "out\($0.offset)", type: $0.element) },
        permissions: permissions)
    let entry = SZLibraryIndexEntry(id: id, contract: contract,
                                    curation: SZLibraryCurationEntry(id: id, tags: tags, purpose: purpose))
    return SZLibraryItem(entry: entry, source: source)
}

private let blur = item("gaussian-blur", title: "Gaussian Blur", tags: ["blur", "soften"])
private let bloom = item("bloom", title: "Bloom", tags: ["glow", "blur"])
private let camera = item("camera", title: "Camera", inputs: [], permissions: [.camera])
private let noise = item("noise", title: "Noise", inputs: [.float])
private let lfo = item("lfo", title: "LFO", inputs: [.float], outputs: [.float])
private let mineBlur = item("gaussian-blur", title: "Gaussian Blur", tags: ["blur"], source: .mine)

@Test func emptyQueryGroupsInFixedOrderAndSkipsEmptyGroups() {
    let model = SZLibraryPanelModel(items: [lfo, blur, camera, noise, bloom], target: .native)
    #expect(model.sections.map(\.title) == ["Sources", "Effects", "Control"])   // no Audio item, no Audio section
    #expect(model.sections[0].rows.map(\.entryID) == ["camera", "noise"])
    #expect(model.sections[1].rows.map(\.entryID) == ["bloom", "gaussian-blur"])   // alphabetical inside a group
    #expect(model.sections[2].rows.map(\.entryID) == ["lfo"])
    #expect(model.highlight == nil)
    #expect(model.emptyText == nil)
}

@Test func everySectionCarriesItsGroupAndCount() {
    let many = (0..<9).map { item("fx-\($0)", title: "Effect \($0)") }
    let model = SZLibraryPanelModel(items: many + [camera], target: .native)
    #expect(model.sections.map(\.group) == [.sources, .effects])
    #expect(model.sections.map(\.title) == ["Sources", "Effects"])
    #expect(model.sections.map(\.rows.count) == [1, 9])       // the count shows for every group, not just long ones
}

@Test func aShutGroupKeepsItsHeaderAndLeavesTheKeyboardAlone() {
    var model = SZLibraryPanelModel(items: [blur, bloom, camera, noise], target: .native)
    model.collapsed = [.effects]
    // The header stays, with its count, so a shut group still says what is in it.
    #expect(model.sections.map(\.title) == ["Sources", "Effects"])
    #expect(model.sections[1].collapsed)
    #expect(model.sections[1].rows.count == 2)
    // Its rows leave the keyboard walk, so the highlight can't land on something invisible.
    #expect(model.flatRows.map(\.entryID) == ["camera", "noise"])
    #expect(model.rowIndex["builtin/gaussian-blur"] == nil)

    // A live query drops groups entirely, so a shut group never hides a search hit.
    model.query = "blur"
    #expect(model.flatRows.first?.entryID == "gaussian-blur")

    model.query = ""
    #expect(model.flatRows.map(\.entryID) == ["camera", "noise"])   // and it comes back shut
    model.toggle(.effects)
    #expect(model.collapsed.isEmpty)
    #expect(model.flatRows.count == 4)
}

@Test func queryRanksIdExactThenTitlePrefixThenTitleThenTerms() {
    var model = SZLibraryPanelModel(items: [bloom, blur, camera, noise], target: .native)
    model.query = "gaussian-blur"
    #expect(model.sections.count == 1 && model.sections[0].title == nil)
    #expect(model.flatRows.first?.entryID == "gaussian-blur")

    model.query = "blur"
    // "Gaussian Blur" carries the word in its title; Bloom only in a tag.
    #expect(model.flatRows.map(\.entryID) == ["gaussian-blur", "bloom"])

    model.query = "  BLO "   // trimmed, case-insensitive title prefix
    #expect(model.flatRows.map(\.entryID) == ["bloom"])

    model.query = "xyz"
    #expect(model.flatRows.isEmpty)
    #expect(model.emptyText == "Nothing matches")
}

@Test func sameIdInTwoLibrariesTiesByBuiltInFirst() {
    var model = SZLibraryPanelModel(items: [mineBlur, blur], target: .native)
    model.query = "gaussian-blur"
    #expect(model.flatRows.map(\.source) == [.builtIn, .mine])
}

@Test func sourceFilterNarrowsTheRows() {
    var model = SZLibraryPanelModel(items: [blur, mineBlur, camera], target: .native)
    model.sourceFilter = .mine
    #expect(model.flatRows.map(\.id) == ["mine/gaussian-blur"])
    model.sourceFilter = nil
    #expect(model.flatRows.count == 3)
}

@Test func highlightWrapsAndResetsWithTheQuery() {
    var model = SZLibraryPanelModel(items: [bloom, blur, camera], target: .native)
    #expect(model.highlight == nil)
    model.moveHighlight(1)
    #expect(model.highlight == 0)
    model.moveHighlight(-1)
    #expect(model.highlight == 2)   // wrapped to the last row
    model.moveHighlight(1)
    #expect(model.highlight == 0)   // and back around

    model.query = "gaussian"
    #expect(model.highlight == 0)   // a live query highlights the best match
    #expect(model.activate() == blur.ref)
    model.query = "b"
    #expect(model.flatRows.map(\.entryID) == ["bloom", "gaussian-blur"])   // prefix beats substring
    model.moveHighlight(1)
    #expect(model.highlight == 1)
    #expect(model.activate() == blur.ref)
    model.query = ""
    #expect(model.highlight == nil)
    #expect(model.activate() == nil)
}

@Test func highlightClampsWhenTheRowsShrink() {
    var model = SZLibraryPanelModel(items: [bloom, blur, camera], target: .native)
    model.moveHighlight(-1)
    #expect(model.highlight == 2)
    model.items = [bloom]
    #expect(model.highlight == nil)   // the row is gone and there is no query, so nothing is highlighted
    model.setHighlight(5)
    #expect(model.highlight == nil)
    model.setHighlight(0)
    #expect(model.activate() == bloom.ref)
}

@Test func emptyStatesNameTheReason() {
    #expect(SZLibraryPanelModel(items: [], target: .web).emptyText == "No library nodes for browser projects yet")
    #expect(SZLibraryPanelModel(items: [], target: .native).emptyText == "The library is empty")
    var model = SZLibraryPanelModel(items: [blur], target: .native)
    model.sourceFilter = .mine
    #expect(model.emptyText == "Nothing matches")
}

@Test func footerIsJustTheCount() {
    #expect(SZLibraryPanelModel(items: [blur, camera], target: .native).footerText == "2 nodes")
    #expect(SZLibraryPanelModel(items: [blur], target: .web).footerText == "1 node")
}

@Test func nodesLeftOutGetTheirOwnNoteOrNone() {
    #expect(SZLibraryPanelModel(items: [blur, camera], target: .native).offPlatformNote == nil)
    #expect(SZLibraryPanelModel(items: [blur, camera], target: .native, offPlatformCount: 1).offPlatformNote
            == "1 node needs a project in a browser")
    #expect(SZLibraryPanelModel(items: [blur], target: .web, offPlatformCount: 11).offPlatformNote
            == "11 nodes need a project on this Mac")
}

@Test func sourceChipsAppearOnlyWithTwoLibraries() {
    let one = SZLibraryPanelModel(items: [blur, camera], target: .native)
    #expect(one.sources.map(\.name) == ["Built in"])
    #expect(!one.showsSourceChips)
    let two = SZLibraryPanelModel(items: [blur, mineBlur], target: .native)
    #expect(two.sources.map(\.name) == ["Built in", "My Library"])
    #expect(two.showsSourceChips)
    #expect(two.sources.map(\.id) == [.builtIn, .mine])
}

@Test func dragPayloadRoundTrips() {
    let ref = SZLibraryRef.library(source: .mine, id: "gaussian-blur")
    #expect(SZLibraryDrag.ref(from: SZLibraryDrag.data(for: ref)) == ref)
    let node = SZLibraryRef.projectNode(SZNodeID())
    #expect(SZLibraryDrag.ref(from: SZLibraryDrag.data(for: node)) == node)
    #expect(SZLibraryDrag.ref(from: Data("nope".utf8)) == nil)
    #expect(SZLibraryDrag.typeIdentifier == "studio.sxp.subjectivezero.library-ref")
}
