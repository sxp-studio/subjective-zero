// SPDX-License-Identifier: AGPL-3.0-only
// `SZHost.syncAgentPack` — the materialization rules: ours-or-theirs by content, so a
// bundle refresh lands in either direction, a user edit stays, and what the bundle stops
// shipping is pruned. Plus the install key that gives each app its own copy to sync.
import Foundation
import Testing
@testable import SubjectiveZero

private struct Fixture {
    let root: URL
    var bundle: URL { root.appending(path: "bundle/director") }
    var dest: URL { root.appending(path: "materialized/director") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "sz-pack-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    }

    func write(_ text: String, bundled relative: String, mtime: Date? = nil) throws {
        try write(text, at: bundle.appending(path: relative), mtime: mtime)
    }
    func write(_ text: String, materialized relative: String, mtime: Date? = nil) throws {
        try write(text, at: dest.appending(path: relative), mtime: mtime)
    }
    private func write(_ text: String, at url: URL, mtime: Date?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
    }
    func materialized(_ relative: String) -> String? {
        try? String(contentsOf: dest.appending(path: relative), encoding: .utf8)
    }
    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: dest.appending(path: relative).path)
    }
    func sync(previous: [String: String] = [:]) throws -> [String: String] {
        try SZHost.syncAgentPack(from: bundle, to: dest, previous: previous)
    }
    func tearDown() { try? FileManager.default.removeItem(at: root) }
}

private func hash(_ text: String) -> String { SZHost.contentHash(Data(text.utf8)) }

@Test func firstSyncCopiesEverythingAndRecordsHashes() throws {
    let f = try Fixture(); defer { f.tearDown() }
    try f.write("{}", bundled: "agent.json")
    try f.write("let step = 1", bundled: "steps/door/Step.swift")
    let manifest = try f.sync()
    #expect(f.materialized("agent.json") == "{}")
    #expect(f.materialized("steps/door/Step.swift") == "let step = 1")
    #expect(manifest == ["agent.json": hash("{}"), "steps/door/Step.swift": hash("let step = 1")])
}

@Test func ourCopyFollowsTheBundleInEitherDirection() throws {
    let f = try Fixture(); defer { f.tearDown() }
    // An older bundle (mtime in the past) shipping different bytes than the copy we wrote:
    // the copy is still ours by content, so it follows — a downgrade, or a stale build
    // sharing this Application Support, cannot leave the newer version behind.
    try f.write("v0.2.7", bundled: "agent.json", mtime: Date(timeIntervalSinceNow: -86_400))
    try f.write("v0.2.8", materialized: "agent.json")
    let manifest = try f.sync(previous: ["agent.json": hash("v0.2.8")])
    #expect(f.materialized("agent.json") == "v0.2.7")
    #expect(manifest["agent.json"] == hash("v0.2.7"))
}

/// The shape a shipped prompt fix arrives in: our copy is untouched (it still hashes to what
/// the manifest says we wrote) and the new bundle differs, so it refreshes on the first launch
/// and the manifest records what it now holds.
@Test func anUntouchedCopyTakesANewerBundleOnTheFirstLaunch() throws {
    let f = try Fixture(); defer { f.tearDown() }
    try f.write("triage v2", bundled: "prompts/triage.md.mustache")
    try f.write("triage v1", materialized: "prompts/triage.md.mustache")
    try f.write("let step = 2", bundled: "steps/door/Step.swift")
    try f.write("let step = 1", materialized: "steps/door/Step.swift")
    let manifest = try f.sync(previous: [
        "prompts/triage.md.mustache": hash("triage v1"),
        "steps/door/Step.swift": hash("let step = 1"),
    ])
    #expect(f.materialized("prompts/triage.md.mustache") == "triage v2")
    #expect(f.materialized("steps/door/Step.swift") == "let step = 2")
    // Recorded as the bundle's bytes, not the ones we replaced — a second pass is a no-op.
    #expect(manifest == ["prompts/triage.md.mustache": hash("triage v2"),
                         "steps/door/Step.swift": hash("let step = 2")])
    #expect(try f.sync(previous: manifest) == manifest)
}

/// Two apps never write one copy: the key follows the app bundle's path, so a worktree build
/// and the app xcodebuild launches to host these tests cannot overwrite each other's packs.
@Test func eachAppBundleGetsItsOwnPackCopy() {
    let installed = URL(filePath: "/Applications/SubjectiveZero.app")
    let built = URL(filePath: "/Users/x/DerivedData/Build/Products/Debug/SubjectiveZero.app")
    #expect(SZHost.packInstallKey(forAppAt: installed) != SZHost.packInstallKey(forAppAt: built))
    // Stable for one app, so its copy — and the user's edits in it — survive an update.
    #expect(SZHost.packInstallKey(forAppAt: installed) == SZHost.packInstallKey(forAppAt: installed))
    #expect(SZHost.packInstallKey(forAppAt: installed)
            == SZHost.packInstallKey(forAppAt: URL(filePath: "/Applications/./SubjectiveZero.app")))
    #expect(SZHost.packInstallKey(forAppAt: installed).count == 8)
}

/// The packs root and its manifest carry the same key, and the manifest stays beside the root
/// rather than inside it (the root is enumerated as a pack library).
@MainActor @Test func theManifestSitsBesideThePackCopyItDescribes() {
    let root = SZHost.materializedAgentPacksRoot
    let manifest = SZHost.materializedManifestURL(for: "director")
    #expect(root.lastPathComponent == SZHost.packInstallKey)
    #expect(manifest.deletingLastPathComponent().lastPathComponent == SZHost.packInstallKey)
    #expect(manifest.path.hasPrefix(SZHost.supportRoot.appending(path: "agent-pack-manifests").path))
    #expect(!manifest.path.hasPrefix(root.path))
}

/// An override root is the user's own tree: the host reads it and never writes it.
@Test func anOverriddenPacksRootIsNeverMaterializedInto() {
    #expect(!SZHost.packsRootIsOverridden)
    setenv("SZ_AGENT_PACKS", "/tmp/sz-packs-of-my-own", 1)
    defer { unsetenv("SZ_AGENT_PACKS") }
    #expect(SZHost.packsRootIsOverridden)
    setenv("SZ_AGENT_PACKS", "", 1)
    #expect(!SZHost.packsRootIsOverridden)   // set-but-empty is not an override
}

@Test func aUserEditStaysAndKeepsItsRecordedHash() throws {
    let f = try Fixture(); defer { f.tearDown() }
    try f.write("shipped v2", bundled: "prompts/chat.md.mustache")
    try f.write("my own words", materialized: "prompts/chat.md.mustache",
                mtime: Date(timeIntervalSinceNow: -86_400))   // even an OLD edit is theirs
    let manifest = try f.sync(previous: ["prompts/chat.md.mustache": hash("shipped v1")])
    #expect(f.materialized("prompts/chat.md.mustache") == "my own words")
    // Recorded as what WE last wrote — the file reads as theirs until it matches that again.
    #expect(manifest["prompts/chat.md.mustache"] == hash("shipped v1"))
}

@Test func aLegacyManifestFallsBackToMtimeAndNeverClaimsTheirBytes() throws {
    let f = try Fixture(); defer { f.tearDown() }
    let old = Date(timeIntervalSinceNow: -86_400)
    // Path-list manifests (before hashes) read with empty hashes → mtime rule.
    try f.write("bundle newer", bundled: "a.json")
    try f.write("stale copy", materialized: "a.json", mtime: old)
    try f.write("bundle older", bundled: "b.json", mtime: old)
    try f.write("kept — maybe theirs", materialized: "b.json")
    let manifest = try f.sync(previous: ["a.json": "", "b.json": ""])
    #expect(f.materialized("a.json") == "bundle newer")
    #expect(manifest["a.json"] == hash("bundle newer"))
    #expect(f.materialized("b.json") == "kept — maybe theirs")
    #expect(manifest["b.json"] == nil)   // no guess: unrecorded until we have written it
}

@Test func legacyManifestDecodesAsEmptyHashes() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "sz-manifest-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(#"["agent.json","graphs/agentic.json"]"#.utf8).write(to: url)
    #expect(SZHost.materializedManifest(at: url) == ["agent.json": "", "graphs/agentic.json": ""])
    try Data(#"{"agent.json":"abc"}"#.utf8).write(to: url)
    #expect(SZHost.materializedManifest(at: url) == ["agent.json": "abc"])
}

@Test func prunesWhatWeWroteAndTheBundleDropped_keepsTheUsersOwnFiles() throws {
    let f = try Fixture(); defer { f.tearDown() }
    try f.write("{}", bundled: "agent.json")
    try f.write("{}", materialized: "agent.json")
    try f.write("old variant", materialized: "graphs/agentic.json")        // ours, dropped
    try f.write("mine", materialized: "graphs/mine.json")                  // never in a manifest
    try f.write("old step", materialized: "steps/resuming/Step.swift")     // ours, dropped
    let manifest = try f.sync(previous: [
        "agent.json": hash("{}"), "graphs/agentic.json": hash("old variant"),
        "steps/resuming/Step.swift": hash("old step"),
    ])
    #expect(!f.exists("graphs/agentic.json"))
    #expect(!f.exists("steps/resuming"))          // emptied dir swept
    #expect(f.materialized("graphs/mine.json") == "mine")
    #expect(manifest == ["agent.json": hash("{}")])
}
