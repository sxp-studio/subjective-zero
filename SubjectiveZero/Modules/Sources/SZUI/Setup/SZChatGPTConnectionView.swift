// SPDX-License-Identifier: AGPL-3.0-only
// native rendering of OpenAI's approved black sign-in button and connection controls.
import SwiftUI
import AppKit

public struct SZChatGPTConnectionView: View {
    public struct Account: Identifiable, Sendable {
        public let id: String
        public let label: String
        public init(id: String, label: String) { self.id = id; self.label = label }
    }
    private let accounts: [Account]
    private let activeID: String?
    private let connected: Bool
    private let usesPlan: Bool
    private let busy: Bool
    private let message: String?
    private let onConnect: () -> Void
    private let onAddAccount: () -> Void
    private let onSelect: (String) -> Void
    private let onSignOut: () -> Void
    private let onCancel: () -> Void
    private let onManageUsage: () -> Void

    public init(accounts: [Account], activeID: String?, connected: Bool, usesPlan: Bool, busy: Bool,
                message: String?, onConnect: @escaping () -> Void, onAddAccount: @escaping () -> Void,
                onSelect: @escaping (String) -> Void, onSignOut: @escaping () -> Void,
                onCancel: @escaping () -> Void, onManageUsage: @escaping () -> Void) {
        self.accounts = accounts; self.activeID = activeID; self.connected = connected
        self.usesPlan = usesPlan; self.busy = busy; self.message = message
        self.onConnect = onConnect; self.onAddAccount = onAddAccount; self.onSelect = onSelect
        self.onSignOut = onSignOut; self.onCancel = onCancel; self.onManageUsage = onManageUsage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message ?? "Connecting to ChatGPT…").font(.system(size: 12))
                    Spacer()
                    Button("Cancel", action: onCancel)
                }
            } else {
                if !usesPlan {
                    Button(action: onConnect) {
                        HStack(spacing: 10) {
                            Image(nsImage: NSImage(contentsOf: Bundle.module.url(forResource: "chatgpt-logo-white", withExtension: "png")!)!)
                                .resizable().interpolation(.high).frame(width: 21, height: 21)
                            Text("Continue with ChatGPT").font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 44)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.2), lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Continue with ChatGPT")
                }
                if !accounts.isEmpty || connected {
                    HStack {
                        if !accounts.isEmpty {
                            Menu {
                                ForEach(accounts) { account in
                                    Button { onSelect(account.id) } label: {
                                        if account.id == activeID { Label(account.label, systemImage: "checkmark") }
                                        else { Text(account.label) }
                                    }
                                }
                                Divider()
                                Button("Add another account", action: onAddAccount)
                                if connected { Button("Sign out", action: onSignOut) }
                            } label: {
                                Text(accounts.first { $0.id == activeID }?.label ?? "Choose an account")
                                    .lineLimit(1).truncationMode(.middle)
                            }.fixedSize()
                            .accessibilityLabel("ChatGPT account")
                        }
                        if connected {
                            Spacer()
                            Button("Manage usage", action: onManageUsage)
                        }
                    }
                }
                if let message {
                    Text(message).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }
}

public struct SZChatGPTWelcomeView: View {
    private let onContinue: () -> Void
    private let onManageUsage: () -> Void

    public init(onContinue: @escaping () -> Void, onManageUsage: @escaping () -> Void) {
        self.onContinue = onContinue
        self.onManageUsage = onManageUsage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30)).foregroundStyle(.green)
            Text("ChatGPT is connected").font(.system(size: 22, weight: .semibold))
            Text("AI requests in SubZ use your ChatGPT plan or available credits.")
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Text("You can review usage and set spending limits in ChatGPT at any time.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Manage usage", action: onManageUsage).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                Spacer()
                Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(.top, 8)
        }.padding(28).frame(width: 360)
    }
}
