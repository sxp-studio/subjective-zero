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

@Test func roundTripPreservesPoppedOutPanels() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let popped = [SZPoppedOutPanel(panel: SZPanelID(.viewport, instance: 1),
                                   x: 120, y: 80, width: 640, height: 400)]
    try SZAppStateIO.save(SZAppState(poppedOutPanels: popped), to: url)
    #expect(SZAppStateIO.load(from: url)?.poppedOutPanels == popped)
}

@Test func fileWithoutPoppedOutPanelsStillDecodes() throws {
    // An app-state.json predating pop-out windows (no poppedOutPanels key) → nil, none popped out.
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"windowSize":{"width":1440,"height":900},"theme":"system","defaultProviderID":"claude"}"#.utf8)
        .write(to: url)
    let loaded = SZAppStateIO.load(from: url)
    #expect(loaded != nil)
    #expect(loaded?.poppedOutPanels == nil)
    #expect(loaded?.defaultProviderID == "claude")
}

@Test func legacyKindKeyedPanelLayoutInsideAppStateDecodes() throws {
    // A whole pre-instance app-state.json: the panelLayout subtree carries bare kind strings.
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let legacy = #"""
    {"windowSize":{"width":1440,"height":900},"theme":"system",
     "panelLayout":{"root":{"split":{"orientation":"horizontal","fraction":0.75,
       "leading":{"panel":{"_0":"viewport"}},"trailing":{"panel":{"_0":"chat"}}}},
      "restorePositions":["nodeEditor",{"neighbor":"viewport","zone":"bottom","share":0.4}]}}
    """#
    try Data(legacy.utf8).write(to: url)
    let loaded = SZAppStateIO.load(from: url)
    #expect(loaded?.panelLayout?.root.leafIDs == [.viewport, .chat])
    #expect(loaded?.panelLayout?.restorePositions[.nodeEditor]
            == SZPanelRestorePosition(neighbor: .viewport, zone: .bottom, share: 0.4))
}

@Test func roundTripPreservesRoutingProfiles() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let fastFleet = SZRoutingProfile(
        name: "fast-fleet",
        agents: [
            "director": ["planner": SZRouteEnvelope(providerID: "claude", reasoningEffort: "max"),
                         "sorter": SZRouteEnvelope(providerID: "claude", model: "claude-haiku-4-5")],
            "coding": ["builder-default": SZRouteEnvelope(providerID: "codex"),
                       "builder-heavy": SZRouteEnvelope(providerID: "claude",
                                                        model: "claude-opus-5", fastMode: true)],
        ])
    try SZAppStateIO.save(SZAppState(routingProfiles: [fastFleet],
                                     activeRoutingProfileName: "fast-fleet"), to: url)
    let loaded = SZAppStateIO.load(from: url)
    #expect(loaded?.routingProfiles == [fastFleet])
    #expect(loaded?.activeRoutingProfileName == "fast-fleet")
}

@Test func fileWithoutRoutingProfilesStillDecodes() throws {
    // An app-state.json predating routing (no routingProfiles key) → nil, routing off.
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"windowSize":{"width":1440,"height":900},"theme":"system","defaultProviderID":"claude"}"#.utf8)
        .write(to: url)
    let loaded = SZAppStateIO.load(from: url)
    #expect(loaded != nil)
    #expect(loaded?.routingProfiles == nil)
    #expect(loaded?.activeRoutingProfileName == nil)
}

@Test func preSlotProfileShapesDecodeToAnEmptyTableNeverAGuess() throws {
    // The short-lived pre-slot shape (per-agent envelopes) carries keys the slot world
    // can't honestly map — the profile keeps its name and decodes with no routes.
    let flat = #"{"name": "p", "agents": {"coding": {"providerID": "codex"}}}"#
    let profile = try JSONDecoder().decode(SZRoutingProfile.self, from: Data(flat.utf8))
    #expect(profile.name == "p")
    #expect(profile.agents.isEmpty)
}

@Test func anEnvelopeWithUnknownKeysDecodesItsKnownFields() throws {
    // A profile written by a future build (an extra envelope knob) still reads back —
    // tolerant decode is the schema's versioning story.
    let json = #"{"providerID":"codex","model":"gpt-6","speedTier":"turbo"}"#
    let envelope = try JSONDecoder().decode(SZRouteEnvelope.self, from: Data(json.utf8))
    #expect(envelope.providerID == "codex")
    #expect(envelope.model == "gpt-6")
}

@Test func mergingAFragmentRespectsTheKeepMineRule() {
    // A pack's recommendation lands per its conflict answer: replacing rewrites set slots,
    // keep-mine fills only silence. Other agents' tables never move.
    let mine = SZRouteEnvelope(providerID: "codex")
    let theirs = SZRouteEnvelope(providerID: "claude", model: "claude-haiku-4-5")
    let profile = SZRoutingProfile(name: "p", agents: [
        "coding": ["builder": mine],
        "director": ["planner": mine],
    ])
    let fragment = ["builder": theirs, "sorter": theirs]

    let kept = profile.merging(fragment, agent: "coding", replacingExisting: false)
    #expect(kept.envelope(agent: "coding", slot: "builder") == mine)
    #expect(kept.envelope(agent: "coding", slot: "sorter") == theirs)

    let replaced = profile.merging(fragment, agent: "coding", replacingExisting: true)
    #expect(replaced.envelope(agent: "coding", slot: "builder") == theirs)
    #expect(replaced.envelope(agent: "coding", slot: "sorter") == theirs)
    #expect(replaced.envelope(agent: "director", slot: "planner") == mine)
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
