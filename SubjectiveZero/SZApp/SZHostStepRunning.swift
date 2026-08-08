// SPDX-License-Identifier: AGPL-3.0-only
// The step-execution bridge for the graph orchestrator. SZAI declares the seams (`SZStepRunning`
// for evaluation, the strategy's declarations seam for the pack gate) and may not import
// SZRuntime; SZRuntime owns compiling/loading steps and may not import SZAI. SZApp imports
// both, so this adapter is where a pack's `steps/<name>/Step.swift` becomes a compiled, keyed
// module: scheduled into Application Support build dirs on first use, evaluated through the
// runtime's keyed table (which awaits in-flight compiles), and reused across the run — the
// host holds ONE `SZStepRuntime` for its lifetime, so a fresh adapter's re-schedule coalesces
// into the runtime's latest-source-wins compile rather than a cold table.
import Foundation
import SZAI
import SZCore
import SZRuntime

/// A red compile (or unloadable dylib), surfaced where the pack gate can report it honestly.
struct SZHostStepError: Error, CustomStringConvertible {
    let key: SZStepKey
    let detail: String
    var description: String { "\(key.agent)/steps/\(key.step): \(detail)" }
}

@MainActor
final class SZHostStepRunning: SZStepRunning {
    private let packsRoot: URL
    private let runtime: SZStepRuntime
    /// Keys this adapter has scheduled — schedule once per run; the runtime's evaluate and
    /// declaration reads await the in-flight compile.
    private var scheduled: Set<SZStepKey> = []
    /// Red-compile reasons per key, captured off the runtime's report hook so `declaration`
    /// can tell "the compile failed" (a throw, with the compiler's words) from "the step
    /// declares nothing" (a legal nil).
    private var failures: [SZStepKey: String] = [:]

    init(packsRoot: URL, runtime: SZStepRuntime) {
        self.packsRoot = packsRoot
        self.runtime = runtime
        runtime.onRedCompile = { [weak self] key, detail in self?.failures[key] = detail }
    }

    /// One step's build artifacts: Application Support, keyed like the runtime's table.
    /// Shared with the hot-reload watchers (SZHost+AgentPacks.swift), so an edit-triggered
    /// recompile lands in the same dirs and coalesces with a run's own schedule.
    static func buildRoot(for key: SZStepKey) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SubjectiveZero/agent-steps/\(key.agent)/\(key.step)")
    }

    private func stepSource(_ key: SZStepKey) -> URL {
        packsRoot.appending(path: "\(key.agent)/steps/\(key.step)/Step.swift")
    }

    private func ensureScheduled(_ key: SZStepKey) {
        guard scheduled.insert(key).inserted else { return }
        failures[key] = nil
        let root = Self.buildRoot(for: key)
        runtime.scheduleLoad(key: key, sourceURL: stepSource(key),
                             buildDir: root.appending(path: "build"),
                             runtimeLoadsDir: root.appending(path: "runtime-loads"))
    }

    // MARK: - SZStepRunning (the engine's evaluation seam)

    func evaluate(agent: String, step: String, factsJSON: String,
                  ask: @escaping @Sendable (String) async throws -> String) async -> SZStepReport {
        let key = SZStepKey(agent: agent, step: step)
        ensureScheduled(key)
        switch await runtime.evaluate(key: key, factsJSON: factsJSON, ask: ask) {
        case .outcome(let payload): return Self.report(payload: payload)
        case .cancelled: return SZStepReport(cancelled: true)
        case .failed(let detail): return SZStepReport(failure: detail)
        }
    }

    /// The SDK's success payload, split: a bare outcome string rides through untouched
    /// (byte-for-byte — the loader stays dumb and so does this for effect-less steps); an
    /// answer that requested effects arrives as the `{"effects": […], "outcome": "…"}`
    /// envelope, which no bare outcome can be mistaken for (outcomes are names, not JSON
    /// objects — and the decode demands BOTH keys).
    static func report(payload: String) -> SZStepReport {
        struct Envelope: Decodable {
            var outcome: String
            var effects: [String]
        }
        if payload.hasPrefix("{"),
           let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(payload.utf8)) {
            return SZStepReport(outcome: envelope.outcome, effects: envelope.effects)
        }
        return SZStepReport(outcome: payload)
    }

    // MARK: - Declarations (the pack gate's seam)

    /// A step's compiled declaration, awaiting its build. nil = the folder carries no source,
    /// or the loaded step declares nothing; throws = the compile went red.
    func declaration(agent: String, step: String) async throws -> SZStepDeclarationInfo? {
        let key = SZStepKey(agent: agent, step: step)
        guard FileManager.default.fileExists(atPath: stepSource(key).path) else { return nil }
        ensureScheduled(key)
        guard let json = await runtime.declarationAwaitingCompile(key: key) else {
            if let detail = failures[key] { throw SZHostStepError(key: key, detail: detail) }
            return nil
        }
        return try JSONDecoder().decode(SZStepDeclarationInfo.self, from: Data(json.utf8))
    }
}
