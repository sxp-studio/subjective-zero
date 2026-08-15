// SPDX-License-Identifier: AGPL-3.0-only
// The delivery's snapshot rule: a step evaluation and its asks see ONE pinned
// (message, world) pair — `facts()` pins, `serveAsk` renders against the pin, and a world
// that moves mid-evaluation (a fleet child promoting a node, a status landing) must not
// leak into an ask the step already started. The comment on `SZDelivery.pinned` claimed
// this; this makes it load-bearing.
import Foundation
import Synchronization
import Testing
import SZAI
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZDeliveryTests {

    @Test func anAskRendersAgainstTheEvaluationsPinnedSnapshot() async throws {
        let prompts = Mutex<[String]>([])
        let renderer = SZBriefRenderer { _, path in
            path == "prompts/probe.md.mustache" ? "round {{round}}" : ""
        }
        let queries = SZQueryService(
            renderer: renderer,
            router: SZIdentityRouter(choice: SZModelChoice(providerID: "claude", model: nil,
                                                           reasoningEffort: nil)),
            cacheDirectory: FileManager.default.temporaryDirectory
                .appending(path: "sz-delivery-test-\(UUID().uuidString)"),
            executor: { request, _ in
                prompts.withLock { $0.append(request.prompt) }
                return "{}"
            })
        var round = 1
        let delivery = SZDelivery(
            agent: "director", message: "", renderer: renderer, queries: queries,
            world: { SZWorld(run: SZRun(workSet: [], round: round, roundCap: 3,
                                        steers: [], instruction: "")) },
            turn: { _ in SZTurnReport(failed: true, detail: "no turns in this test") },
            effect: { _ in }, onNote: { _ in })

        _ = delivery.facts()   // the evaluation starts: round 1 is pinned
        round = 2              // the world moves underneath it
        _ = try await delivery.serveAsk(step: "probe",
                                        requestJSON: #"{"template": "probe", "attempt": 0}"#)
        #expect(prompts.withLock { $0 } == ["round 1"])
    }
}
