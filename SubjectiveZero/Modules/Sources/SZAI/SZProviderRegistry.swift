// SPDX-License-Identifier: AGPL-3.0-only
// The set of providers SubZ ships (claude + codex + grok + pi + opencode), and lookup by id. Adding a backend =
// add a Providers/SZ<Name>Provider.swift conforming to SZProvider and list it here.
import Foundation

public struct SZProviderRegistry: Sendable {
    public let providers: [any SZProvider]
    public let defaultProviderID: String

    public init(providers: [any SZProvider], defaultProviderID: String) {
        self.providers = providers
        self.defaultProviderID = defaultProviderID
    }

    /// The bundled providers, in selection order.
    public static let shared = SZProviderRegistry(
        providers: [SZClaudeProvider(), SZCodexProvider(), SZGrokProvider(), SZPiProvider(), SZOpenCodeProvider()],
        defaultProviderID: SZClaudeProvider.providerID
    )

    public func provider(id: String) -> (any SZProvider)? {
        providers.first { $0.id == id }
    }

    public var defaultProvider: any SZProvider {
        provider(id: defaultProviderID) ?? providers[0]
    }
}
