// SPDX-License-Identifier: AGPL-3.0-only
// The SZTrace fence architecture: the gate's truth table, recorder thread-safety, task-local
// context flow (the load-bearing design fact), drop-by-design attribution, and span parentage.
// Facade tests use distinct turnIDs so parallel test execution can't cross-contaminate the
// shared recorder.
import Foundation
import Testing
@testable import SZCore

// MARK: - Gate

@Test func traceGateTruthTable() {
    #expect(SZTrace.enabled(env: ["SZ_TRACE": "1"]))
    #expect(!SZTrace.enabled(env: ["SZ_TRACE": "0"]))
    // Absent → build-flavor default; tests compile DEBUG, so the default is on.
    #expect(SZTrace.enabled(env: [:]))
    // Junk values fall through to the default, not to a crash.
    #expect(SZTrace.enabled(env: ["SZ_TRACE": "banana"]))
}

// MARK: - Recorder

@Test func recorderSurvivesConcurrentHammering() async {
    let recorder = SZTraceRecorder()
    let turnIDs = (0..<8).map { _ in UUID() }
    await withTaskGroup(of: Void.self) { group in
        for (i, turnID) in turnIDs.enumerated() {
            group.addTask {
                for j in 0..<200 {
                    recorder.record(SZTurnEvent(stage: "t\(i)", detail: "\(j)"), turnID: turnID)
                }
            }
        }
    }
    for (i, turnID) in turnIDs.enumerated() {
        let events = recorder.take(turnID: turnID)
        #expect(events.count == 200)                       // no loss, no cross-turn bleed
        #expect(events.allSatisfy { $0.stage == "t\(i)" })
    }
}

@Test func recorderTakeRemovesAndDiscardDrops() {
    let recorder = SZTraceRecorder()
    let turnID = UUID()
    recorder.record(SZTurnEvent(stage: "a"), turnID: turnID)
    #expect(recorder.take(turnID: turnID).count == 1)
    #expect(recorder.take(turnID: turnID).isEmpty)         // take = remove
    recorder.record(SZTurnEvent(stage: "b"), turnID: turnID)
    recorder.discard(turnID: turnID)
    #expect(recorder.take(turnID: turnID).isEmpty)
}

@Test func recorderCapsRunawayTurns() {
    let recorder = SZTraceRecorder(cap: 5)
    let turnID = UUID()
    for i in 0..<20 { recorder.record(SZTurnEvent(stage: "s\(i)"), turnID: turnID) }
    let events = recorder.take(turnID: turnID)
    #expect(events.count == 5)
    #expect(events.first?.stage == "s0")                   // first N kept, tail dropped
}

// MARK: - Context flow (the design's load-bearing facts)

@Test func fencesWithoutContextAreDropped() {
    let turnID = UUID()
    // No ambient context here — every form must no-op, never misfile.
    SZTrace.instant("orphan")
    SZTrace.begin("orphan").end()
    SZTrace.span("orphan") { }
    #expect(SZTrace.take(turnID: turnID).isEmpty)
}

@Test func boundContextAttributesAllForms() {
    let turnID = UUID()
    let ctx = SZTraceContext(turnID: turnID, scopeKey: "scope", runID: UUID())
    SZTrace.$context.withValue(ctx) {
        SZTrace.instant("i", detail: "sight")
        SZTrace.span("s") { }
        SZTrace.begin("b").end(detail: "done")
    }
    let events = SZTrace.take(turnID: turnID)
    #expect(events.map(\.stage) == ["i", "s", "b"])
    #expect(events.allSatisfy { $0.runID == ctx.runID })   // runID stamped from context
    #expect(events[2].detail == "done")                    // end-detail replaces begin's
    #expect(events[1].duration != nil)                     // spans measure
    #expect(events[0].duration == nil)                     // instants don't
}

@Test func contextFlowsIntoUnstructuredTasks() async {
    let turnID = UUID()
    let ctx = SZTraceContext(turnID: turnID, scopeKey: "scope")
    await SZTrace.$context.withValue(ctx) {
        // The stream-consumer pattern: an unstructured Task created inside the binding
        // inherits the task-local at creation.
        await Task { SZTrace.instant("from-child-task") }.value
    }
    #expect(SZTrace.take(turnID: turnID).count == 1)
}

@Test func nilBindingShadowsAmbientContext() {
    let turnID = UUID()
    let ctx = SZTraceContext(turnID: turnID, scopeKey: "scope")
    SZTrace.$context.withValue(ctx) {
        // The bridge's rule: binding nil DROPS, even with an outer context ambient.
        SZTrace.$context.withValue(nil) {
            SZTrace.instant("shadowed")
        }
    }
    #expect(SZTrace.take(turnID: turnID).isEmpty)
}

@Test func fenceEndsWithBeginTimeContextAfterContextChanged() {
    let turnA = UUID(), turnB = UUID()
    let fence = SZTrace.$context.withValue(SZTraceContext(turnID: turnA, scopeKey: "a")) {
        SZTrace.begin("crossing")
    }
    // Context is different (gone) by end-time — the event still lands on turn A.
    SZTrace.$context.withValue(SZTraceContext(turnID: turnB, scopeKey: "b")) {
        fence.end()
    }
    #expect(SZTrace.take(turnID: turnA).count == 1)
    #expect(SZTrace.take(turnID: turnB).isEmpty)
}

@Test func spansParentNestedFences() {
    let turnID = UUID()
    let ctx = SZTraceContext(turnID: turnID, scopeKey: "scope")
    SZTrace.$context.withValue(ctx) {
        SZTrace.span("outer") {
            SZTrace.span("inner") {
                SZTrace.instant("leaf")
            }
            SZTrace.instant("sibling")
        }
    }
    let events = SZTrace.take(turnID: turnID)
    let outer = events.first { $0.stage == "outer" }
    let inner = events.first { $0.stage == "inner" }
    let leaf = events.first { $0.stage == "leaf" }
    let sibling = events.first { $0.stage == "sibling" }
    #expect(outer?.parentID == nil && outer?.id != nil)
    #expect(inner?.parentID == outer?.id)
    #expect(leaf?.parentID == inner?.id)                   // instants attach to the ambient span
    #expect(sibling?.parentID == outer?.id)
}

@Test func closingSpanDerivesMetadataFromTheResultAndStillParents() {
    let turnID = UUID()
    let ctx = SZTraceContext(turnID: turnID, scopeKey: "scope")
    SZTrace.$context.withValue(ctx) {
        let value = SZTrace.span("tool", detail: "name",
                                 closing: { (result: String) in
                                     (detail: "name", addedTokens: result.count / 4)
                                 }) {
            SZTrace.instant("nested")
            return String(repeating: "x", count: 400)
        }
        #expect(value.count == 400)
    }
    let events = SZTrace.take(turnID: turnID)
    let tool = events.first { $0.stage == "tool" }
    #expect(tool?.addedTokens == 100)
    #expect(tool?.detail == "name")
    #expect(events.first { $0.stage == "nested" }?.parentID == tool?.id)
    // A thrown body records with the begin-time detail and no token stamp. (Fresh turn — the
    // first take() tombstoned `turnID`.)
    struct Boom: Error {}
    let secondTurn = UUID()
    SZTrace.$context.withValue(SZTraceContext(turnID: secondTurn, scopeKey: "scope")) {
        #expect(throws: Boom.self) {
            try SZTrace.span("thrower", detail: "kept",
                             closing: { (_: Int) in (detail: "unreached", addedTokens: 9) }) {
                throw Boom()
            }
        }
    }
    let thrown = SZTrace.take(turnID: secondTurn).first { $0.stage == "thrower" }
    #expect(thrown?.detail == "kept")
    #expect(thrown?.addedTokens == nil)
}

@Test func spanRecordsEvenWhenBodyThrows() {
    struct Boom: Error {}
    let turnID = UUID()
    let ctx = SZTraceContext(turnID: turnID, scopeKey: "scope")
    SZTrace.$context.withValue(ctx) {
        #expect(throws: Boom.self) {
            try SZTrace.span("throwing") { throw Boom() }
        }
    }
    #expect(SZTrace.take(turnID: turnID).first?.stage == "throwing")   // a failing call still took time
}

@Test func asyncSpanMeasuresAndParents() async {
    let turnID = UUID()
    let ctx = SZTraceContext(turnID: turnID, scopeKey: "scope")
    await SZTrace.$context.withValue(ctx) {
        await SZTrace.span("async-outer") {
            SZTrace.instant("inside")
        }
    }
    let events = SZTrace.take(turnID: turnID)
    let outer = events.first { $0.stage == "async-outer" }
    #expect(outer?.duration != nil)
    #expect(events.first { $0.stage == "inside" }?.parentID == outer?.id)
}
