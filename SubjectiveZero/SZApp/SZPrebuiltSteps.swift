// SPDX-License-Identifier: AGPL-3.0-only
// The shipped agent-pack steps, prebuilt at release time so a user's Mac never compiles them:
// `--prebuild-steps <dir>` compiles every bundled `steps/<name>/Step.swift` into `dir` (the
// bundle's Contents/PlugIns) through the same toolchain the runtime uses, and
// `--verify-prebuilt-steps <dir>` proves the runtime's own lookup finds and loads each one. Both
// run on the bare binary from the release script and exit; SZMain intercepts the flags.
import Foundation
import SZAI
import SZRuntime

enum SZPrebuiltSteps {
    /// Every `<agent>/steps/<step>/Step.swift` under `root`, sorted, keyed like the runtime.
    static func stepSources(under root: URL) -> [(key: SZStepKey, source: URL)] {
        let fm = FileManager.default
        var found: [(key: SZStepKey, source: URL)] = []
        for agent in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted() {
            let stepsDir = root.appending(path: "\(agent)/steps")
            for step in ((try? fm.contentsOfDirectory(atPath: stepsDir.path)) ?? []).sorted() {
                let source = stepsDir.appending(path: "\(step)/Step.swift")
                if fm.fileExists(atPath: source.path) {
                    found.append((SZStepKey(agent: agent, step: step), source))
                }
            }
        }
        return found
    }

    /// Everything in `dir` that is ours: artifacts, and the staging folders an interrupted build leaves.
    private static func leftovers(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("SZStep-") || $0.lastPathComponent.hasPrefix(".prebuilding-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("prebuilt steps: \(message)\n".utf8))
        exit(1)
    }

    /// `--prebuild-steps <dir>`: clear old artifacts, build one per shipped step, exit 0 or 1.
    static func prebuild(into dir: URL) -> Never {
        guard let root = SZAgentPackLoader.bundledRoot else { fail("no bundled agent packs in this binary") }
        let sources = stepSources(under: root)
        guard !sources.isEmpty else { fail("no Step.swift under \(root.path)") }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for stale in leftovers(in: dir) { try FileManager.default.removeItem(at: stale) }
            let toolchain = SZToolchain()
            for (key, source) in sources {
                let artifact = try toolchain.prebuildStep(key: key, source: source, into: dir)
                print("prebuilt \(key.agent)/\(key.step) -> \(artifact.lastPathComponent)")
            }
        } catch {
            fail(String(describing: error))
        }
        exit(0)
    }

    /// `--verify-prebuilt-steps <dir>`: the runtime lookup must hit for every shipped step, each
    /// artifact must load with a declaration, and nothing else of ours may sit in `dir`. Exit 0 or 1.
    static func verify(in dir: URL) -> Never {
        guard let root = SZAgentPackLoader.bundledRoot else { fail("no bundled agent packs in this binary") }
        let toolchain = SZToolchain(prebuiltStepsDir: dir)
        var expected: Set<String> = []
        var problems: [String] = []
        let loads = FileManager.default.temporaryDirectory.appending(path: "sz-verify-prebuilt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: loads) }
        for (key, source) in stepSources(under: root) {
            guard let artifact = toolchain.prebuiltStep(key: key, source: source) else {
                problems.append("\(key.agent)/\(key.step): no artifact for its current source")
                continue
            }
            expected.insert(artifact.lastPathComponent)
            let loader = SZStepLoader()
            do {
                try loader.load(dylib: artifact, runtimeLoadsDir: loads)
                guard loader.declaration != nil else {
                    problems.append("\(key.agent)/\(key.step): loaded but declares nothing"); continue
                }
                print("ok \(key.agent)/\(key.step) \(artifact.lastPathComponent)")
            } catch {
                problems.append("\(key.agent)/\(key.step): \(error)")
            }
        }
        for stray in leftovers(in: dir) where !expected.contains(stray.lastPathComponent) {
            problems.append("stray \(stray.lastPathComponent)")
        }
        guard problems.isEmpty else { fail(problems.joined(separator: "\n")) }
        exit(0)
    }
}
