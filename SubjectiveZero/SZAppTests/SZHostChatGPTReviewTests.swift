// SPDX-License-Identifier: AGPL-3.0-only
// account catalog generations discard stale completions without blocking replacement fetches.
import Foundation
import Testing
import SZAI
@testable import SubjectiveZero

@MainActor
struct SZHostChatGPTReviewTests {
    @Test func accountChangesReplaceInflightCatalogsAndResetCooldown() async throws {
        let host = SZHost()
        let provider = SZDeferredCatalogProvider()
        let id = provider.id
        host.refreshProviderModelCatalogIfNeeded(provider, transitioned: false)
        try await waitFor { await provider.pending.count == 1 }
        let oldGeneration = try #require(host.catalogRefreshesInFlight[id])
        host.invalidateProviderModelCatalog(id)
        host.refreshProviderModelCatalogIfNeeded(provider, transitioned: false)
        try await waitFor { await provider.pending.count == 2 }
        let replacement = try #require(host.catalogRefreshesInFlight[id])
        #expect(replacement != oldGeneration)
        await provider.pending.complete(0, model: "old-account")
        for _ in 0..<20 { await Task.yield() }
        #expect(host.catalogRefreshesInFlight[id] == replacement)
        #expect(host.providerModelCatalogs[id] == nil)
        await provider.pending.complete(1, model: "selected-account")
        try await waitFor { host.catalogRefreshesInFlight[id] == nil }
        #expect(host.providerModelCatalogs[id]?.defaultModelID == "selected-account")
        host.invalidateProviderModelCatalog(id)
        host.refreshProviderModelCatalogIfNeeded(provider, transitioned: false)
        try await waitFor { await provider.pending.count == 3 }
        await provider.pending.complete(2, model: "third-account")
        try await waitFor { host.catalogRefreshesInFlight[id] == nil }
        #expect(host.providerModelCatalogs[id]?.defaultModelID == "third-account")
    }

    @Test func failedProbeRemainsRecoverableUntilRetrySucceeds() throws {
        let host = SZHost()
        let id = SZChatGPTProvider.providerID
        host.providerHealth[id] = .init(providerID: id, status: .ready, message: "Connected")
        host.providerProbes[id] = .init(providerID: id, status: .healthFailed, message: "Try again")
        var card = try #require(host.providerSetupCards.first { $0.id == id })
        #expect(card.readiness == .failed)
        #expect(!card.isConfirmable)
        host.probingProviders.insert(id)
        card = try #require(host.providerSetupCards.first { $0.id == id })
        #expect(card.isTesting)
        host.probingProviders.remove(id)
        host.providerProbes[id] = .init(providerID: id, status: .ready, message: "Verified", probeVerified: true)
        card = try #require(host.providerSetupCards.first { $0.id == id })
        #expect(card.isConfirmable)
        #expect(!card.isTesting)
    }

    private func waitFor(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await predicate()), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await predicate())
    }
}

private struct SZDeferredCatalogProvider: SZProvider {
    let id = "review-catalog-" + UUID().uuidString
    let pending = SZPendingCatalogs()
    let displayName = "Review catalog"
    let models: [SZProviderModel] = []
    let defaultModel = ""
    let defaultReasoningEffort = ""
    let supportedReasoningEfforts: [String] = []
    let supportsFastMode = false
    let healthArgs: [String] = []
    let installCommand = ""
    let loginCommand = ""
    func refreshModelCatalog(runner: any SZProcessRunning) async throws -> SZProviderModelCatalog? {
        await pending.fetch()
    }
}

private actor SZPendingCatalogs {
    private var continuations: [CheckedContinuation<SZProviderModelCatalog?, Never>] = []
    var count: Int { continuations.count }
    func fetch() async -> SZProviderModelCatalog? {
        await withCheckedContinuation { continuations.append($0) }
    }
    func complete(_ index: Int, model: String) {
        continuations[index].resume(returning: .init(models: [.init(id: model, displayName: model)], defaultModelID: model))
    }
}
