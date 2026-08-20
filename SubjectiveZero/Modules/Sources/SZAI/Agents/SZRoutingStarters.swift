// SPDX-License-Identifier: AGPL-3.0-only
// The shipped routing starters, as data (RoutingStarters.json): model, slot, and agent ids
// stay out of host code. The host seeds and protects what this file declares.
import Foundation
import SZCore

/// One shipped starter: the profile, and the provider that must be usable before it seeds.
public struct SZRoutingStarter: Codable, Equatable, Sendable {
    public var requiresProvider: String
    public var profile: SZRoutingProfile

    public init(requiresProvider: String, profile: SZRoutingProfile) {
        self.requiresProvider = requiresProvider
        self.profile = profile
    }
}

public enum SZRoutingStarters {
    /// The bundled starters; [] in a build whose bundle carries no resources.
    public static func load() -> [SZRoutingStarter] {
        guard let url = Bundle.module.url(forResource: "RoutingStarters", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SZRoutingStarter].self, from: data)) ?? []
    }
}
