// SPDX-License-Identifier: AGPL-3.0-only
// The AI Settings Routing pane — named profiles filling the agent graphs' declared MODEL
// SLOTS with generation envelopes. The profile is the visible container: a pinned list
// (Off first, ACTIVE badged, activation on the toolbar's right edge) whose selection IS
// what the editor below shows — tinted agent cards, one row per declared slot; the Off row
// renders them read-only with each slot's live resolution. SZUI can't import SZAI: cards
// arrive host-mapped (SZHost+RoutingSettings), keyed by the typed SZRoutingPosition.
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
/// "Default (…)" resolution. Pure so the rule is pinnable in tests; the host renders from it.
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
    /// goes: "Default (Claude · Opus 5)" (grade variants resolve through their standard slot).
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
    /// The pack's recommendation, host-counted for THIS edited profile: how many slots it
    /// would fill, and how many of those are already set (the conflict prompt's numbers).
    /// 0 recommended = no fragment shipped, the button stays absent.
    public var recommendedCount: Int
    public var recommendedConflicts: Int

    public init(id: String, title: String, symbol: String, tint: String? = nil,
                rows: [SZRoutingPositionRow] = [],
                recommendedCount: Int = 0, recommendedConflicts: Int = 0) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.rows = rows
        self.recommendedCount = recommendedCount
        self.recommendedConflicts = recommendedConflicts
    }
}

public struct SZRoutingSettingsView: View {
    private let profiles: [SZRoutingProfileRow]
    /// The list's selection, host-resolved: a saved profile's name, or nil = the Off row.
    /// Off shows the same agent cards read-only, every row stating its live resolution.
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
    private let onEditProfile: (String?) -> Void            // nil = the Off row
    private let onAssignEnvelope: (SZRoutingPosition, String?, String?) -> Void   // (position, providerID, modelID); (p, nil, nil) = clear
    private let onSetPositionEffort: (SZRoutingPosition, String?) -> Void
    private let onSetPositionFastMode: (SZRoutingPosition, Bool) -> Void
    /// Close the settings sheet and land the Agent Graph panel on this agent's plan.
    private let onShowAgentGraph: (String) -> Void
    /// Apply a pack's recommended routes to the edited profile: (agent id, replace
    /// already-set slots). The view only prompts; the merge is the host's.
    private let onApplyRecommended: (String, Bool) -> Void

    // The rename alert's target + draft (view-local; committed via onRenameProfile).
    @State private var renameTarget: String?
    @State private var renameDraft = ""
    // The conflict prompt's subject: a card whose recommendation would replace set slots.
    @State private var recommendTarget: SZRoutingAgentCard?

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
                onEditProfile: @escaping (String?) -> Void = { _ in },
                onAssignEnvelope: @escaping (SZRoutingPosition, String?, String?) -> Void = { _, _, _ in },
                onSetPositionEffort: @escaping (SZRoutingPosition, String?) -> Void = { _, _ in },
                onSetPositionFastMode: @escaping (SZRoutingPosition, Bool) -> Void = { _, _ in },
                onShowAgentGraph: @escaping (String) -> Void = { _ in },
                onApplyRecommended: @escaping (String, Bool) -> Void = { _, _ in }) {
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
        self.onApplyRecommended = onApplyRecommended
    }

    private var activeProfile: SZRoutingProfileRow? { profiles.first(where: \.isActive) }
    /// Off (nil selection) shows the cards read-only — live resolutions, no controls.
    private var isEditable: Bool { editedProfileName != nil }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Routing").font(.system(size: 17, weight: .semibold))

            Text("Each agent lists the kinds of work it needs a model for. A profile picks a model for each; anything left on Default runs on the default provider.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let pinned = envPinnedProfileName {
                Text("Pinned to \"\(pinned)\" for this launch (SZ_MODEL_ROUTING). Relaunch without it to switch profiles.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            profilesBox

            VStack(alignment: .leading, spacing: 10) {
                editorHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(agents) { agentCard($0) }
                    }
                }
                .modifier(SZScrollBottomFade())
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
        .alert("Some slots are already set",
               isPresented: Binding(get: { recommendTarget != nil },
                                    set: { if !$0 { recommendTarget = nil } }),
               presenting: recommendTarget) { agent in
            Button("Replace All") { onApplyRecommended(agent.id, true); recommendTarget = nil }
            Button("Keep Mine") { onApplyRecommended(agent.id, false); recommendTarget = nil }
            Button("Cancel", role: .cancel) { recommendTarget = nil }
        } message: { agent in
            Text("\(agent.recommendedConflicts) of the \(agent.recommendedCount) recommended slots already have a model. Replace them, or keep yours and fill only the empty ones?")
        }
    }

    // MARK: - Profiles list (selection = what the editor below shows)

    /// The pane's one container for profile identity: the pinned Off row, the saved
    /// profiles (scrolling past four), and the toolbar whose right edge holds activation.
    /// The ACTIVE badge marks what runs; the selection highlight marks what's shown.
    private var profilesBox: some View {
        VStack(spacing: 0) {
            profileListRow(name: "Off", caption: "The default provider runs everything",
                           selected: !isEditable, active: activeProfile == nil) {
                onEditProfile(nil)
            }
            if profiles.count > 4 {
                ScrollView { profileRows }.frame(height: 104)
            } else {
                profileRows
            }
            listToolbar
        }
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
    }

    private var profileRows: some View {
        VStack(spacing: 0) {
            ForEach(profiles) { profile in
                Divider().padding(.leading, 12)
                profileListRow(name: profile.name, caption: nil,
                               selected: profile.name == editedProfileName,
                               active: profile.isActive) {
                    onEditProfile(profile.name)
                }
            }
        }
    }

    private func profileListRow(name: String, caption: String?, selected: Bool, active: Bool,
                                select: @escaping () -> Void) -> some View {
        SZProfileListRow(name: name, caption: caption, selected: selected, active: active,
                         select: select)
    }

    /// +, −, and the gear act on the SELECTED row; the right edge switches what RUNS
    /// ("Use This Profile" / "Turn Routing Off"), hidden when the selection already runs.
    private var listToolbar: some View {
        HStack(spacing: 2) {
            Menu {
                Button("Empty Profile") { onCreateProfile() }
                if claudeLadderAvailable {
                    Divider()
                    Button("Claude Ladder: Haiku sorts, Sonnet builds and answers, Opus takes the heavy work") {
                        onCreateClaudeLadder()
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("New profile: start empty, or from a preset. Presets only fill the built-in agents")
            Button {
                if let edited = editedProfileName { onDeleteProfile(edited) }
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .disabled(!isEditable)
            .help("Delete the selected profile. Deleting the active profile turns routing off")
            Menu {
                Button("Rename…") {
                    renameDraft = editedProfileName ?? ""
                    renameTarget = editedProfileName
                }
                Button("Duplicate") { if let edited = editedProfileName { onDuplicateProfile(edited) } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .disabled(!isEditable)
            .help("Rename or duplicate the selected profile")
            Spacer()
            activationButton
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
            .fill(Color.black.opacity(0.12)))
    }

    /// The one control that changes what runs. Absent when the selection already runs;
    /// locked (not hidden) under a launch pin so the state stays explicable.
    @ViewBuilder
    private var activationButton: some View {
        if let edited = editedProfileName, edited != activeProfile?.name {
            Button("Use This Profile") { onSelectActiveProfile(edited) }
                .buttonStyle(.bordered)
                .disabled(envPinnedProfileName != nil)
                .help(envPinnedProfileName != nil
                    ? "SZ_MODEL_ROUTING pins the profile for this launch"
                    : "Run new chats and runs on \"\(edited)\". Refused while a run is in flight")
        } else if !isEditable, activeProfile != nil {
            Button("Turn Routing Off") { onSelectActiveProfile(nil) }
                .buttonStyle(.bordered)
                .disabled(envPinnedProfileName != nil)
                .help(envPinnedProfileName != nil
                    ? "SZ_MODEL_ROUTING pins the profile for this launch"
                    : "Run everything on the default provider. Refused while a run is in flight")
        }
    }

    /// The editor's scope title: the selected profile's name, or Off's read-only summary.
    @ViewBuilder
    private var editorHeader: some View {
        if let edited = editedProfileName {
            Text(edited)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        } else if profiles.isEmpty {
            Text("No profiles yet. Create one to give specific work its own model.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            Text("Where each kind of work goes right now")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Agent cards (one per pack, one row per declared slot)

    private func agentCard(_ agent: SZRoutingAgentCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader(agent)
            // Dividers separate ROWS only — the header band is its own edge, and a hairline
            // right under it read as a smudge.
            if agent.rows.isEmpty {
                Text("This agent doesn't ask for model choices; it runs on the default provider.")
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
            if isEditable, agent.recommendedCount > 0 {
                SZCardChipButton(label: "Use Recommended Models", symbol: "wand.and.stars",
                                 help: "Fill this agent's slots with the models its pack recommends") {
                    if agent.recommendedConflicts == 0 { onApplyRecommended(agent.id, true) }
                    else { recommendTarget = agent }
                }
            }
            SZCardChipButton(label: "View Graph", symbol: "arrow.up.forward",
                             help: "Close settings and show \(agent.title)'s graph") {
                onShowAgentGraph(agent.id)
            }
        }
        .padding(.horizontal, 14)
        // The card's 2pt outline overlaps the header's top edge, so the VISIBLE band starts
        // 2pt down — bias the content by that much, then fix the height so centering is
        // arithmetic, not font metrics.
        .padding(.top, 2)
        .frame(height: 40)
        // The agent's hue as the header band — contained to the header, half strength at
        // the top deepening to full at its bottom edge.
        .background(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10)
            .fill(headerWash(SZAgentTint.color(agent.tint))))
    }

    private func headerWash(_ tint: Color?) -> AnyShapeStyle {
        guard let tint else { return AnyShapeStyle(Color.white.opacity(0.03)) }
        return AnyShapeStyle(LinearGradient(
            colors: [tint.opacity(0.11), tint.opacity(0.22)],
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
            if isEditable {
                if row.isSet {
                    effortMenu(row)
                    fastToggle(row)
                }
                envelopeMenu(row)
            } else {
                // Off: no controls, just the truth — where this slot's work goes today.
                Text(row.selectionLabel)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func envelopeMenu(_ row: SZRoutingPositionRow) -> some View {
        Menu {
            // The clear action, spelled as its destination ("Default (…)", live-resolved;
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
        .help("Pick the provider and model this runs on. The first item shows where it goes when you don't")
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
            .help("Reasoning effort for this model. Default is the model's own")
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

/// One row of the profiles list: name (Off carries its caption), the selection wash, and
/// the ACTIVE badge on whichever row governs new work. Its own view — hover is per-row state.
private struct SZProfileListRow: View {
    let name: String
    let caption: String?
    let selected: Bool
    let active: Bool
    let select: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Text(name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                if active {
                    Text("Active")
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.22)
                                 : Color.white.opacity(hovered ? 0.04 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A card header's chip-sized action (View Graph, Use Recommended Models) — a real bordered
/// button, centered on the header's height, lifting under the cursor.
private struct SZCardChipButton: View {
    let label: String
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .font(.system(size: 11))
                .foregroundStyle(hovered ? .primary : .secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)   // a fixed box — SwiftUI centers it exactly
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(hovered ? 0.10 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(hovered ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary),
                                  lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// The fast-mode chip, worded: "Fast On" / "Fast Off" with the bolt. Activation is a
/// one-shot show: the accent CHARGES the chip left to right, then a highlight shimmers
/// across the bolt. Turning off stays quiet, and Reduce Motion collapses it all to the
/// plain state change.
private struct SZFastToggleChip: View {
    let isOn: Bool
    let action: () -> Void
    @State private var hovered = false
    @State private var sweep: CGFloat            // the accent flood's progress (1 = settled)
    @State private var charge: Double            // the accent's visibility (fades out on off)
    @State private var shimmer: CGFloat = -1.4   // the bolt highlight's position (off-glyph)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isOn: Bool, action: @escaping () -> Void) {
        self.isOn = isOn
        self.action = action
        _sweep = State(initialValue: 1)
        _charge = State(initialValue: isOn ? 1 : 0)
    }

    var body: some View {
        Button(action: action) {
            // The label's box is the WIDER of the two texts, always — flipping the word
            // must never nudge the row.
            ZStack {
                Label { Text("Fast Off") } icon: { bolt }.hidden()
                Label { Text(isOn ? "Fast On" : "Fast Off") } icon: { bolt }
            }
            .font(.system(size: 11))
            .foregroundStyle(isOn ? Color.white : (hovered ? Color.primary : Color.secondary))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(chipFill)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(hovered ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary),
                              lineWidth: isOn ? 0 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(isOn ? "Fast mode is on" : "Turn on fast mode")
        .onChange(of: isOn) { _, on in
            if on {
                guard !reduceMotion else { sweep = 1; charge = 1; return }
                sweep = 0
                charge = 1
                withAnimation(.easeOut(duration: 0.28)) { sweep = 1 }
                shimmer = -1.4
                withAnimation(.easeInOut(duration: 0.5).delay(0.18)) { shimmer = 1.4 }
            } else {
                // Off is quiet: the accent just fades back to the gray lift.
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { charge = 0 }
            }
        }
    }

    /// The charge: base lift, with the accent flooding left → right on activation and
    /// fading away on deactivation.
    private var chipFill: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(hovered ? 0.10 : 0.05))
                Rectangle()
                    .fill(Color.accentColor.opacity(hovered ? 0.85 : 1))
                    .frame(width: geo.size.width * sweep)
                    .opacity(charge)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    /// The bolt, with a one-shot highlight sweeping across the glyph after the charge lands.
    private var bolt: some View {
        Image(systemName: "bolt.fill")
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white, .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .offset(x: geo.size.width * shimmer)
                }
                .mask(Image(systemName: "bolt.fill"))
            }
    }
}
