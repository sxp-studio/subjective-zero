// SPDX-License-Identifier: AGPL-3.0-only
// CROSS-TARGET PIN, side B, for the shipped packs' step declarations. Side A is
// SZAITests' `shippedPackSteps` stub (SZAgentPackTests): the pack gate over there validates
// the shipped packs root with HAND-WRITTEN declarations, because SZAITests may not import
// SZRuntime to compile the sources. This suite closes the loop with the real machinery —
// every `steps/<name>/Step.swift` under the shipped pack root goes through swiftc + dlopen, and
// the declaration JSON its module exports must byte-match the pin below, which mirrors the
// stub field for field. Edit a shipped step, and both sides move together.
import Foundation
import Synchronization
import Testing
@testable import SZRuntime

private let shippedPacksRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()   // SZRuntimeTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // Modules
    .appending(path: "Sources/SZAI/Resources/Agents")

/// agent/step → the declaration JSON the compiled module must export (`SZStepDeclare`
/// encodes with sorted keys). Mirrors SZAITests' `shippedPackSteps` claims exactly.
private let pinnedDeclarations: [String: String] = [
    "director/door": #"{"outcomes":["build","answer","answer-resumed","implement"]}"#,
    "director/work-left": #"{"outcomes":["yes","no"]}"#,
    "coding/door": #"{"outcomes":["implement","continue","chat","chat-resumed"]}"#,
    "debug/door": #"{"outcomes":["answer"]}"#,
]

/// Serialized like the other step suites: each test drives real swiftc invocations.
@Suite(.serialized) @MainActor
struct SZShippedPackStepTests {

    /// Every `Step.swift` on disk under the shipped pack root, keyed `agent/step`. DISCOVERY
    /// decides coverage, not the pin list — a new step cannot ship unpinned.
    private static func discoverStepSources() throws -> [String: URL] {
        let fm = FileManager.default
        var sources: [String: URL] = [:]
        for agent in try fm.contentsOfDirectory(atPath: shippedPacksRoot.path).sorted() {
            let stepsDir = shippedPacksRoot.appending(path: agent).appending(path: "steps")
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
                "shipped steps and the pin diverge — update BOTH this pin and SZAITests' shippedPackSteps stub")

        let runtime = SZStepRuntime()
        let failures = Mutex<[String]>([])
        runtime.onRedCompile = { key, message in
            failures.withLock { $0.append("\(key.agent)/\(key.step): \(message)") }
        }
        for (name, source) in sources.sorted(by: { $0.key < $1.key }) {
            let dir = FileManager.default.temporaryDirectory
                .appending(path: "sz-pack-step-\(UUID().uuidString)")
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
