// SPDX-License-Identifier: AGPL-3.0-only
// Prebuilt shipped steps: the artifact name is a pure function of the inputs, a bundled artifact
// for the exact source bytes is mapped with no compile at all, an edited source misses and
// compiles as before, and the same artifact is never mapped twice.
import Foundation
import Testing
@testable import SZRuntime

private func tempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "sz-prebuilt-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeStep(_ source: String, in dir: URL) throws -> URL {
    let url = dir.appending(path: "Step.swift")
    try source.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func fixedOutcomeStep(_ outcome: String) -> String {
    """
    let step = SZStep(outcomes: ["\(outcome)"]) { _ in "\(outcome)" }
    """
}

private let chatFacts = #"{"message": "hey", "resuming": false, "pendingTasks": [], "runningTasks": []}"#
private let noAsk: SZStepAskRunner = { _ in throw CancellationError() }

private func tool(_ path: String, _ args: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let out = Pipe()
    process.standardOutput = out
    process.standardError = out
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Serialized: the prebuild runs real swiftc invocations.
@Suite(.serialized) @MainActor
struct SZPrebuiltStepTests {

    @Test func theArtifactNameIsPureAndKeyedByEveryInput() {
        let key = SZStepKey(agent: "director", step: "door")
        let source = Data("let step = 1".utf8)
        func name(key k: SZStepKey = key, source s: Data = source, kit: String = "kit", abi: Int32 = 5,
                  targets: [String] = ["a", "b"], salt: String = "1") -> String {
            SZToolchain.prebuiltStepArtifactName(key: k, source: s, kit: kit, abi: abi, targets: targets, salt: salt)
        }
        let base = name()
        #expect(base == name())
        #expect(base.hasPrefix("SZStep-director-door-") && base.hasSuffix(".dylib"))
        let variants = [
            name(source: Data("let step = 2".utf8)),
            name(key: SZStepKey(agent: "coding", step: "door")),
            name(key: SZStepKey(agent: "director", step: "work-left")),
            name(kit: "kit2"),
            name(abi: 6),
            name(targets: ["a"]),
            name(salt: "2"),
        ]
        #expect(Set(variants).count == variants.count)
        #expect(!variants.contains(base))
    }

    @Test func aBundledArtifactIsMappedWithNoCompile() async throws {
        let bundle = try tempDir("bundle")
        let sourceDir = try tempDir("source")
        let source = try writeStep(fixedOutcomeStep("shipped"), in: sourceDir)
        let loads = sourceDir.appending(path: "runtime-loads")
        let key = SZStepKey(agent: "director", step: "door")

        let artifact = try SZToolchain().prebuildStep(key: key, source: source, into: bundle)
        #expect(artifact.deletingLastPathComponent().standardizedFileURL == bundle.standardizedFileURL)
        let archs = try tool("/usr/bin/lipo", ["-archs", artifact.path])
        #expect(archs.contains("arm64") && archs.contains("x86_64"))
        let build = try tool("/usr/bin/vtool", ["-arch", "arm64", "-show-build", artifact.path])
        #expect(build.contains("minos 15.0"))

        // The lookup finds it for these exact bytes, and not for a different key.
        let toolchain = SZToolchain(prebuiltStepsDir: bundle)
        #expect(toolchain.prebuiltStep(key: key, source: source) == artifact)
        #expect(toolchain.prebuiltStep(key: SZStepKey(agent: "coding", step: "door"), source: source) == nil)
        #expect(toolchain.isPrebuilt(artifact))

        // The runtime maps it without ever creating the build directory: a compile always would.
        let runtime = SZStepRuntime(prebuiltStepsDir: bundle)
        let buildDir = sourceDir.appending(path: "never-built")
        runtime.scheduleLoad(key: key, sourceURL: source, buildDir: buildDir, runtimeLoadsDir: loads)
        #expect(await runtime.evaluate(key: key, factsJSON: chatFacts, ask: noAsk) == .outcome("shipped"))
        #expect(!FileManager.default.fileExists(atPath: buildDir.path))

        // Scheduling the same bytes again compiles nothing either.
        runtime.scheduleLoad(key: key, sourceURL: source, buildDir: buildDir, runtimeLoadsDir: loads)
        #expect(await runtime.evaluate(key: key, factsJSON: chatFacts, ask: noAsk) == .outcome("shipped"))
        #expect(!FileManager.default.fileExists(atPath: buildDir.path))

        // An edited source misses the bundle and compiles as before.
        try fixedOutcomeStep("edited").write(to: source, atomically: true, encoding: .utf8)
        #expect(toolchain.prebuiltStep(key: key, source: source) == nil)
        runtime.scheduleLoad(key: key, sourceURL: source, buildDir: buildDir, runtimeLoadsDir: loads)
        #expect(await runtime.evaluate(key: key, factsJSON: chatFacts, ask: noAsk) == .outcome("edited"))
        let compiled = buildDir.appending(path: "Step.dylib")
        let editedBytes = try Data(contentsOf: compiled)

        // Reverting to the shipped bytes compiles too (a fresh module, so the artifact changes):
        // the bundled artifact was mapped once already and nothing is ever dlclosed.
        try fixedOutcomeStep("shipped").write(to: source, atomically: true, encoding: .utf8)
        runtime.scheduleLoad(key: key, sourceURL: source, buildDir: buildDir, runtimeLoadsDir: loads)
        #expect(await runtime.evaluate(key: key, factsJSON: chatFacts, ask: noAsk) == .outcome("shipped"))
        #expect(try Data(contentsOf: compiled) != editedBytes)
    }

    @Test func aMissingPrebuiltDirectoryBehavesLikeTheDefaultRuntime() async throws {
        let sourceDir = try tempDir("plain")
        let source = try writeStep(fixedOutcomeStep("compiled"), in: sourceDir)
        let key = SZStepKey(agent: "debug", step: "door")
        let runtime = SZStepRuntime(prebuiltStepsDir: sourceDir.appending(path: "no-such-plugins"))
        let buildDir = sourceDir.appending(path: "build")
        runtime.scheduleLoad(key: key, sourceURL: source, buildDir: buildDir,
                             runtimeLoadsDir: sourceDir.appending(path: "runtime-loads"))
        #expect(await runtime.evaluate(key: key, factsJSON: chatFacts, ask: noAsk) == .outcome("compiled"))
        #expect(FileManager.default.fileExists(atPath: buildDir.path))
    }
}
