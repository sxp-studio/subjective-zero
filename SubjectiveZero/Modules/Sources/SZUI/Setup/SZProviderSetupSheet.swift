// SPDX-License-Identifier: AGPL-3.0-only
// The AI Settings sheet (the Xcode-Settings shape): a sidebar toggles focused panes — Providers
// (provider cards with live status badges, inline remedies, and an explicit Confirm for the
// default; also the first-run surface, unchanged in substance) and Routing (named routing
// profiles, SZRoutingSettingsView). Each card: radio select, capsule badge, message, monospaced
// path line, accent-tinted selection, fix-in-place remedies, and a per-card Test probe.
// SZUI can't import SZAI: everything arrives as host-mapped values + closures, the panel's
// established seam.
import AppKit
import SwiftUI

/// One model entry in a picker menu: the opaque id the host selects by + the label the menu
/// shows ("claude-opus-4-8" → "Opus 4.8" — pinned versions, honest labels).
public struct SZProviderGenerationPickerModelItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// The sheet's sidebar sections: provider health/auth/default vs. the routing profiles —
/// related surfaces, deliberately not one list.
public enum SZProviderSetupSection: String, CaseIterable, Sendable {
    case providers
    case routing
}

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
        case disabled       // user-disabled → Enable is the only remedy
    }

    public var id: String
    public var displayName: String
    public var statusLabel: String
    public var message: String
    public var readiness: Readiness
    public var detail: String?          // failure receipts (attempted command, exit, output tail)
    public var cliPath: String?         // the monospaced path line; nil = not found
    public var installCommand: String?  // the needsInstall remedy
    /// The provider's model catalog (menu order). The card shows a Model picker when this has ≥2
    /// entries — the only in-app way to change a FAILING provider's model, since a failing provider
    /// can't be made active and reach the composer's picker. Empty for a one-model or un-fetched
    /// provider → no picker.
    public var models: [SZProviderGenerationPickerModelItem]
    public var selectedModel: String    // resolved model id, checkmarked in the picker
    public var isTesting: Bool          // probe in flight → Test button spins
    public var isSelectable: Bool
    public var isConfirmable: Bool      // Confirm gates on the SELECTED card's readiness
    /// Display name of the ready provider a failing card offers as the way out ("Use X Instead");
    /// nil = no ready alternative exists, the button hides.
    public var fallbackName: String?
    /// Whether the not-ready remedies include Disable (false on the last enabled provider —
    /// disabling everything would leave no way to run agents at all).
    public var canDisable: Bool

    public init(id: String, displayName: String, statusLabel: String, message: String,
                readiness: Readiness, detail: String? = nil, cliPath: String? = nil,
                installCommand: String? = nil,
                models: [SZProviderGenerationPickerModelItem] = [], selectedModel: String = "",
                isTesting: Bool = false,
                isSelectable: Bool = true, isConfirmable: Bool = false,
                fallbackName: String? = nil, canDisable: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.statusLabel = statusLabel
        self.message = message
        self.readiness = readiness
        self.detail = detail
        self.cliPath = cliPath
        self.installCommand = installCommand
        self.models = models
        self.selectedModel = selectedModel
        self.isTesting = isTesting
        self.isSelectable = isSelectable
        self.isConfirmable = isConfirmable
        self.fallbackName = fallbackName
        self.canDisable = canDisable
    }
}

public struct SZProviderSetupSheet: View {
    private let cards: [SZProviderSetupCard]
    private let selectedID: String?
    /// The Routing pane's content, built by the presenter (the gearMenu AnyView pattern —
    /// its rows/closures are wired where the host is in scope). nil = no Routing section
    /// (previews/tests), the sidebar hides it.
    private let routing: SZRoutingSettingsView?
    private let onSelect: (String) -> Void
    private let onRefresh: () -> Void
    private let onTest: (String) -> Void
    private let onSetModel: (String, String) -> Void   // (providerID, modelID)
    private let onOpenLogin: (String) -> Void
    private let onUseFallback: (String) -> Void
    private let onSetEnabled: (String, Bool) -> Void
    private let onConfirm: () -> Void
    private let onSkip: () -> Void
    /// First run = the default provider is still unconfirmed; flips the Providers footer
    /// between Skip/Confirm (the one-time decision) and a plain Done.
    private let isFirstRun: Bool
    private let onOpenSetupGuide: () -> Void
    private let onJoinDiscord: () -> Void
    /// The presenter remembers the last-viewed section, so reopening returns there.
    private let onSectionChange: (SZProviderSetupSection) -> Void

    /// The sidebar selection; seeded by the presenter (auto-present lands on Providers).
    @State private var section: SZProviderSetupSection

    public init(cards: [SZProviderSetupCard], selectedID: String?,
                routing: SZRoutingSettingsView? = nil,
                initialSection: SZProviderSetupSection = .providers,
                onSelect: @escaping (String) -> Void, onRefresh: @escaping () -> Void,
                onTest: @escaping (String) -> Void,
                onSetModel: @escaping (String, String) -> Void,
                onOpenLogin: @escaping (String) -> Void,
                onUseFallback: @escaping (String) -> Void,
                onSetEnabled: @escaping (String, Bool) -> Void,
                onConfirm: @escaping () -> Void, onSkip: @escaping () -> Void,
                onOpenSetupGuide: @escaping () -> Void,
                onJoinDiscord: @escaping () -> Void,
                onSectionChange: @escaping (SZProviderSetupSection) -> Void = { _ in },
                isFirstRun: Bool = true) {
        self.cards = cards
        self.selectedID = selectedID
        self.routing = routing
        self.isFirstRun = isFirstRun
        _section = State(initialValue: initialSection)
        self.onSelect = onSelect
        self.onRefresh = onRefresh
        self.onTest = onTest
        self.onSetModel = onSetModel
        self.onOpenLogin = onOpenLogin
        self.onUseFallback = onUseFallback
        self.onSetEnabled = onSetEnabled
        self.onConfirm = onConfirm
        self.onSkip = onSkip
        self.onOpenSetupGuide = onOpenSetupGuide
        self.onJoinDiscord = onJoinDiscord
        self.onSectionChange = onSectionChange
    }

    private var selectedCard: SZProviderSetupCard? { cards.first { $0.id == selectedID } }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Group {
                switch section {
                case .providers: providersPane
                case .routing: routingPane
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 820, height: 580)
        .onChange(of: section) { _, new in onSectionChange(new) }
    }

    // MARK: - Sidebar (the Xcode-Settings shape: sections toggle, panes stay focused)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AI Settings")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            sidebarItem(.providers, label: "Providers", systemImage: "cpu")
            if routing != nil {
                sidebarItem(.routing, label: "Routing", systemImage: "arrow.triangle.branch")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(width: 178, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.6))
    }

    private func sidebarItem(_ target: SZProviderSetupSection, label: String,
                             systemImage: String) -> some View {
        SZSidebarItem(label: label, systemImage: systemImage,
                      selected: section == target) { section = target }
    }

    // MARK: - Providers pane (the original sheet, unchanged in substance)

    /// One sidebar row: the Xcode selection pill (full accent fill, white content) when
    /// selected, a quiet lift under the cursor otherwise. Its own view — hover is per-row state.
    private struct SZSidebarItem: View {
        let label: String
        let systemImage: String
        let selected: Bool
        let action: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 18)
                    Text(label)
                        .font(.system(size: 13))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor
                                   : Color.white.opacity(hovered ? 0.07 : 0)))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
        }
    }

    private var providersPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Providers").font(.system(size: 17, weight: .semibold))
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
            .modifier(SZScrollBottomFade())
            .frame(minHeight: 260)

            HStack(spacing: 10) {
                Button { onOpenSetupGuide() } label: { Label("Setup Guide", systemImage: "doc.text") }
                    .help("The agent-readable install & verification guide (APP_SETUP.md)")
                Button { onJoinDiscord() } label: { Label("Ask on Discord", systemImage: "questionmark.bubble") }
                    .help("Stuck? The community Discord can help you get set up.")
                Spacer()
                // Skip/Confirm is FIRST-RUN vocabulary — the one-time default-provider
                // decision. A settled install just closes, like every settings pane.
                if isFirstRun {
                    Button("Skip for Now") { onSkip() }
                    Button("Confirm") { onConfirm() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!(selectedCard?.isConfirmable ?? false))
                } else {
                    Button("Done") { onSkip() }
                }
            }
        }
    }

    // MARK: - Routing pane (presenter-built content; a Done that mirrors the sheet's dismiss)

    @ViewBuilder
    private var routingPane: some View {
        if let routing {
            VStack(alignment: .leading, spacing: 14) {
                routing
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Button("Done") { onSkip() }   // post-first-run close; routing never gates Confirm
                }
            }
        }
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
                    modelMenu(card)
                    testButton(card)
                }

                Text(card.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .textSelection(.enabled)

                remedyRow(card)

                // No path line on a disabled card: checks skip it, so there is no fresh lookup to
                // report — "not found" would be a claim nobody made.
                if card.readiness != .disabled {
                    Text(card.cliPath ?? "not found on the app's search path")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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
        case .checking, .unavailable, .disabled: .secondary
        }
    }

    /// The per-card model picker — the reachable model control for a FAILING provider, whose composer
    /// picker is gated behind being active. Shown only when the provider lists ≥2 models and only for
    /// the SAME readiness set as the Test button (below): a model choice is meaningless where there's
    /// nothing to install/log-into or nothing yet to test, and its help promises a Test that must
    /// actually be present. A one-model or un-fetched provider shows nothing.
    @ViewBuilder
    private func modelMenu(_ card: SZProviderSetupCard) -> some View {
        switch card.readiness {
        case .needsInstall, .unavailable, .checking, .disabled:
            EmptyView()
        default:
            if card.models.count > 1 {
                let selectedLabel = card.models.first { $0.id == card.selectedModel }?.label
                    ?? card.selectedModel
                Menu {
                    ForEach(card.models) { model in
                        Button {
                            onSetModel(card.id, model.id)
                        } label: {
                            if model.id == card.selectedModel {
                                Label(model.label, systemImage: "checkmark")
                            } else {
                                Text(model.label)
                            }
                        }
                    }
                } label: {
                    // Cap the width and truncate — a long qualified id (the raw-id fallback path)
                    // must never expand the row and shove Test off the fixed-width card. `.fixedSize`
                    // would do exactly that (it sizes to the label's full ideal width), so it's out.
                    Text(selectedLabel.isEmpty ? "Model" : "Model: \(selectedLabel)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 190)
                }
                .menuStyle(.button)
                .controlSize(.small)
                .help("Pick the model this provider runs — applies immediately and re-tests it here")
            }
        }
    }

    /// The probe on demand. Hidden while the CLI isn't even installed — there's nothing to test —
    /// and while the provider is user-disabled (Enable first).
    @ViewBuilder
    private func testButton(_ card: SZProviderSetupCard) -> some View {
        switch card.readiness {
        case .needsInstall, .unavailable, .checking, .disabled:
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

    /// Fix-in-place, not instructions: each unhealthy card carries its exact remedy — plus the
    /// ways OUT of the nag: a failing card offers the first ready provider instead, and every
    /// not-ready card can be disabled (a provider the user doesn't subscribe to shouldn't nag).
    @ViewBuilder
    private func remedyRow(_ card: SZProviderSetupCard) -> some View {
        switch card.readiness {
        case .needsInstall:
            HStack(spacing: 6) {
                if let command = card.installCommand {
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
                disableButton(card)
            }
        case .needsLogin:
            HStack(spacing: 6) {
                Button {
                    onOpenLogin(card.id)
                } label: {
                    Label("Open Terminal to Log In", systemImage: "terminal")
                }
                .controlSize(.small)
                .help("Login is interactive — it runs in Terminal, and this card turns green when it lands")
                disableButton(card)
            }
        case .failed:
            HStack(spacing: 6) {
                if let detail = card.detail {
                    SZCopyableDetailDisclosure(detail: detail)
                }
                if let fallbackName = card.fallbackName {
                    Button("Use \(fallbackName) Instead") { onUseFallback(card.id) }
                        .controlSize(.small)
                        .help("Make \(fallbackName) the default provider and close this sheet — \(card.displayName) stays available here if it recovers")
                }
                disableButton(card)
            }
        case .disabled:
            Button("Enable") { onSetEnabled(card.id, true) }
                .controlSize(.small)
                .help("Include \(card.displayName) in health checks and the provider picker again")
        case .checking, .ready, .verified, .unavailable:
            EmptyView()
        }
    }

    @ViewBuilder
    private func disableButton(_ card: SZProviderSetupCard) -> some View {
        if card.canDisable {
            Button("Disable") { onSetEnabled(card.id, false) }
                .controlSize(.small)
                .help("Stop checking \(card.displayName) and hide it from runs — re-enable it here any time")
        }
    }
}

/// Fades a scroller's last 22pt while more content sits below the fold — via an alpha MASK
/// on the scroll content, not a painted gradient: the sheet ground is system material, so
/// paint would band. Fully opaque at the true bottom. Shared by both Setup panes.
struct SZScrollBottomFade: ViewModifier {
    @State private var hasMore = false

    func body(content: Content) -> some View {
        content
            // Quantized to a Bool on purpose (the transcript's rule): the raw distance
            // changes every scroll tick, and writing that to state would re-render at
            // scroll cadence.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y
                    - geometry.containerSize.height > 12
            } action: { _, more in
                withAnimation(.easeOut(duration: 0.15)) { hasMore = more }
            }
            .mask(VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, hasMore ? .clear : .black],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 22)
            })
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
