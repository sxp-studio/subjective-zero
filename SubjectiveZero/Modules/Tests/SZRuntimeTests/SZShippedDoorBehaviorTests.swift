// SPDX-License-Identifier: AGPL-3.0-only
// The shipped doors' BEHAVIOR, driven through the real toolchain — swiftc + dlopen on the
// exact `Step.swift` files the app ships, evaluated against hand-written facts documents.
// `SZShippedPackStepTests` pins what each step DECLARES; this suite pins what each step
// DECIDES, fork by fork — so an edit that keeps the outcome list but changes a ruling
// (dropping the granted-run fast-path, inverting the attempt fork) cannot ship green.
import Foundation
import Synchronization
import Testing
@testable import SZRuntime

private let shippedPacksRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()   // SZRuntimeTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // Modules
    .appending(path: "Sources/SZAI/Resources/Agents")

/// Serialized like the other step suites: each compile drives a real swiftc.
@Suite(.serialized) @MainActor
struct SZShippedDoorBehaviorTests {

    private func compiled(_ agent: String, _ step: String) throws -> (loader: SZStepLoader, dir: URL) {
        let source = shippedPacksRoot.appending(path: "\(agent)/steps/\(step)/Step.swift")
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sz-door-behavior-\(UUID().uuidString)")
        let dylib = try SZToolchain().compile(stepSource: source,
                                              into: dir.appending(path: "build"))
        let loader = SZStepLoader()
        try loader.load(dylib: dylib, runtimeLoadsDir: dir.appending(path: "runtime-loads"))
        return (loader, dir)
    }

    /// Evaluate against `facts`, recording every ask; `reply` answers them all.
    private func decide(_ loader: SZStepLoader, facts: String,
                        reply: String = "{}") async -> (outcome: SZStepEvalResult, asks: [String]) {
        let asked = Mutex<[String]>([])
        let outcome = await loader.evaluate(factsJSON: facts) { request in
            asked.withLock { $0.append(request) }
            return reply
        }
        return (outcome, asked.withLock { $0 })
    }

    // MARK: - director/door

    @Test func aGrantedRunEntersTheBuildLaneWithoutSpendingAToken() async throws {
        let (loader, dir) = try compiled("director", "door")
        defer { try? FileManager.default.removeItem(at: dir) }
        let facts = #"{"message": "build it", "resuming": true, "pendingTasks": [], "run": {"workSet": ["\#(UUID().uuidString)"], "round": 1, "roundCap": 2, "steers": [], "instruction": "build it"}}"#
        let (outcome, asks) = await decide(loader, facts: facts)
        #expect(outcome == .outcome("build"))
        // The fleet path spends ZERO model calls: a granted run is pre-ruled, never re-triaged.
        #expect(asks.isEmpty)
    }

    @Test func anImplementRulingCarriesTheRequestBuildEffect() async throws {
        let (loader, dir) = try compiled("director", "door")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (outcome, asks) = await decide(
            loader, facts: #"{"message": "make it warmer", "resuming": false, "pendingTasks": []}"#,
            reply: #"{"outcome": "implement"}"#)
        #expect(outcome == .outcome(#"{"effects":["requestBuild"],"outcome":"implement"}"#))
        #expect(asks.count == 1)
        #expect(asks[0].contains(#""template":"triage""#))
    }

    @Test func anAmendRulingNeedsSomethingScheduledToFoldInto() async throws {
        let (loader, dir) = try compiled("director", "door")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ruling = #"{"outcome": "amend"}"#
        let scheduled = UUID().uuidString

        // With work waiting, the follow-up takes the amend lane and spends nothing on a build.
        let (folds, _) = await decide(
            loader,
            facts: #"{"message": "actually blue", "resuming": false, "pendingTasks": ["\#(scheduled)"]}"#,
            reply: ruling)
        #expect(folds == .outcome("amend"))

        // With NOTHING scheduled the same ruling cannot stand — there is no task to fold into, so
        // the ask becomes a fresh one rather than routing to a turn with no work to do.
        let (fresh, _) = await decide(
            loader, facts: #"{"message": "actually blue", "resuming": false, "pendingTasks": []}"#,
            reply: ruling)
        #expect(fresh == .outcome(#"{"effects":["requestBuild"],"outcome":"implement"}"#))
    }

    @Test func proseIsAnsweredColdOrResumedOnTheScopesSession() async throws {
        let (loader, dir) = try compiled("director", "door")
        defer { try? FileManager.default.removeItem(at: dir) }
        let answer = #"{"outcome": "answer"}"#
        let cold = await decide(loader, facts: #"{"message": "hi", "resuming": false, "pendingTasks": []}"#, reply: answer)
        #expect(cold.outcome == .outcome("answer"))
        let resumed = await decide(loader, facts: #"{"message": "hi again", "resuming": true, "pendingTasks": []}"#, reply: answer)
        #expect(resumed.outcome == .outcome("answer-resumed"))
    }

    // MARK: - coding/door

    @Test func anAssignmentImplementsColdAndContinuesOnRetry() async throws {
        let (loader, dir) = try compiled("coding", "door")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = await decide(loader,
            facts: #"{"message": "", "resuming": false, "pendingTasks": [], "assignment": {"attempt": 1}}"#)
        #expect(first.outcome == .outcome("implement"))
        let retry = await decide(loader,
            facts: #"{"message": "", "resuming": true, "pendingTasks": [], "assignment": {"attempt": 2, "note": "port math was off"}}"#)
        #expect(retry.outcome == .outcome("continue"))
        // The whole coding surface is deterministic — not one model call.
        #expect(first.asks.isEmpty && retry.asks.isEmpty)
    }

    @Test func unassignedProseIsTriagedAndAQuestionStaysAChat() async throws {
        let (loader, dir) = try compiled("coding", "door")
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = #"{"outcome": "chat"}"#
        let cold = await decide(loader, facts: #"{"message": "what does this node do?", "resuming": false, "pendingTasks": []}"#,
                                reply: chat)
        #expect(cold.outcome == .outcome("chat"))
        let resumed = await decide(loader, facts: #"{"message": "and now?", "resuming": true, "pendingTasks": []}"#,
                                   reply: chat)
        #expect(resumed.outcome == .outcome("chat-resumed"))
        // One triage ask each — the model judges prose; the session fork is mechanical.
        #expect(cold.asks.count == 1 && resumed.asks.count == 1)
        #expect(cold.asks[0].contains(#""template":"triage""#))
    }

    @Test func aChangeRequestIsRuledIntoTheEditLane() async throws {
        let (loader, dir) = try compiled("coding", "door")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (outcome, asks) = await decide(
            loader, facts: #"{"message": "add a toggle between the two effects", "resuming": true, "pendingTasks": []}"#,
            reply: #"{"outcome": "edit"}"#)
        #expect(outcome == .outcome("edit"))
        #expect(asks.count == 1)
        // The ruling ignores the session fork — a first-contact change request edits too.
        let cold = await decide(
            loader, facts: #"{"message": "make it twice as slow", "resuming": false, "pendingTasks": []}"#,
            reply: #"{"outcome": "edit"}"#)
        #expect(cold.outcome == .outcome("edit"))
    }

    // MARK: - debug/door + director/work-left

    @Test func theDebugDoorAnswersEverythingWithoutAsking() async throws {
        let (loader, dir) = try compiled("debug", "door")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (outcome, asks) = await decide(loader, facts: #"{"message": "why is it black?", "resuming": false, "pendingTasks": []}"#)
        #expect(outcome == .outcome("answer"))
        #expect(asks.isEmpty)
    }

    @Test func theWorkLeftGateReadsTheRunsWorkSet() async throws {
        let (loader, dir) = try compiled("director", "work-left")
        defer { try? FileManager.default.removeItem(at: dir) }
        let owing = await decide(loader,
            facts: #"{"message": "", "resuming": true, "pendingTasks": [], "run": {"workSet": ["\#(UUID().uuidString)"], "round": 2, "roundCap": 2, "steers": [], "instruction": ""}}"#)
        #expect(owing.outcome == SZStepEvalResult.outcome("yes"))
        let settled = await decide(loader,
            facts: #"{"message": "", "resuming": true, "pendingTasks": [], "run": {"workSet": [], "round": 2, "roundCap": 2, "steers": [], "instruction": ""}}"#)
        #expect(settled.outcome == SZStepEvalResult.outcome("no"))
    }
}
