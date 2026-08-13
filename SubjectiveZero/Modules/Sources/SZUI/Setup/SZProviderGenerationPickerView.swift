// SPDX-License-Identifier: AGPL-3.0-only
// The composer's provider generation picker — the HUD provider picker grown into the full
// generation-settings control (provider → model → reasoning effort → fast mode) as one pill +
// nested menu, relocated per the old picker's plan (SZProviderPickerView, which this supersedes).
// SZUI can't import SZAI, so capabilities + the resolved selection arrive as dumb host-mapped
// values (SZHost.providerGenerationPickerItems). Inside the menu: plain titles only (menu items render
// template images, so a tinted dot goes monochrome) — disabled dimming carries provider health,
// and the pill wears a warning dot when the ACTIVE provider is unhealthy (the way in is the
// menu's "Agent Providers…" entry).
import SwiftUI

/// One model entry in the picker: the opaque id the host selects by + the label the menu/pill
/// shows ("claude-opus-4-8" → "Opus 4.8" — pinned versions, honest labels).
public struct SZProviderGenerationPickerModelItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// One provider's full generation surface + resolved selection. `isEnabled` gates selection to
/// healthy providers — an unhealthy one renders dimmed, still visible so its absence isn't a
/// mystery. `supportedReasoningEfforts == []` hides the effort dimension for the selected model.
public struct SZProviderGenerationPickerItem: Identifiable, Equatable, Sendable {
    public var id: String                           // provider id
    public var label: String                        // display name ("Claude Code")
    public var isEnabled: Bool
    public var isActive: Bool
    public var models: [SZProviderGenerationPickerModelItem]   // menu order
    public var supportedReasoningEfforts: [String]  // selected-model menu order; [] → hidden
    public var supportsFastMode: Bool
    public var selectedModel: String                // resolved model ID (never empty)
    public var selectedReasoningEffort: String?     // nil when the provider has no effort concept
    public var fastModeEnabled: Bool

    public init(id: String, label: String, isEnabled: Bool, isActive: Bool,
                models: [SZProviderGenerationPickerModelItem],
                supportedReasoningEfforts: [String], supportsFastMode: Bool,
                selectedModel: String, selectedReasoningEffort: String?, fastModeEnabled: Bool) {
        self.id = id
        self.label = label
        self.isEnabled = isEnabled
        self.isActive = isActive
        self.models = models
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.supportsFastMode = supportsFastMode
        self.selectedModel = selectedModel
        self.selectedReasoningEffort = selectedReasoningEffort
        self.fastModeEnabled = fastModeEnabled
    }
}

public struct SZProviderGenerationPickerView: View {
    private let items: [SZProviderGenerationPickerItem]
    private let onSetProvider: (String) -> Void
    private let onSetModel: (String) -> Void
    private let onSetReasoningEffort: (String) -> Void
    private let onSetFastMode: (Bool) -> Void
    private let onOpenProviderSetup: () -> Void

    public init(items: [SZProviderGenerationPickerItem],
                onSetProvider: @escaping (String) -> Void,
                onSetModel: @escaping (String) -> Void,
                onSetReasoningEffort: @escaping (String) -> Void,
                onSetFastMode: @escaping (Bool) -> Void,
                onOpenProviderSetup: @escaping () -> Void) {
        self.items = items
        self.onSetProvider = onSetProvider
        self.onSetModel = onSetModel
        self.onSetReasoningEffort = onSetReasoningEffort
        self.onSetFastMode = onSetFastMode
        self.onOpenProviderSetup = onOpenProviderSetup
    }

    @State private var hover = false   // pill hover highlight

    private var active: SZProviderGenerationPickerItem? { items.first(where: \.isActive) }

    public var body: some View {
        Menu {
            ForEach(items) { item in
                Button {
                    onSetProvider(item.id)
                } label: {
                    if item.isActive {
                        Label(item.label, systemImage: "checkmark")
                    } else {
                        Text(item.label)
                    }
                }
                .disabled(!item.isEnabled)
            }
            if let active {
                Divider()
                Menu("Model") {
                    ForEach(active.models) { model in
                        Button {
                            onSetModel(model.id)
                        } label: {
                            if model.id == active.selectedModel {
                                Label(model.label, systemImage: "checkmark")
                            } else {
                                Text(model.label)
                            }
                        }
                    }
                }
                if !active.supportedReasoningEfforts.isEmpty {
                    Menu("Reasoning Effort") {
                        ForEach(active.supportedReasoningEfforts, id: \.self) { effort in
                            Button {
                                onSetReasoningEffort(effort)
                            } label: {
                                if effort == active.selectedReasoningEffort {
                                    Label(Self.effortLabel(effort), systemImage: "checkmark")
                                } else {
                                    Text(Self.effortLabel(effort))
                                }
                            }
                        }
                    }
                }
                if active.supportsFastMode {
                    Button {
                        onSetFastMode(!active.fastModeEnabled)
                    } label: {
                        if active.fastModeEnabled {
                            Label("Fast Mode", systemImage: "checkmark")
                        } else {
                            Text("Fast Mode")
                        }
                    }
                }
            }
            Divider()
            Button("Agent Providers…") { onOpenProviderSetup() }
        } label: {
            pill
        }
        // .plain button style + .button menu style (not .borderlessButton, which substitutes its
        // own proportional label and drops the decorated pill) — the SZPortControl enum-chip recipe.
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .trackingHover($hover)
        .help("Agent provider, model, reasoning effort, and fast mode for new runs and chats")
    }

    /// The Codex-shape pill: `[dot] [bolt] <provider> · <model> · <effort> ⌄`. The provider id leads
    /// (the tab caption's lowercase convention) because a model label alone stopped identifying the
    /// backend the moment a BYOK harness joined the registry — the same model label can be served
    /// by two different providers. Falls back to raw tokens when a lookup misses so a stale
    /// selection stays visible and re-pickable, never blank.
    private var pill: some View {
        HStack(spacing: 4) {
            if let active, !active.isEnabled {
                Circle().fill(.orange).frame(width: 5, height: 5)
                    .help("The active provider is not ready — open Agent Providers…")
            }
            if active?.fastModeEnabled == true {
                Image(systemName: "bolt.fill").font(.system(size: 8))
            }
            Text(pillTitle)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(height: 22)
        .padding(.horizontal, 8)
        .background(Capsule().fill(Color(white: hover ? 0.28 : 0.22)))
    }

    private var pillTitle: String {
        guard let active else { return "provider" }
        // Model label lookup with a raw-id fallback — a stale selection stays visible, never blank.
        // Empty segments drop out: a runtime-catalog provider serves NO model before its first
        // fetch (selectedModel ""), and the pill should read "pi · Medium", not "pi ·  · Medium".
        let model = active.models.first { $0.id == active.selectedModel }?.label ?? active.selectedModel
        let effort = active.selectedReasoningEffort.map { Self.effortLabel($0) } ?? ""
        return [active.id, model, effort].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Opaque effort token → menu/pill display; unknown tokens pass through raw (still legible,
    /// still re-pickable).
    private static func effortLabel(_ token: String) -> String {
        switch token {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Max"
        case "ultra": return "Ultra"
        default: return token
        }
    }
}
