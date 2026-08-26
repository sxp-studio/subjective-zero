// SPDX-License-Identifier: AGPL-3.0-only
// Splitting one turn's working trace into the steps it took — the rule a run card's band draws.
import Foundation
import Testing
import SZCore
@testable import SZUI

@Test func aToolSightingBecomesItsOwnStep() {
    let steps = SZAgentActivityStep.steps(thinking: "→ Read\n→ Edit\n")
    #expect(steps.map(\.kind) == [.tool, .tool])
    #expect(steps.map(\.text) == ["Read", "Edit"])
}

@Test func proseBetweenToolsGathersIntoOneThought() {
    // The stream writes reasoning in pieces; a step is what the agent DID, so the prose
    // between two sightings is one thought rather than a step per flush.
    let steps = SZAgentActivityStep.steps(thinking: "I'll write it\nfrom scratch.\n→ Read\nNow edit.\n")
    #expect(steps.map(\.kind) == [.thought, .tool, .thought])
    #expect(steps[0].text == "I'll write it\nfrom scratch.")
    #expect(steps[1].text == "Read")
    #expect(steps[2].text == "Now edit.")
}

@Test func blankRunsCollapseRatherThanBecomingEmptySteps() {
    // The stream pads with newlines; an empty row would read as the agent pausing.
    let steps = SZAgentActivityStep.steps(thinking: "\n\n→ Read\n\n\n→ Edit\n\n")
    #expect(steps.map(\.kind) == [.tool, .tool])
}

@Test func anEmptyTraceHasNoSteps() {
    #expect(SZAgentActivityStep.steps(thinking: "").isEmpty)
    #expect(SZAgentActivityStep.steps(thinking: "   \n\n").isEmpty)
}

@Test func anArrowWithNoNameIsProseNotAStep() {
    // A bare arrow names no tool — it is whatever the model wrote, not a sighting.
    let steps = SZAgentActivityStep.steps(thinking: "→\nthen a → b holds\n")
    #expect(steps.map(\.kind) == [.thought])
}

@MainActor
@Test func aTurnIsFoundByIdWhicheverConversationItLandedIn() {
    // A band knows its visit's message id, not its scope: a chat run names no node whatever
    // scope it answers in, so deriving one read a node's chat out of the Director's transcript.
    let store = SZStore()
    let node = SZNodeID()
    let inNode = store.appendChatMessage(SZChatMessage(role: .assistant, text: "node turn"),
                                         to: .node(node))
    let inDirector = store.appendChatMessage(SZChatMessage(role: .assistant, text: "director turn"),
                                             to: .director)
    #expect(store.chatMessage(id: inNode)?.text == "node turn")
    #expect(store.chatMessage(id: inDirector)?.text == "director turn")
    #expect(store.chatMessage(id: UUID()) == nil)
}
