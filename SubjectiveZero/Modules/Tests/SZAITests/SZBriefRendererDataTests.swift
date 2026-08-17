// SPDX-License-Identifier: AGPL-3.0-only
// The leftover-token refusal judges AUTHORED text only. Data that happens to spell a
// token — a user asking about `{{node}}`, a run instruction quoting a template — must
// ship as words (defused), never expand, and never fail the delivery; while a token a
// template or partial authored that nothing substitutes must refuse. Both directions
// pinned here; the byte truth for every production brief stays with the equivalence gate.
import Foundation
import Testing
import SZCore
@testable import SZAI

struct SZBriefRendererDataTests {

    private func renderer(_ templates: [String: String]) -> SZBriefRenderer {
        SZBriefRenderer { agent, path in
            guard let text = templates[path] else {
                throw SZBriefRenderError.missingTemplate(agent: agent, path: path)
            }
            return text
        }
    }

    @Test func wordsThatSpellATokenShipDefusedNotLiteral() throws {
        let r = renderer(["prompts/chat.md.mustache": "The user said:\n{{message}}\n"])
        let out = try r.render(agent: "debug", template: "chat",
                               message: "why is {{node}} not substituting?", world: SZWorld())
        #expect(out.contains("{ {node}} not substituting"))
        #expect(!out.contains("{{node}}"))
    }

    @Test func aRunInstructionThatSpellsATokenIsInert() throws {
        let r = renderer(["prompts/decompose.md.mustache": "{{instruction}}"])
        var world = SZWorld()
        world.run = SZRun(workSet: [], round: 1, roundCap: 2, steers: [],
                          instruction: "render {{graph}} literally please")
        let out = try r.render(agent: "director", template: "decompose",
                               message: "", world: world)
        #expect(out.contains("{ {graph}} literally please"))
    }

    @Test func theWorkBriefCarriesTheNodesCurrentTitleAndSymbol() throws {
        // The compile brief shows the card's identity so the agent authors it in, not blind — a promote
        // keeps the boundary's title/symbol, so a blind retitle would be a silent no-op.
        let r = renderer(["prompts/node-compile.md.mustache": "titled {{title}} ({{symbol}})"])
        let node = SZNode(title: "Fish", sfSymbol: "fish", prompt: "a fish tank",
                          position: SZPoint(x: 0, y: 0))
        let world = SZWorld(graph: SZGraph(nodes: [node]), node: node.id)
        let out = try r.render(agent: "coding", template: "node-compile", message: "", world: world)
        #expect(out == "titled Fish (fish)")
    }

    @Test func aTemplateAuthoredTokenNothingSubstitutesRefuses() {
        let r = renderer(["prompts/chat.md.mustache": "Hello {{bogus}}"])
        #expect(throws: SZBriefRenderError.self) {
            try r.render(agent: "debug", template: "chat", message: "hi", world: SZWorld())
        }
    }

    @Test func aPartialAuthoredTokenNothingSubstitutesRefuses() {
        let r = renderer([
            "prompts/chat.md.mustache": "{{toolbelt}}",
            "prompts/toolbelt.md.mustache": "Use {{misspelled_token}} for edits.",
        ])
        #expect(throws: SZBriefRenderError.self) {
            try r.render(agent: "debug", template: "chat", message: "hi", world: SZWorld())
        }
    }
}
