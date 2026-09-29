// SPDX-License-Identifier: AGPL-3.0-only
// direct account connections and optional coding tools, in setup order.
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
        providers: [SZChatGPTProvider(), SZClaudeProvider(), SZGrokProvider(), SZPiProvider(),
                    SZOpenCodeProvider(), SZMuseCodeProvider()],
        defaultProviderID: SZChatGPTProvider.providerID
    )

    public func provider(id: String) -> (any SZProvider)? {
        providers.first { $0.id == id }
    }

    public var defaultProvider: any SZProvider {
        provider(id: defaultProviderID) ?? providers[0]
    }
}
