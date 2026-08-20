// SPDX-License-Identifier: AGPL-3.0-only
// The AI Settings Routing pane — named profiles filling the agent graphs' declared MODEL
// SLOTS with generation envelopes. One toggle: off hides everything and the active provider
// runs it all; on shows the profiles list, where the SELECTED row is both what runs and
// what the tinted agent cards below edit (no separate activation). Double-click renames in
// place. SZUI can't import SZAI: cards arrive host-mapped (SZHost+RoutingSettings), keyed
// by the typed SZRoutingPosition.
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

/// One saved profile in the pane's list; `isActive` marks the row that runs (= selected).
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
    /// The one selection: `isActive` in `profiles` marks the row that RUNS and is edited
    /// below — routing has no separate edit target. nil active row = routing is off.
    private let selectedProfileName: String?
    private let agents: [SZRoutingAgentCard]
    /// The live resolution of the active provider ("Claude Code · Opus 5") — the toggle's
    /// off-state helper says where everything runs.
    private let activeProviderSummary: String
    /// Non-nil = SZ_MODEL_ROUTING pins this profile at launch; the toggle and list lock.
    private let envPinnedProfileName: String?
    /// SZ_MODEL_ROUTING=0: routing is off for this launch no matter what's persisted.
    private let envKilled: Bool
    private let onSetRoutingEnabled: (Bool) -> Void
    private let onSelectProfile: (String) -> Void
    private let onCreateProfile: () -> Void
    private let onRenameProfile: (String, String) -> Void   // (old, new)
    private let onDuplicateProfile: (String) -> Void
    private let onDeleteProfile: (String) -> Void
    private let onAssignEnvelope: (SZRoutingPosition, String?, String?) -> Void   // (position, providerID, modelID); (p, nil, nil) = clear
    private let onSetPositionEffort: (SZRoutingPosition, String?) -> Void
    private let onSetPositionFastMode: (SZRoutingPosition, Bool) -> Void
    /// Close the settings sheet and land the Agent Graph panel on this agent's plan.
    private let onShowAgentGraph: (String) -> Void
    /// Apply a pack's recommended routes to the edited profile: (agent id, replace
    /// already-set slots). The view only prompts; the merge is the host's.
    private let onApplyRecommended: (String, Bool) -> Void

    // The row being renamed inline (double-click begins; commit via onRenameProfile).
    @State private var renameTarget: String?
    // The conflict prompt's subject: a card whose recommendation would replace set slots.
    @State private var recommendTarget: SZRoutingAgentCard?

    public init(profiles: [SZRoutingProfileRow],
                selectedProfileName: String?,
                agents: [SZRoutingAgentCard],
                activeProviderSummary: String = "",
                envPinnedProfileName: String? = nil,
                envKilled: Bool = false,
                onSetRoutingEnabled: @escaping (Bool) -> Void = { _ in },
                onSelectProfile: @escaping (String) -> Void = { _ in },
                onCreateProfile: @escaping () -> Void = {},
                onRenameProfile: @escaping (String, String) -> Void = { _, _ in },
                onDuplicateProfile: @escaping (String) -> Void = { _ in },
                onDeleteProfile: @escaping (String) -> Void = { _ in },
                onAssignEnvelope: @escaping (SZRoutingPosition, String?, String?) -> Void = { _, _, _ in },
                onSetPositionEffort: @escaping (SZRoutingPosition, String?) -> Void = { _, _ in },
                onSetPositionFastMode: @escaping (SZRoutingPosition, Bool) -> Void = { _, _ in },
                onShowAgentGraph: @escaping (String) -> Void = { _ in },
                onApplyRecommended: @escaping (String, Bool) -> Void = { _, _ in }) {
        self.profiles = profiles
        self.selectedProfileName = selectedProfileName
        self.agents = agents
        self.activeProviderSummary = activeProviderSummary
        self.envPinnedProfileName = envPinnedProfileName
        self.envKilled = envKilled
        self.onSetRoutingEnabled = onSetRoutingEnabled
        self.onSelectProfile = onSelectProfile
        self.onCreateProfile = onCreateProfile
        self.onRenameProfile = onRenameProfile
        self.onDuplicateProfile = onDuplicateProfile
        self.onDeleteProfile = onDeleteProfile
        self.onAssignEnvelope = onAssignEnvelope
        self.onSetPositionEffort = onSetPositionEffort
        self.onSetPositionFastMode = onSetPositionFastMode
        self.onShowAgentGraph = onShowAgentGraph
        self.onApplyRecommended = onApplyRecommended
    }

    private var routingEnabled: Bool { selectedProfileName != nil && !envKilled }
    /// The launch env owns routing this session (=0 kill or a name pin): the toggle and
    /// the list render the pinned truth, locked.
    private var envLocked: Bool { envKilled || envPinnedProfileName != nil }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Routing").font(.system(size: 17, weight: .semibold))

            Text("Each agent lists the kinds of work it needs a model for. A profile picks a model for each; anything left on Default runs on the active provider.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Enable Model Routing",
                       isOn: Binding(get: { routingEnabled }, set: { onSetRoutingEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 13, weight: .medium))
                    .disabled(envLocked)
                toggleHelper
            }

            if routingEnabled {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Profiles")
                        .font(.system(size: 13, weight: .semibold))
                    profilesBox
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(agents) { agentCard($0) }
                    }
                }
                .modifier(SZScrollBottomFade())
            } else {
                Spacer()
            }
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

    /// The sentence under the toggle: the launch env's lock when it governs, else where
    /// everything runs while routing is off. On says nothing — the list speaks.
    @ViewBuilder
    private var toggleHelper: some View {
        Group {
            if envKilled {
                Text("SZ_MODEL_ROUTING turns routing off for this launch. Relaunch without it to use profiles.")
            } else if let pinned = envPinnedProfileName {
                Text("Pinned to \"\(pinned)\" for this launch (SZ_MODEL_ROUTING). Relaunch without it to switch profiles.")
            } else if !routingEnabled {
                Text("Everything runs on \(activeProviderSummary), the active provider.")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    // MARK: - Profiles list (the selected row runs, and is what the cards below edit)

    private var profilesBox: some View {
        VStack(spacing: 0) {
            if profiles.count > 4 {
                ScrollView { profileRows }.frame(height: 104)
            } else {
                profileRows
            }
            Divider()
            listToolbar
        }
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.82)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
    }

    private var profileRows: some View {
        VStack(spacing: 0) {
            ForEach(profiles) { profile in
                SZProfileListRow(name: profile.name, caption: nil,
                                 selected: profile.name == selectedProfileName,
                                 renaming: renameTarget == profile.name,
                                 select: { onSelectProfile(profile.name) },
                                 beginRename: { renameTarget = profile.name },
                                 commitRename: { new in
                                     onRenameProfile(profile.name, new)
                                     renameTarget = nil
                                 },
                                 cancelRename: { renameTarget = nil })
            }
        }
        .disabled(envLocked)
    }

    /// + creates (and runs) an empty profile; − and duplicate act on the selected row.
    private var listToolbar: some View {
        HStack(spacing: 4) {
            SZListGadget(symbol: "plus", disabled: envLocked,
                         help: "New empty profile") { onCreateProfile() }
            SZListGadget(symbol: "minus", disabled: envLocked || selectedProfileName == nil,
                         help: "Delete the selected profile") {
                if let selected = selectedProfileName { onDeleteProfile(selected) }
            }
            SZListGadget(symbol: "plus.square.on.square",
                         disabled: envLocked || selectedProfileName == nil,
                         help: "Duplicate the selected profile") {
                if let selected = selectedProfileName { onDuplicateProfile(selected) }
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
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
            if agent.recommendedCount > 0 {
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
            SZChipMenuFace(text: row.selectionLabel, quiet: !row.isSet)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
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
                SZChipMenuFace(text: row.selectedEffort.map(SZGenerationLabels.effort) ?? "Effort",
                               quiet: row.selectedEffort == nil, maxWidth: 90)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
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

/// One row of the profiles list: an inset rounded selection pill (the sidebar's recipe,
/// not an edge-to-edge bar) — the selected row is what runs. Double-click renames in
/// place; Return commits, Esc or clicking away cancels. Its own view — hover is per-row
/// state.
private struct SZProfileListRow: View {
    let name: String
    let caption: String?
    let selected: Bool
    let renaming: Bool
    let select: () -> Void
    let beginRename: () -> Void
    let commitRename: (String) -> Void
    let cancelRename: () -> Void
    @State private var hovered = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if renaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .focused($fieldFocused)
                    .onSubmit { commitRename(draft) }
                    .onExitCommand { cancelRename() }
                    .onAppear {
                        draft = name
                        fieldFocused = true
                    }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused { cancelRename() }   // clicking away abandons the edit
                    }
            } else {
                Text(name)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
        // Full-bleed rows, clipped by the box: the text shares the cards' 14pt inset so
        // the pane reads as one left edge.
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(selected ? Color.accentColor.opacity(0.22)
                             : Color.white.opacity(hovered ? 0.05 : 0))
        .contentShape(Rectangle())
        // Double-click first so it wins the race; a lone click still selects promptly.
        .onTapGesture(count: 2) { beginRename() }
        .onTapGesture { select() }
        .onHover { hovered = $0 }
    }
}

/// One toolbar gadget under the profiles list: a 22pt square that lifts under the cursor —
/// the chip recipe at glyph size, so the strip reads as one family with the chips.
private struct SZListGadget: View {
    let symbol: String
    var disabled = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { SZListGadgetFace(symbol: symbol) }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.4 : 1)
            .help(help)
    }
}

/// A menu's chip face: the chip recipe with its own chevron, quiet while it shows the
/// unset word. Cap-and-truncate: a long label must never shove the row wider than the sheet.
private struct SZChipMenuFace: View {
    let text: String
    var quiet = false
    var maxWidth: CGFloat = 210
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: maxWidth)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.down")
                .font(.system(size: 7.5, weight: .semibold))
                .opacity(0.55)
        }
        .font(.system(size: 11))
        .foregroundStyle(quiet && !hovered ? Color.secondary : Color.primary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(Color.white.opacity(hovered ? 0.10 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(hovered ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary),
                          lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onHover { hovered = $0 }
    }
}

/// The gadget's face, on its own so a Menu can wear it as a label.
private struct SZListGadgetFace: View {
    let symbol: String
    @State private var hovered = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(hovered ? .primary : .secondary)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(Color.white.opacity(hovered ? 0.10 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .onHover { hovered = $0 }
    }
}

/// The card headers' chip-sized action recipe (View Graph, Use Recommended Models) — a
/// real bordered button, 22pt tall, lifting under the cursor.
private struct SZCardChipButton: View {
    let label: String
    var symbol: String? = nil
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(label)
            }
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
