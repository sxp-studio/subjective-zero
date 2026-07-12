// SPDX-License-Identifier: AGPL-3.0-only
// Load/save the dynamic provider model catalogs (`SZProviderModelCatalog`, keyed by provider id)
// as `provider-catalogs.json` in Application Support — the last-known truth a runtime-enumerated
// provider (pi) serves offline, next relaunch, until a fresh fetch lands. Sibling of SZCore's
// SZAppStateIO (same directory, same pretty-printed JSON, same forgiving load: a missing or
// corrupt file is "no catalogs yet", never a startup error). Lives in SZAI, not SZCore, because
// the catalog is a provider-seam type; per-machine like app-state, never part of a `.subz` project.
import Foundation
import SZCore

public enum SZProviderCatalogIO {
    static let fileName = "provider-catalogs.json"

    /// `~/Library/Application Support/SubjectiveZero/provider-catalogs.json`
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SubjectiveZero").appending(path: fileName)
    }

    public static func load(from url: URL = defaultURL) -> [String: SZProviderModelCatalog] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: SZProviderModelCatalog].self, from: data)) ?? [:]
    }

    public static func save(_ catalogs: [String: SZProviderModelCatalog], to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SZJSON.encoder().encode(catalogs).write(to: url, options: .atomic)
    }
}
