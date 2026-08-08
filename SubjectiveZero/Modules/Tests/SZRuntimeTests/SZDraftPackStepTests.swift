// SPDX-License-Identifier: AGPL-3.0-only
// CROSS-TARGET PIN, side B, for the shipped draft packs' step declarations. Side A is
// SZAITests' `draftPackSteps` stub (SZAgentPackTests): the pack gate over there validates
// the AgentsDraft root with HAND-WRITTEN declarations, because SZAITests may not import
// SZRuntime to compile the sources. This suite closes the loop with the real machinery —
// every `steps/<name>/Step.swift` under the draft root goes through swiftc + dlopen, and
// the declaration JSON its module exports must byte-match the pin below, which mirrors the
// stub field for field. Edit a draft step, and both sides move together.
import Foundation
import Synchronization
import Testing
@testable import SZRuntime

private let draftPacksRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()   // SZRuntimeTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // Modules
    .appending(path: "Sources/SZAI/Resources/AgentsDraft")

/// agent/step → the declaration JSON the compiled module must export (`SZStepDeclare`
/// encodes with sorted keys). Mirrors SZAITests' `draftPackSteps` claims exactly.
private let pinnedDeclarations: [String: String] = [
    "director/work-left": #"{"facts":"build","outcomes":["yes","no"]}"#,
    "director/resuming": #"{"facts":"chat","outcomes":["yes","no"]}"#,
    "coding/retrying": #"{"facts":"item","outcomes":["yes","no"]}"#,
    "coding/request-op": #"{"facts":"request","outcomes":["split","merge"]}"#,
]

/// Serialized like the other step suites: each test drives real swiftc invocations.
@Suite(.serialized) @MainActor
struct SZDraftPackStepTests {

    /// Every `Step.swift` on disk under the draft root, keyed `agent/step`. DISCOVERY
    /// decides coverage, not the pin list — a new draft step cannot ship unpinned.
    private static func discoverStepSources() throws -> [String: URL] {
        let fm = FileManager.default
        var sources: [String: URL] = [:]
        for agent in try fm.contentsOfDirectory(atPath: draftPacksRoot.path).sorted() {
            let stepsDir = draftPacksRoot.appending(path: agent).appending(path: "steps")
            guard let steps = try? fm.contentsOfDirectory(atPath: stepsDir.path) else { continue }
            for step in steps.sorted() {
                let source = stepsDir.appending(path: step).appending(path: "Step.swift")
                if fm.fileExists(atPath: source.path) {
                    sources["\(agent)/\(step)"] = source
                }
            }
        }
        return sources
    }

    @Test func everyDraftStepCompilesAndDeclaresWhatThePackGateWasTold() async throws {
        let sources = try Self.discoverStepSources()
        #expect(Set(sources.keys) == Set(pinnedDeclarations.keys),
                "draft steps and the pin diverge — update BOTH this pin and SZAITests' draftPackSteps stub")

        let runtime = SZStepRuntime()
        let failures = Mutex<[String]>([])
        runtime.onRedCompile = { key, message in
            failures.withLock { $0.append("\(key.agent)/\(key.step): \(message)") }
        }
        for (name, source) in sources.sorted(by: { $0.key < $1.key }) {
            let dir = FileManager.default.temporaryDirectory
                .appending(path: "sz-draft-step-\(UUID().uuidString)")
            let parts = name.split(separator: "/")
            let key = SZStepKey(agent: String(parts[0]), step: String(parts[1]))
            runtime.scheduleLoad(key: key, sourceURL: source,
                                 buildDir: dir.appending(path: "build"),
                                 runtimeLoadsDir: dir.appending(path: "runtime-loads"))
            let declaration = await runtime.declarationAwaitingCompile(key: key)
            #expect(declaration == pinnedDeclarations[name],
                    "\(name) declared \(declaration ?? "nothing")")
            runtime.unload(key: key)
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(failures.withLock { $0 }.isEmpty, "\(failures.withLock { $0 })")
    }
}
