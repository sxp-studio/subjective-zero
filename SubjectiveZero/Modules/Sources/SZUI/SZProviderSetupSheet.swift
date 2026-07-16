// SPDX-License-Identifier: AGPL-3.0-only
// The Agent Providers setup sheet — provider cards with live status badges, inline remedies, and
// an explicit Confirm for the default. Each card: radio select, capsule badge, message, monospaced
// path line, accent-tinted selection — plus (roadmap Task 2) a six-status vocabulary, fix-in-place
// remedies (copyable install command, a Terminal login launcher), and a per-card Test that runs the
// one-shot prompt probe.
// SZUI can't import SZAI: everything arrives as host-mapped `SZProviderSetupCard` values +
// closures, the panel's established seam.
import AppKit
import SwiftUI

/// One provider's card — a pure view-model the host maps from its merged health truth.
public struct SZProviderSetupCard: Identifiable, Equatable, Sendable {
    /// What the card can DO — drives badge color and which remedy row shows. Distinct from the
    /// host's health status: this is presentation vocabulary (e.g. probe-verified gets its own
    /// badge so "the CLI answered a real prompt" reads differently from "version+auth passed").
    public enum Readiness: Sendable {
        case checking       // no health pass finished yet
        case ready          // cheap tiers passed
        case verified       // the prompt probe actually got a reply
        case needsInstall   // missingCLI → copyable install command
        case needsLogin     // authNeeded → Terminal login launcher
        case failed         // healthFailed → detail popover
        case unavailable    // reserved statuses (invalidConfig / unsupported)
    }

    public var id: String
    public var displayName: String
    public var statusLabel: String
    public var message: String
    public var readiness: Readiness
    public var detail: String?          // failure receipts (attempted command, exit, output tail)
    public var cliPath: String?         // the monospaced path line; nil = not found
    public var installCommand: String?  // the needsInstall remedy
    public var isTesting: Bool          // probe in flight → Test button spins
    public var isSelectable: Bool
    public var isConfirmable: Bool      // Confirm gates on the SELECTED card's readiness

    public init(id: String, displayName: String, statusLabel: String, message: String,
                readiness: Readiness, detail: String? = nil, cliPath: String? = nil,
                installCommand: String? = nil, isTesting: Bool = false,
                isSelectable: Bool = true, isConfirmable: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.statusLabel = statusLabel
        self.message = message
        self.readiness = readiness
        self.detail = detail
        self.cliPath = cliPath
        self.installCommand = installCommand
        self.isTesting = isTesting
        self.isSelectable = isSelectable
        self.isConfirmable = isConfirmable
    }
}

public struct SZProviderSetupSheet: View {
    private let cards: [SZProviderSetupCard]
    private let selectedID: String?
    private let onSelect: (String) -> Void
    private let onRefresh: () -> Void
    private let onTest: (String) -> Void
    private let onOpenLogin: (String) -> Void
    private let onConfirm: () -> Void
    private let onSkip: () -> Void
    private let onOpenSetupGuide: () -> Void
    private let onJoinDiscord: () -> Void

    public init(cards: [SZProviderSetupCard], selectedID: String?,
                onSelect: @escaping (String) -> Void, onRefresh: @escaping () -> Void,
                onTest: @escaping (String) -> Void, onOpenLogin: @escaping (String) -> Void,
                onConfirm: @escaping () -> Void, onSkip: @escaping () -> Void,
                onOpenSetupGuide: @escaping () -> Void,
                onJoinDiscord: @escaping () -> Void) {
        self.cards = cards
        self.selectedID = selectedID
        self.onSelect = onSelect
        self.onRefresh = onRefresh
        self.onTest = onTest
        self.onOpenLogin = onOpenLogin
        self.onConfirm = onConfirm
        self.onSkip = onSkip
        self.onOpenSetupGuide = onOpenSetupGuide
        self.onJoinDiscord = onJoinDiscord
    }

    private var selectedCard: SZProviderSetupCard? { cards.first { $0.id == selectedID } }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Agent Providers").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { onRefresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Choose the default agent provider for runs and chat.")
                Text("Cards re-check on their own while this sheet is open — install or log in and watch them turn green. Only Ready providers can run agents.")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .textSelection(.enabled)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(cards) { providerCard($0) }
                }
            }
            .frame(minHeight: 260)

            HStack(spacing: 10) {
                Button { onOpenSetupGuide() } label: { Label("Setup Guide", systemImage: "doc.text") }
                    .help("The agent-readable install & verification guide (APP_SETUP.md)")
                Button { onJoinDiscord() } label: { Label("Ask on Discord", systemImage: "questionmark.bubble") }
                    .help("Stuck? The community Discord can help you get set up.")
                Spacer()
                Button("Skip for Now") { onSkip() }
                Button("Confirm") { onConfirm() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!(selectedCard?.isConfirmable ?? false))
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }

    // MARK: - Card

    @ViewBuilder
    private func providerCard(_ card: SZProviderSetupCard) -> some View {
        let selected = card.id == selectedID
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(card.isSelectable ? Color.accentColor : Color.secondary.opacity(0.35))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(card.displayName).font(.system(size: 13, weight: .semibold))
                    statusBadge(card)
                    Spacer()
                    testButton(card)
                }

                Text(card.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .textSelection(.enabled)

                remedyRow(card)

                Text(card.cliPath ?? "not found on the app's search path")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.12)
                               : Color(nsColor: .controlBackgroundColor).opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.accentColor.opacity(0.52) : Color.primary.opacity(0.10),
                        lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if card.isSelectable { onSelect(card.id) }
        }
    }

    private func statusBadge(_ card: SZProviderSetupCard) -> some View {
        Text(card.statusLabel)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor(card.readiness).opacity(0.15), in: Capsule())
            .foregroundStyle(badgeColor(card.readiness))
    }

    private func badgeColor(_ readiness: SZProviderSetupCard.Readiness) -> Color {
        switch readiness {
        case .ready, .verified: .green
        case .needsInstall, .needsLogin: .orange
        case .failed: .red
        case .checking, .unavailable: .secondary
        }
    }

    /// The probe on demand. Hidden while the CLI isn't even installed — there's nothing to test.
    @ViewBuilder
    private func testButton(_ card: SZProviderSetupCard) -> some View {
        switch card.readiness {
        case .needsInstall, .unavailable, .checking:
            EmptyView()
        default:
            Button {
                onTest(card.id)
            } label: {
                if card.isTesting {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Testing…")
                    }
                } else {
                    Text("Test")
                }
            }
            .controlSize(.small)
            .disabled(card.isTesting)
            .help("Send one tiny prompt through the real agent path — proves it actually replies")
        }
    }

    /// Fix-in-place, not instructions: each unhealthy card carries its exact remedy.
    @ViewBuilder
    private func remedyRow(_ card: SZProviderSetupCard) -> some View {
        switch card.readiness {
        case .needsInstall:
            if let command = card.installCommand {
                HStack(spacing: 6) {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .controlSize(.small)
                    .help("Copy the install command")
                }
            }
        case .needsLogin:
            Button {
                onOpenLogin(card.id)
            } label: {
                Label("Open Terminal to Log In", systemImage: "terminal")
            }
            .controlSize(.small)
            .help("Login is interactive — it runs in Terminal, and this card turns green when it lands")
        case .failed:
            if let detail = card.detail {
                SZCopyableDetailDisclosure(detail: detail)
            }
        case .checking, .ready, .verified, .unavailable:
            EmptyView()
        }
    }
}

/// "Details" for a failing card — the health diagnostics (attempted command, exit code, output
/// tail) in a copyable popover.
struct SZCopyableDetailDisclosure: View {
    let detail: String
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Label("Details", systemImage: "info.circle")
        }
        .controlSize(.small)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .trailing, spacing: 8) {
                ScrollView {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(detail, forType: .string)
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(width: 420, height: 220)
        }
    }
}
