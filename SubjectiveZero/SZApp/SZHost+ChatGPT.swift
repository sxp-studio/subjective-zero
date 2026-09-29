// SPDX-License-Identifier: AGPL-3.0-only
// the host routes native ChatGPT setup, account selection, and usage controls.
import AppKit
import SZAI
import SZUI

extension SZHost {
    private var chatGPTProvider: SZChatGPTProvider? {
        SZProviderRegistry.shared.provider(id: SZChatGPTProvider.providerID) as? SZChatGPTProvider
    }

    var chatGPTConnectionView: SZChatGPTConnectionView {
        let active = chatGPTAccounts.first { $0.id == chatGPTActiveAccountID }
        return SZChatGPTConnectionView(
            accounts: chatGPTAccounts.map { .init(id: $0.id, label: $0.label) },
            activeID: chatGPTActiveAccountID, connected: active?.connected ?? false,
            usesPlan: active?.usesPlan ?? false, busy: chatGPTSetupTask != nil,
            message: chatGPTSetupMessage,
            onConnect: { self.connectChatGPT(newAccount: false) },
            onAddAccount: { self.connectChatGPT(newAccount: true) },
            onSelect: { self.selectChatGPTAccount($0) },
            onSignOut: { self.signOutChatGPT() },
            onCancel: { self.chatGPTSetupTask?.cancel() },
            onManageUsage: { NSWorkspace.shared.open(SZChatGPTAccounts.usageURL) })
    }

    func refreshChatGPTAccounts() async {
        do {
            chatGPTAccounts = try await SZChatGPTAccounts.shared.accounts()
            chatGPTActiveAccountID = try await SZChatGPTAccounts.shared.activeAccountID()
        } catch { chatGPTSetupMessage = error.localizedDescription }
    }

    private func canChangeChatGPTAccount() -> Bool {
        guard chatGPTSetupTask == nil, !isBusyForProjectSwitch, probingProviders.isEmpty else {
            chatGPTSetupMessage = "Wait for running agents and connection tests to finish before changing accounts."
            return false
        }
        return true
    }

    func connectChatGPT(newAccount: Bool) {
        guard canChangeChatGPTAccount() else { return }
        let accountID = newAccount ? nil : chatGPTActiveAccountID
        chatGPTSetupMessage = "Preparing ChatGPT setup…"
        selectedSetupProviderID = SZChatGPTProvider.providerID
        chatGPTSetupTask = Task { @MainActor in
            defer { chatGPTSetupTask = nil }
            do {
                try await SZChatGPTEngine.shared.install { message in
                    await MainActor.run { self.chatGPTSetupMessage = message }
                }
                try Task.checkCancellation()
                chatGPTSetupMessage = "Complete sign-in in your browser…"
                try await SZChatGPTAccounts.shared.signIn(profileID: accountID) { url in
                    await MainActor.run { NSWorkspace.shared.open(url) }
                }
                NSApp.activate(ignoringOtherApps: true)
                resetAgentSessions(ownedBy: SZChatGPTProvider.providerID)
                chatGPTProvider?.clearCatalog()
                providerProbes[SZChatGPTProvider.providerID] = nil
                invalidateProviderModelCatalog(SZChatGPTProvider.providerID)
                chatGPTSetupMessage = nil
                await refreshChatGPTAccounts()
                chatGPTWelcomePresented = try await SZChatGPTAccounts.shared.needsWelcome()
                await refreshProviderHealthOnce()
            } catch is CancellationError {
                chatGPTSetupMessage = "Connection cancelled. You can continue setup at any time."
            } catch { chatGPTSetupMessage = error.localizedDescription }
            await refreshChatGPTAccounts()
        }
    }

    func selectChatGPTAccount(_ id: String) {
        guard canChangeChatGPTAccount(), !id.isEmpty else { return }
        chatGPTSetupTask = Task { @MainActor in
            defer { chatGPTSetupTask = nil }
            do {
                try await SZChatGPTAccounts.shared.select(id)
                NSApp.activate(ignoringOtherApps: true)
                resetAgentSessions(ownedBy: SZChatGPTProvider.providerID)
                chatGPTProvider?.clearCatalog()
                providerProbes[SZChatGPTProvider.providerID] = nil
                invalidateProviderModelCatalog(SZChatGPTProvider.providerID)
                chatGPTSetupMessage = nil
                await refreshChatGPTAccounts()
                await refreshProviderHealthOnce()
            } catch { chatGPTSetupMessage = error.localizedDescription }
        }
    }

    func signOutChatGPT() {
        guard canChangeChatGPTAccount(), let id = chatGPTActiveAccountID else { return }
        chatGPTSetupTask = Task { @MainActor in
            defer { chatGPTSetupTask = nil }
            do {
                try await SZChatGPTAccounts.shared.signOut(id)
                chatGPTSetupMessage = "Signed out of ChatGPT."
            } catch { chatGPTSetupMessage = error.localizedDescription }
            resetAgentSessions(ownedBy: SZChatGPTProvider.providerID)
            chatGPTProvider?.clearCatalog()
            invalidateProviderModelCatalog(SZChatGPTProvider.providerID)
            providerProbes[SZChatGPTProvider.providerID] = nil
            await refreshChatGPTAccounts()
            await refreshProviderHealthOnce()
        }
    }

    func acknowledgeChatGPTWelcome() {
        chatGPTWelcomePresented = false
        Task { try? await SZChatGPTAccounts.shared.acknowledgeWelcome() }
    }
}
