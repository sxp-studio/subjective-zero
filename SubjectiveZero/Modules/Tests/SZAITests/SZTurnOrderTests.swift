// SPDX-License-Identifier: AGPL-3.0-only
// An order landed on its scope's session: a resume takes affinity's choice and the id it may
// continue (never across providers), a spawn passes through; the request an order becomes;
// and the world's `resuming` fact, true only when every resume turn would really continue.
import Foundation
import Testing
import SZAI
import SZCore

private let claude = SZModelChoice(providerID: "claude", model: "claude-opus-5")
private let codexRouted = SZModelChoice(providerID: "codex", model: "gpt-5", via: "p · a · assistant")
private let tmp = URL(filePath: "/tmp")

private func order(_ session: SZAgentGraph.Turn.Session, choice: SZModelChoice,
                   tools: [String]? = nil) -> SZTurnOrder {
    SZTurnOrder(agent: "a", brief: "hi", session: session, tools: tools, choice: choice)
}

@Suite
struct SZTurnOrderTests {

    @Test func aPinlessSessionUnderAMovedRouteIsNotResumable() {
        let session = SZAgentSession(providerID: "claude", sessionID: "s-1")
        let resolved = order(.resume, choice: codexRouted).resolved(against: session)
        #expect(resolved.choice.providerID == "codex")
        #expect(resolved.resumeSessionID == nil)
    }

    @Test func aPinnedSessionUnderAMovedRouteKeepsItsThread() {
        let session = SZAgentSession(providerID: "claude", sessionID: "s-1",
                                     envelope: SZRouteEnvelope(providerID: "claude", model: "claude-opus-5"))
        let resolved = order(.resume, choice: codexRouted).resolved(against: session)
        #expect(resolved.choice.providerID == "claude")
        #expect(resolved.choice.via == "session")
        #expect(resolved.resumeSessionID == "s-1")
    }

    @Test func aSpawnAndAMissingSessionPassThrough() {
        let session = SZAgentSession(providerID: "claude", sessionID: "s-1")
        #expect(order(.spawn, choice: claude).resolved(against: session).resumeSessionID == nil)
        #expect(order(.resume, choice: claude).resolved(against: nil).resumeSessionID == nil)
        #expect(order(.resume, choice: claude).resolved(against: session).resumeSessionID == "s-1")
    }

    @Test func theRequestCarriesTheOrdersToolsGenerationAndResumeID() {
        var resumed = order(.resume, choice: SZModelChoice(providerID: "claude", model: "m",
                                                            reasoningEffort: "high", fastMode: true))
        resumed.resumeSessionID = "s-9"
        let request = SZAgentRunRequest(resumed, workingDirectory: tmp, packageDirectory: tmp,
                                        cacheDirectory: tmp, mcpPort: 4242, defaultTools: ["a", "b"])
        #expect(request.prompt == "hi")
        #expect(request.mcpServerPort == 4242 && request.allowedMCPTools == ["a", "b"])
        #expect(request.resumeSessionID == "s-9")
        #expect(request.model == "m" && request.reasoningEffort == "high" && request.fastMode)
        #expect(request.timeout == SZAgentTurnBudgets.codingTimeout)

        let none = SZAgentRunRequest(order(.spawn, choice: claude, tools: []), prompt: "p",
                                     workingDirectory: tmp, packageDirectory: tmp,
                                     cacheDirectory: tmp, mcpPort: 4242, defaultTools: ["a"])
        #expect(none.mcpServerPort == nil && none.allowedMCPTools.isEmpty && none.prompt == "p")
        let some = SZAgentRunRequest(order(.spawn, choice: claude, tools: ["x"]),
                                     workingDirectory: tmp, packageDirectory: tmp,
                                     cacheDirectory: tmp, mcpPort: 4242, defaultTools: ["a"])
        #expect(some.mcpServerPort == 4242 && some.allowedMCPTools == ["x"])
    }

    @Test func thePinMirrorsTheRequestItOpenedWith() {
        let request = SZAgentRunRequest(prompt: "", workingDirectory: tmp, cacheDirectory: tmp,
                                        model: "m", reasoningEffort: "low", fastMode: true)
        let pin = SZAgentSession(providerID: "codex", sessionID: "t", opening: request)
        #expect(pin.envelope == SZRouteEnvelope(providerID: "codex", model: "m",
                                                reasoningEffort: "low", fastMode: true))
    }

    /// Two resume turns on different slots, like the shipped coding graph.
    private let graph = SZAgentGraph(
        nodes: [.init(id: SZAgentGraph.doorID, form: .step(name: "door")),
                .init(id: "continue", form: .turn(.init(brief: "again", session: .resume,
                                                         slot: "builder"))),
                .init(id: "chat-resumed", form: .turn(.init(brief: "chat", session: .resume,
                                                             slot: "assistant")))],
        edges: [.init(from: SZAgentGraph.doorID, outcome: "continue", to: "continue"),
                .init(from: SZAgentGraph.doorID, outcome: "chat-resumed", to: "chat-resumed")])

    @Test func resumingIsTrueOnlyWhenEveryResumeTurnWouldContinue() {
        // Only the assistant slot moves to codex; the builder slot stays on claude.
        let routed = SZProfileRouter(fallback: claude, agents: ["a": ["assistant": codexRouted]])
        let pinless = SZAgentSession(providerID: "claude", sessionID: "s")
        let pinned = SZAgentSession(providerID: "claude", sessionID: "s",
                                    envelope: SZRouteEnvelope(providerID: "claude"))
        #expect(!graph.resumes(pinless, agent: "a", router: routed))   // one turn would not
        #expect(graph.resumes(pinned, agent: "a", router: routed))
        #expect(graph.resumes(pinless, agent: "a", router: SZIdentityRouter(choice: claude)))
        #expect(!graph.resumes(nil, agent: "a", router: SZIdentityRouter(choice: claude)))
    }
}
