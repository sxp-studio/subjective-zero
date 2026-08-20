// SPDX-License-Identifier: AGPL-3.0-only
// The AI Settings Routing pane — named profiles filling the agent graphs' declared MODEL
// SLOTS with generation envelopes. Top: the ACTIVE-profile menu (Off = the identity world)
// + profile management; below: one grouped card per agent, one divider-separated row per
// declared slot. SZUI can't import SZAI: cards arrive host-mapped (SZHost+RoutingSettings),
// keyed by the typed SZRoutingPosition — every row is an (agent, slot).
import AppKit
import SwiftUI

/// Opaque effort token → display label; unknown tokens pass through raw (still legible, still
/// re-pickable). One home for every effort menu in Setup.
public enum SZGenerationLabels {
    public static func effort(_ token: String) -> String {
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

/// One saved profile in the profile bar's menus.
public struct SZRoutingProfileRow: Identifiable, Equatable, Sendable {
    public var name: String
    public var isActive: Bool
    public var id: String { name }

    public init(name: String, isActive: Bool = false) {
        self.name = name
        self.isActive = isActive
    }
}

/// One provider·model pair an envelope menu offers. Dimmed rows carry their reason in the
/// label ("(disabled)", "(needs login)") — menu rows have no tooltip.
public struct SZRoutingEnvelopeOption: Identifiable, Equatable, Sendable {
    public var id: String          // "provider/model" ("provider/" for a catalog-less provider)
    public var providerID: String
    public var modelID: String?    // nil = the provider's own selected/default model
    public var label: String       // "Codex · GPT-5.6 Terra"
    public var isSelected: Bool
    public var isEnabled: Bool

    public init(providerID: String, modelID: String?, label: String,
                isSelected: Bool = false, isEnabled: Bool = true) {
        self.id = "\(providerID)/\(modelID ?? "")"
        self.providerID = providerID
        self.modelID = modelID
        self.label = label
        self.isSelected = isSelected
        self.isEnabled = isEnabled
    }
}

/// One fillable position in a profile — an (agent, slot) pair, the packs' own vocabulary,
/// so the SZUI↔host seam never invents a position the graphs don't declare.
public struct SZRoutingPosition: Hashable, Sendable {
    public var agent: String
    public var slot: String

    public init(agent: String, slot: String) {
        self.agent = agent
        self.slot = slot
    }
}

/// Where an UNFILLED slot's work goes — the derivation behind a grade variant's live
/// "Default — …" resolution. Pure so the rule is pinnable in tests; the host renders from it.
public enum SZRoutingInheritance {
    /// The standard slot a grade-variant slot falls back to: `slot` appears as a
    /// light/heavy value in the graph's grade table, and the table names a DIFFERENT
    /// standard slot to fall to. nil = no variant relation — the app default catches it.
    public static func standardSlot(for slot: String, grades: [String: String]?) -> String? {
        guard let grades,
              grades.contains(where: { $0.key != "standard" && $0.value == slot }),
              let standard = grades["standard"], standard != slot else { return nil }
        return standard
    }
}

/// One slot's row — a pure view-model. Effort/fast props are resolved against the ROUTED
/// model host-side; empty/false hides those controls.
public struct SZRoutingPositionRow: Identifiable, Equatable, Sendable {
    public var position: SZRoutingPosition
    public var id: SZRoutingPosition { position }
    public var label: String           // the slot's authored label (or its id, verbatim)
    public var caption: String         // the pack's description, rendered verbatim
    public var selectionLabel: String  // "Default" (unset) or "Codex · GPT-5.6 Terra"
    /// The envelope menu's first row — the clear action, spelled as where the work then
    /// goes: "Default — Claude · Opus 5" (grade variants resolve through their standard slot).
    public var clearLabel: String
    public var isSet: Bool
    public var options: [SZRoutingEnvelopeOption]
    public var effortOptions: [String]
    public var selectedEffort: String?
    public var supportsFastMode: Bool
    public var fastModeEnabled: Bool

    public init(position: SZRoutingPosition, label: String, caption: String = "",
                selectionLabel: String, clearLabel: String, isSet: Bool,
                options: [SZRoutingEnvelopeOption] = [],
                effortOptions: [String] = [], selectedEffort: String? = nil,
                supportsFastMode: Bool = false, fastModeEnabled: Bool = false) {
        self.position = position
        self.label = label
        self.caption = caption
        self.selectionLabel = selectionLabel
        self.clearLabel = clearLabel
        self.isSet = isSet
        self.options = options
        self.effortOptions = effortOptions
        self.selectedEffort = selectedEffort
        self.supportsFastMode = supportsFastMode
        self.fastModeEnabled = fastModeEnabled
    }
}

/// One agent's card: identity in the header, one row per declared slot beneath.
public struct SZRoutingAgentCard: Identifiable, Equatable, Sendable {
    public var id: String       // the agent id — what View Graph reveals
    public var title: String
    public var symbol: String
    /// The pack's declared tint name (SZAgentTint vocabulary); nil = untinted.
    public var tint: String?
    public var rows: [SZRoutingPositionRow]

    public init(id: String, title: String, symbol: String, tint: String? = nil,
                rows: [SZRoutingPositionRow] = []) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.rows = rows
    }
}

public struct SZRoutingSettingsView: View {
    private let profiles: [SZRoutingProfileRow]
    /// The profile whose table the form shows (host-resolved: requested → active → first);
    /// nil = no saved profiles, the pane shows only the empty-state sentence.
    private let editedProfileName: String?
    private let agents: [SZRoutingAgentCard]
    /// Non-nil = SZ_MODEL_ROUTING pins this profile at launch; the active menu locks.
    private let envPinnedProfileName: String?
    /// Whether the New Profile menu offers the Claude Ladder starter (host-gated on the
    /// claude provider being installed and healthy).
    private let claudeLadderAvailable: Bool
    private let onSelectActiveProfile: (String?) -> Void
    private let onCreateProfile: () -> Void
    private let onCreateClaudeLadder: () -> Void
    private let onRenameProfile: (String, String) -> Void   // (old, new)
    private let onDuplicateProfile: (String) -> Void
    private let onDeleteProfile: (String) -> Void
    private let onEditProfile: (String) -> Void
    private let onAssignEnvelope: (SZRoutingPosition, String?, String?) -> Void   // (position, providerID, modelID); (p, nil, nil) = clear
    private let onSetPositionEffort: (SZRoutingPosition, String?) -> Void
    private let onSetPositionFastMode: (SZRoutingPosition, Bool) -> Void
    /// Close the settings sheet and land the Agent Graph panel on this agent's plan.
    private let onShowAgentGraph: (String) -> Void

    // The rename alert's target + draft (view-local; committed via onRenameProfile).
    @State private var renameTarget: String?
    @State private var renameDraft = ""

    public init(profiles: [SZRoutingProfileRow],
                editedProfileName: String?,
                agents: [SZRoutingAgentCard],
                envPinnedProfileName: String? = nil,
                claudeLadderAvailable: Bool = false,
                onSelectActiveProfile: @escaping (String?) -> Void = { _ in },
                onCreateProfile: @escaping () -> Void = {},
                onCreateClaudeLadder: @escaping () -> Void = {},
                onRenameProfile: @escaping (String, String) -> Void = { _, _ in },
                onDuplicateProfile: @escaping (String) -> Void = { _ in },
                onDeleteProfile: @escaping (String) -> Void = { _ in },
                onEditProfile: @escaping (String) -> Void = { _ in },
                onAssignEnvelope: @escaping (SZRoutingPosition, String?, String?) -> Void = { _, _, _ in },
                onSetPositionEffort: @escaping (SZRoutingPosition, String?) -> Void = { _, _ in },
                onSetPositionFastMode: @escaping (SZRoutingPosition, Bool) -> Void = { _, _ in },
                onShowAgentGraph: @escaping (String) -> Void = { _ in }) {
        self.profiles = profiles
        self.editedProfileName = editedProfileName
        self.agents = agents
        self.envPinnedProfileName = envPinnedProfileName
        self.claudeLadderAvailable = claudeLadderAvailable
        self.onSelectActiveProfile = onSelectActiveProfile
        self.onCreateProfile = onCreateProfile
        self.onCreateClaudeLadder = onCreateClaudeLadder
        self.onRenameProfile = onRenameProfile
        self.onDuplicateProfile = onDuplicateProfile
        self.onDeleteProfile = onDeleteProfile
        self.onEditProfile = onEditProfile
        self.onAssignEnvelope = onAssignEnvelope
        self.onSetPositionEffort = onSetPositionEffort
        self.onSetPositionFastMode = onSetPositionFastMode
        self.onShowAgentGraph = onShowAgentGraph
    }

    private var activeProfile: SZRoutingProfileRow? { profiles.first(where: \.isActive) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Routing").font(.system(size: 17, weight: .semibold))

            Text("Each agent lists the kinds of work it needs a model for. A profile picks a model for each — anything left on Default runs on the default provider.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            profileBar

            if let name = editedProfileName {
                editorBar(name)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(agents) { agentCard($0) }
                    }
                }
                .modifier(SZScrollBottomFade())
            } else {
                Text("No profiles yet. Every agent runs on the default provider — create a profile to give specific work its own model.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .alert("Rename Profile", isPresented: Binding(get: { renameTarget != nil },
                                                      set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                if let old = renameTarget { onRenameProfile(old, renameDraft) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    // MARK: - Profile bar (the ACTIVE selection + profile management)

    private var profileBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Active")
                    .font(.system(size: 13, weight: .medium))
                activeMenu
                    .disabled(envPinnedProfileName != nil)
                Spacer()
                newProfileMenu
            }
            if let pinned = envPinnedProfileName {
                Text("Pinned to \"\(pinned)\" for this launch (SZ_MODEL_ROUTING) — relaunch without it to switch profiles.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var activeMenu: some View {
        Menu {
            Button {
                onSelectActiveProfile(nil)
            } label: {
                if activeProfile == nil { Label("Off — the default provider runs everything", systemImage: "checkmark") }
                else { Text("Off — the default provider runs everything") }
            }
            Divider()
            ForEach(profiles) { profile in
                Button {
                    onSelectActiveProfile(profile.name)
                } label: {
                    if profile.isActive { Label(profile.name, systemImage: "checkmark") }
                    else { Text(profile.name) }
                }
            }
        } label: {
            Text(activeProfile?.name ?? "Off")
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 210)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .help("The profile new chats and runs use — switching is refused while a run is in flight")
    }

    /// New Profile: start empty, or from a preset (only offered while its provider is usable).
    private var newProfileMenu: some View {
        Menu {
            Button("Empty Profile") { onCreateProfile() }
            if claudeLadderAvailable {
                Divider()
                Button("Claude Ladder — Haiku sorts, Sonnet builds and answers, Opus takes the heavy work") {
                    onCreateClaudeLadder()
                }
            }
        } label: {
            Text("New Profile")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help("Start empty, or from a preset — presets only fill the built-in agents")
    }

    /// Which profile the FORM shows (independent of which is active), plus its management menu.
    private func editorBar(_ edited: String) -> some View {
        HStack(spacing: 10) {
            Text("Editing")
                .font(.system(size: 13, weight: .medium))
            Menu {
                ForEach(profiles) { profile in
                    Button {
                        onEditProfile(profile.name)
                    } label: {
                        if profile.name == edited { Label(profile.name, systemImage: "checkmark") }
                        else { Text(profile.name) }
                    }
                }
            } label: {
                Text(edited)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 210)
            }
            .menuStyle(.button)
            .controlSize(.small)
            .help("Pick which profile the form below edits — the active profile can be edited live")
            Menu {
                Button("Rename…") {
                    renameDraft = edited
                    renameTarget = edited
                }
                Button("Duplicate") { onDuplicateProfile(edited) }
                Divider()
                Button("Delete", role: .destructive) { onDeleteProfile(edited) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .help("Rename, duplicate, or delete \"\(edited)\" — deleting the active profile turns routing off")
            Spacer()
        }
    }

    // MARK: - Agent cards (one per pack, one row per declared slot)

    private func agentCard(_ agent: SZRoutingAgentCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader(agent)
            // Dividers separate ROWS only — the header band is its own edge, and a hairline
            // right under it read as a smudge.
            if agent.rows.isEmpty {
                Text("This agent doesn't ask for model choices — it runs on the default provider.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(agent.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 14) }
                    slotRow(row)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.82)))
        // The agent's own tint outlines its card — the same accent its chat lines and
        // graph wear, so the three surfaces read as one identity.
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder((SZAgentTint.color(agent.tint) ?? .clear).opacity(0.5), lineWidth: 2))
    }

    private func cardHeader(_ agent: SZRoutingAgentCard) -> some View {
        HStack(spacing: 10) {
            Image(systemName: agent.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18)
                .foregroundStyle(SZAgentTint.color(agent.tint) ?? .primary)
            Text(agent.title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            SZViewGraphButton(title: agent.title) { onShowAgentGraph(agent.id) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // The agent's hue as the header band — a gradient settling toward the trailing
        // edge, so the name sits in the color and the controls stay quiet. Untinted packs
        // get a plain lift so every card still reads a header.
        .background(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10)
            .fill(headerWash(SZAgentTint.color(agent.tint))))
    }

    private func headerWash(_ tint: Color?) -> AnyShapeStyle {
        guard let tint else { return AnyShapeStyle(Color.white.opacity(0.04)) }
        // Vertical: the color sits along the card's top edge and dissolves fully away.
        return AnyShapeStyle(LinearGradient(
            colors: [tint.opacity(0.24), tint.opacity(0)],
            startPoint: .top, endPoint: .bottom))
    }

    private func slotRow(_ row: SZRoutingPositionRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .font(.system(size: 13, weight: .medium))
                // The pack author's words, shown WHOLE — the row grows rather than cutting
                // a description short.
                Text(row.caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if row.isSet {
                effortMenu(row)
                fastToggle(row)
            }
            envelopeMenu(row)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func envelopeMenu(_ row: SZRoutingPositionRow) -> some View {
        Menu {
            // The clear action, spelled as its destination ("Default — …", live-resolved;
            // grade variants resolve through their standard slot) — the menu explains the inherit.
            Button {
                onAssignEnvelope(row.position, nil, nil)
            } label: {
                if !row.isSet { Label(row.clearLabel, systemImage: "checkmark") }
                else { Text(row.clearLabel) }
            }
            Divider()
            ForEach(row.options) { option in
                Button {
                    onAssignEnvelope(row.position, option.providerID, option.modelID)
                } label: {
                    if option.isSelected { Label(option.label, systemImage: "checkmark") }
                    else { Text(option.label) }
                }
                .disabled(!option.isEnabled)
            }
        } label: {
            // Cap-and-truncate: a long label must never shove the row wider than the fixed sheet.
            Text(row.selectionLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 210)
                .foregroundStyle(row.isSet ? Color.primary : Color.secondary)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .help("Pick the provider and model this runs on — the first item shows where it goes when you don't")
    }

    /// Only when the routed model has an effort concept — an absent menu is the honest render.
    @ViewBuilder
    private func effortMenu(_ row: SZRoutingPositionRow) -> some View {
        if !row.effortOptions.isEmpty {
            Menu {
                Button {
                    onSetPositionEffort(row.position, nil)
                } label: {
                    if row.selectedEffort == nil { Label("Default", systemImage: "checkmark") }
                    else { Text("Default") }
                }
                Divider()
                ForEach(row.effortOptions, id: \.self) { token in
                    Button {
                        onSetPositionEffort(row.position, token)
                    } label: {
                        if token == row.selectedEffort {
                            Label(SZGenerationLabels.effort(token), systemImage: "checkmark")
                        } else {
                            Text(SZGenerationLabels.effort(token))
                        }
                    }
                }
            } label: {
                Text(row.selectedEffort.map(SZGenerationLabels.effort) ?? "Effort")
                    .lineLimit(1)
                    .frame(maxWidth: 90)
            }
            .menuStyle(.button)
            .controlSize(.small)
            .help("Reasoning effort for this model — Default is the model's own")
        }
    }

    /// Only where the ROUTED model honours it — an inert toggle is a lie. A bordered chip
    /// (accent-filled when on, brightening under the cursor), so it reads as a pressable
    /// control, not a status glyph.
    @ViewBuilder
    private func fastToggle(_ row: SZRoutingPositionRow) -> some View {
        if row.supportsFastMode {
            SZFastToggleChip(isOn: row.fastModeEnabled) {
                onSetPositionFastMode(row.position, !row.fastModeEnabled)
            }
        }
    }
}

/// The card header's deep link — a real bordered button, centered on the header's height,
/// lifting under the cursor.
private struct SZViewGraphButton: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Label("View Graph", systemImage: "arrow.up.forward")
                .font(.system(size: 11))
                .foregroundStyle(hovered ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(hovered ? 0.10 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(hovered ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary),
                                  lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Close settings and show \(title)'s graph")
    }
}

/// The fast-mode chip: accent-filled when on, quaternary-bordered when off, and visibly
/// alive under the cursor (its own view — hover is per-chip state).
private struct SZFastToggleChip: View {
    let isOn: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : (hovered ? Color.primary : Color.secondary))
                .frame(width: 26, height: 19)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(isOn ? Color.accentColor.opacity(hovered ? 0.85 : 1)
                               : Color.white.opacity(hovered ? 0.08 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(hovered ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary),
                                  lineWidth: isOn ? 0 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(isOn ? "Fast mode is on" : "Turn on fast mode")
    }
}
