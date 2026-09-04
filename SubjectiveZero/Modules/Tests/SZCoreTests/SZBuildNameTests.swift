// SPDX-License-Identifier: AGPL-3.0-only
// The naming rule for a build: first line, lead dropped, a handful of words, same everywhere.
import Foundation
import Testing
@testable import SZCore

@Test func theImperativeLeadIsDroppedAndTheRestSentenceCased() {
    #expect(SZBuildName.short("Make a warm orange radial gradient") == "Warm orange radial gradient")
    #expect(SZBuildName.short("make a grayscale version my macbook camera") == "Grayscale version my macbook camera")
    #expect(SZBuildName.short("Can you please add a bloom pass after the blur") == "Bloom pass after the blur")
    #expect(SZBuildName.short("I'd like some film grain.") == "Film grain")
    #expect(SZBuildName.short("I\u{2019}d like some film grain.") == "Film grain")
    #expect(SZBuildName.short("Can you add bloom?") == "Bloom")
}

@Test func casingLeavesProperNamesAlone() {
    #expect(SZBuildName.short("iPhone camera feed") == "iPhone camera feed")
    #expect(SZBuildName.short("add an iPhone camera feed") == "iPhone camera feed")
    #expect(SZBuildName.short("glsl noise") == "Glsl noise")
}

@Test func aLeadThatCarriesTheMeaningStays() {
    // "It grayscale" says nothing; the verb is the ask.
    #expect(SZBuildName.short("Make it grayscale") == "Make it grayscale")
    #expect(SZBuildName.short("Make it, grayscale") == "Make it, grayscale")
    #expect(SZBuildName.short("Render to a texture") == "Render to a texture")
    #expect(SZBuildName.short("Add to the group") == "Add to the group")
    #expect(SZBuildName.short("I want to add bloom") == "Bloom")
    #expect(SZBuildName.short("Add") == "Add")
    // The Build button's own title has no lead to drop.
    #expect(SZBuildName.short("Implement 2 nodes") == "Implement 2 nodes")
}

@Test func longAsksAreCappedAtAFewWords() {
    let ask = "Make a warm orange radial gradient that breathes slowly and fades at the corners"
    #expect(SZBuildName.short(ask) == "Warm orange radial gradient that breathes…")
    #expect(SZBuildName.short("one two three four five six seven", maxWords: 3) == "One two three…")
    // The ellipsis never follows "the" or "and".
    #expect(SZBuildName.short("Add a bloom pass after the blur and then a vignette") == "Bloom pass after the blur…")
}

@Test func onlyTheFirstLineNamesTheBuild() {
    #expect(SZBuildName.short("Slowly rotating checkerboard\nwith soft edges") == "Slowly rotating checkerboard")
    #expect(SZBuildName.short("") == "")
    #expect(SZBuildName.short("...") == "...")
}

@Test func aRecordNamesItselfThroughTheSameRule() {
    let id = UUID()
    let run = SZAgentGraphRun(id: id, agent: "director", thread: id,
                              title: "Make a slowly rotating grayscale checkerboard")
    #expect(run.name == "Slowly rotating grayscale checkerboard")
    #expect(SZAgentGraphRun(id: id, agent: "director").name == nil)
    #expect(SZAgentGraphRun(id: id, agent: "director", title: "  ").name == nil)
}
