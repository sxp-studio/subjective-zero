// SPDX-License-Identifier: AGPL-3.0-only
// Pins the recordPrefs app-state key: roundtrip, and the decode-compatibility contract (an older
// file without the key, or with a partial one, still decodes).
import Foundation
import Testing
@testable import SZCore

@Test func recordPrefsRoundTrip() throws {
    let prefs = SZRecordPrefs(resolution: 2160, frameRate: 30, codec: "hevc", ratio: "tall",
                              crop: SZRect(x: 0.25, y: 0, width: 0.5, height: 1), seenSettings: true)
    let state = SZAppState(recordPrefs: prefs)
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(SZAppState.self, from: data)
    #expect(decoded.recordPrefs == prefs)
}

@Test func appStateWithoutRecordPrefsDecodes() throws {
    let bare = try JSONDecoder().decode(
        SZAppState.self,
        from: Data(#"{"windowSize":{"width":1440,"height":900},"theme":"system"}"#.utf8))
    #expect(bare.recordPrefs == nil)
}

@Test func partialRecordPrefsDecode() throws {
    let json = #"{"windowSize":{"width":1440,"height":900},"theme":"system","recordPrefs":{"frameRate":30}}"#
    let state = try JSONDecoder().decode(SZAppState.self, from: Data(json.utf8))
    #expect(state.recordPrefs?.frameRate == 30)
    #expect(state.recordPrefs?.crop == nil)
}
