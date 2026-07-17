// SPDX-License-Identifier: AGPL-3.0-only
// SZAppStateIO — app-state.json round trip and the forgiving load path (missing/corrupt files are
// "no saved state", never a startup error).
import Foundation
import Testing
@testable import SZCore

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "sz-appstate-tests-\(UUID().uuidString)")
        .appending(path: "app-state.json")
}

@Test func roundTripPreservesPanelLayout() throws {
    var layout = SZPanelLayoutState.default
    layout.movePanel(.chat, onto: .viewport, zone: .top)
    layout.removePanel(.nodeEditor)

    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try SZAppStateIO.save(SZAppState(panelLayout: layout), to: url)

    let loaded = SZAppStateIO.load(from: url)
    #expect(loaded?.panelLayout == layout)
}

@Test func missingFileLoadsAsNil() {
    #expect(SZAppStateIO.load(from: temporaryURL()) == nil)
}

@Test func corruptFileLoadsAsNil() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json {{{".utf8).write(to: url)
    #expect(SZAppStateIO.load(from: url) == nil)
}

@Test func fileWithoutPanelLayoutStillDecodes() throws {
    // An app-state.json predating the rearrangeable layout (no panelLayout key).
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"windowSize":{"width":1440,"height":900},"theme":"system"}"#.utf8).write(to: url)
    let loaded = SZAppStateIO.load(from: url)
    #expect(loaded != nil)
    #expect(loaded?.panelLayout == nil)
    // No snapToGrid key either (predates the grid) → nil, which the host reads as ON.
    #expect(loaded?.snapToGrid == nil)
    // No defaultProviderID key (predates provider setup) → nil, which re-presents the sheet.
    #expect(loaded?.defaultProviderID == nil)
}

@Test func roundTripPreservesSnapToGrid() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try SZAppStateIO.save(SZAppState(snapToGrid: false), to: url)
    #expect(SZAppStateIO.load(from: url)?.snapToGrid == false)
}

@Test func roundTripPreservesDefaultProviderID() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try SZAppStateIO.save(SZAppState(defaultProviderID: "codex"), to: url)
    #expect(SZAppStateIO.load(from: url)?.defaultProviderID == "codex")
}

@Test func roundTripPreservesRecentProjectPaths() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let recents = ["/tmp/A.subz", "/tmp/B.subz"]
    try SZAppStateIO.save(SZAppState(openProjectPath: "/tmp/A.subz", recentProjectPaths: recents), to: url)
    let loaded = SZAppStateIO.load(from: url)
    #expect(loaded?.recentProjectPaths == recents)
    #expect(loaded?.openProjectPath == "/tmp/A.subz")
}

@Test func fileWithoutRecentsStillDecodes() throws {
    // An app-state.json predating project lifecycle (no recentProjectPaths key).
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"windowSize":{"width":1440,"height":900},"theme":"system","defaultProviderID":"claude"}"#.utf8)
        .write(to: url)
    let loaded = SZAppStateIO.load(from: url)
    #expect(loaded != nil)
    #expect(loaded?.recentProjectPaths == nil)
    #expect(loaded?.defaultProviderID == "claude")   // the new field's absence loses nothing else
}

@Test func roundTripPreservesDisabledProviderIDs() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try SZAppStateIO.save(SZAppState(disabledProviderIDs: ["grok", "pi"]), to: url)
    #expect(SZAppStateIO.load(from: url)?.disabledProviderIDs == ["grok", "pi"])
}

@Test func fileWithoutDisabledProviderIDsStillDecodes() throws {
    // An app-state.json predating per-provider disable (no disabledProviderIDs key).
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"windowSize":{"width":1440,"height":900},"theme":"system","defaultProviderID":"claude"}"#.utf8)
        .write(to: url)
    let loaded = SZAppStateIO.load(from: url)
    #expect(loaded != nil)
    #expect(loaded?.disabledProviderIDs == nil)   // nil means none disabled
    #expect(loaded?.defaultProviderID == "claude")
}

@Test func roundTripPreservesProviderGenerationSettings() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let settings: [String: SZProviderGenerationSettings] = [
        "claude": SZProviderGenerationSettings(model: "opus", fastMode: true),
        "codex": SZProviderGenerationSettings(model: "gpt-5.4", reasoningEffort: "xhigh", fastMode: false),
    ]
    try SZAppStateIO.save(SZAppState(providerGenerationSettings: settings), to: url)
    #expect(SZAppStateIO.load(from: url)?.providerGenerationSettings == settings)
}

@Test func fileWithoutGenerationSettingsStillDecodes() throws {
    // An app-state.json predating per-provider generation settings (no providerGenerationSettings key).
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"windowSize":{"width":1440,"height":900},"theme":"system","defaultProviderID":"claude"}"#.utf8)
        .write(to: url)
    let loaded = SZAppStateIO.load(from: url)
    #expect(loaded != nil)
    #expect(loaded?.providerGenerationSettings == nil)
    #expect(loaded?.defaultProviderID == "claude")
}

@Test func roundTripPreservesTelemetryEnabled() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try SZAppStateIO.save(SZAppState(telemetryEnabled: false), to: url)
    #expect(SZAppStateIO.load(from: url)?.telemetryEnabled == false)
}

@Test func fileWithoutTelemetryEnabledStillDecodes() throws {
    // An app-state.json predating the opt-out (no telemetryEnabled key) → nil, host reads as ON.
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"windowSize":{"width":1440,"height":900},"theme":"system"}"#.utf8).write(to: url)
    let loaded = SZAppStateIO.load(from: url)
    #expect(loaded != nil)
    #expect(loaded?.telemetryEnabled == nil)
}

@Test func noteRecentProjectDedupesToFront() {
    var state = SZAppState(recentProjectPaths: ["/tmp/A.subz", "/tmp/B.subz", "/tmp/C.subz"])
    state.noteRecentProject(path: "/tmp/B.subz")
    #expect(state.recentProjectPaths == ["/tmp/B.subz", "/tmp/A.subz", "/tmp/C.subz"])
}

@Test func noteRecentProjectStartsFromNil() {
    var state = SZAppState()
    state.noteRecentProject(path: "/tmp/A.subz")
    #expect(state.recentProjectPaths == ["/tmp/A.subz"])
}

@Test func noteRecentProjectCapsAtMax() {
    var state = SZAppState()
    for i in 0..<(SZAppState.maxRecentProjects + 3) {
        state.noteRecentProject(path: "/tmp/P\(i).subz")
    }
    #expect(state.recentProjectPaths?.count == SZAppState.maxRecentProjects)
    // Newest first; the oldest fell off the end.
    #expect(state.recentProjectPaths?.first == "/tmp/P\(SZAppState.maxRecentProjects + 2).subz")
    #expect(state.recentProjectPaths?.contains("/tmp/P0.subz") == false)
}
