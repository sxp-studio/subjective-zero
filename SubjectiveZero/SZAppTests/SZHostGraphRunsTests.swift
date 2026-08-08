// SPDX-License-Identifier: AGPL-3.0-only
// The RUNS-record host seam, smoke-tested end to end without a project or an engine: the
// strategy's hooks (begin → note → conclude → tally) land on `SZHost` and must leave the
// observable list the Agent Graph panel draws — ordered, sealed, tally-amended — with the
// engine's note vocabulary mapped onto the record's own trace entry.
import Foundation
import Testing
import SZAI
import SZCore
@testable import SubjectiveZero

@Test @MainActor func graphRunHooksBuildOrderAndSealTheRecords() throws {
    let host = SZHost()
    let build = UUID(), item = UUID()

    // A director traversal begins, works, and concludes by dispatching.
    host.beginAgentGraphRun(SZTraversalSighting(id: build, agent: "director",
                                                graphName: "build", kind: .build))
    host.noteAgentGraphRun(build, SZTraversalNote(ordinal: 1, node: "work-left", phase: .running))
    host.noteAgentGraphRun(build, SZTraversalNote(ordinal: 1, node: "work-left", phase: .done,
                                                  outcome: "yes"))
    // An item traversal starts while the build record is still live — the build must keep
    // the head of the list (it is what the panel follows).
    host.beginAgentGraphRun(SZTraversalSighting(id: item, agent: "coding", graphName: "item",
                                                kind: .item, item: "node-1"))
    #expect(host.agentGraphRuns.map(\.id) == [build, item])

    host.concludeAgentGraphRun(build, .ended)
    host.noteAgentGraphRun(item, SZTraversalNote(ordinal: 1, node: "implement", phase: .failed,
                                                 detail: "the turn threw"))
    host.concludeAgentGraphRun(item, .failed(reason: "the turn threw"))
    // The set settles after the sender sealed — the sanctioned post-seal amend.
    host.amendAgentGraphRunTally(build, settled: 1, total: 1, failed: 1)

    let sealed = host.agentGraphRuns
    #expect(sealed.allSatisfy { !$0.isLive })
    let buildRecord = try #require(sealed.first { $0.id == build })
    #expect(buildRecord.conclusion == .ended)
    #expect(buildRecord.tally == SZAgentGraphRun.Tally(settled: 1, total: 1, failed: 1))
    #expect(buildRecord.trace.map(\.outcome) == ["yes"])       // note replaced, not appended
    let itemRecord = try #require(sealed.first { $0.id == item })
    #expect(itemRecord.item == "node-1")
    #expect(itemRecord.conclusion == .failed(reason: "the turn threw"))
    #expect(itemRecord.trace.first?.detail == "the turn threw")

    // The drain sweep is a no-op once everything sealed itself (the healthy path).
    host.sealLeakedAgentGraphRuns(thread: nil)
    #expect(host.agentGraphRuns == sealed)
}
