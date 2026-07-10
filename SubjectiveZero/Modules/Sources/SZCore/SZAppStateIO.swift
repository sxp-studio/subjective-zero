// SPDX-License-Identifier: AGPL-3.0-only
// Load/save `SZAppState` (docs/STATE.md "App" — panel layout, window size, theme) as
// `app-state.json` in Application Support. Local, per-machine preferences: this is deliberately NOT
// part of a `.subz` project — a project is a portable document and says nothing about how this
// machine's window is arranged. Sibling of SZProjectIO (same pretty-printed human-diffable JSON),
// but forgiving where the project loader is strict: app state is a convenience, so a missing or
// corrupt file quietly becomes "no saved state" rather than a startup error.
import Foundation

public enum SZAppStateIO {
    static let fileName = "app-state.json"

    /// `~/Library/Application Support/SubjectiveZero/app-state.json`
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SubjectiveZero").appending(path: fileName)
    }

    /// nil on a missing or undecodable file — never throws into app startup.
    public static func load(from url: URL = defaultURL) -> SZAppState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SZAppState.self, from: data)
    }

    public static func save(_ state: SZAppState, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SZJSON.encoder().encode(state).write(to: url, options: .atomic)
    }
}
