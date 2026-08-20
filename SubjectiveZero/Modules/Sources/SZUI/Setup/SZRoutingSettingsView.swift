// SPDX-License-Identifier: AGPL-3.0-only
// The AI Settings Routing pane — named profiles mapping positions (agents,
// grades, queries) to generation envelopes. Top: the ACTIVE-profile menu (Off = the identity
// world) + profile management; below: the mapping form for the profile being edited, a grouped
// divider-separated list (the Xcode Components shape). SZUI can't import SZAI: rows arrive
// host-mapped (SZHost+RoutingSettings), keyed by the typed SZRoutingPosition — the view
// switches on its cases for layout (indent, section headers) and echoes it back in closures.
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

/// One mappable position in a profile — typed, so the SZUI↔host seam is a switch on
/// cases, never string matching.
public enum SZRoutingPosition: Hashable, Sendable {
    case agent(id: String)
    case queries
    case grade(String)
}

/// One mappable position's row — a pure view-model. Effort/fast props are
/// resolved against the ROUTED model host-side; empty/false hides those controls.
public struct SZRoutingPositionRow: Identifiable, Equatable, Sendable {
    public var position: SZRoutingPosition
    public var id: SZRoutingPosition { position }
    public var label: String
    public var symbol: String?         // agent header rows carry the agent's glyph
    public var caption: String?        // the row's one explanatory line
    public var selectionLabel: String  // "Default" (unset) or "codex · GPT-5.6 Terra"
    public var isSet: Bool
    public var options: [SZRoutingEnvelopeOption]
    public var effortOptions: [String]
    public var selectedEffort: String?
    public var supportsFastMode: Bool
    public var fastModeEnabled: Bool

    public init(position: SZRoutingPosition, label: String, symbol: String? = nil, caption: String? = nil,
                selectionLabel: String, isSet: Bool,
                options: [SZRoutingEnvelopeOption] = [],
                effortOptions: [String] = [], selectedEffort: String? = nil,
                supportsFastMode: Bool = false, fastModeEnabled: Bool = false) {
        self.position = position
        self.label = label
        self.symbol = symbol
        self.caption = caption
        self.selectionLabel = selectionLabel
        self.isSet = isSet
        self.options = options
        self.effortOptions = effortOptions
        self.selectedEffort = selectedEffort
        self.supportsFastMode = supportsFastMode
        self.fastModeEnabled = fastModeEnabled
    }
}

public struct SZRoutingSettingsView: View {
    private let profiles: [SZRoutingProfileRow]
    /// The profile whose table the form shows (host-resolved: requested → active → first);
    /// nil = no saved profiles, the pane shows only the empty-state sentence.
    private let editedProfileName: String?
    private let positions: [SZRoutingPositionRow]
    /// Non-nil = SZ_MODEL_ROUTING pins this profile at launch; the active menu locks.
    private let envPinnedProfileName: String?
    private let onSelectActiveProfile: (String?) -> Void
    private let onCreateProfile: () -> Void
    private let onRenameProfile: (String, String) -> Void   // (old, new)
    private let onDuplicateProfile: (String) -> Void
    private let onDeleteProfile: (String) -> Void
    private let onEditProfile: (String) -> Void
    private let onAssignEnvelope: (SZRoutingPosition, String?, String?) -> Void   // (position, providerID, modelID); (p, nil, nil) = Default
    private let onSetPositionEffort: (SZRoutingPosition, String?) -> Void
    private let onSetPositionFastMode: (SZRoutingPosition, Bool) -> Void

    // The rename alert's target + draft (view-local; committed via onRenameProfile).
    @State private var renameTarget: String?
    @State private var renameDraft = ""

    public init(profiles: [SZRoutingProfileRow],
                editedProfileName: String?,
                positions: [SZRoutingPositionRow],
                envPinnedProfileName: String? = nil,
                onSelectActiveProfile: @escaping (String?) -> Void = { _ in },
                onCreateProfile: @escaping () -> Void = {},
                onRenameProfile: @escaping (String, String) -> Void = { _, _ in },
                onDuplicateProfile: @escaping (String) -> Void = { _ in },
                onDeleteProfile: @escaping (String) -> Void = { _ in },
                onEditProfile: @escaping (String) -> Void = { _ in },
                onAssignEnvelope: @escaping (SZRoutingPosition, String?, String?) -> Void = { _, _, _ in },
                onSetPositionEffort: @escaping (SZRoutingPosition, String?) -> Void = { _, _ in },
                onSetPositionFastMode: @escaping (SZRoutingPosition, Bool) -> Void = { _, _ in }) {
        self.profiles = profiles
        self.editedProfileName = editedProfileName
        self.positions = positions
        self.envPinnedProfileName = envPinnedProfileName
        self.onSelectActiveProfile = onSelectActiveProfile
        self.onCreateProfile = onCreateProfile
        self.onRenameProfile = onRenameProfile
        self.onDuplicateProfile = onDuplicateProfile
        self.onDeleteProfile = onDeleteProfile
        self.onEditProfile = onEditProfile
        self.onAssignEnvelope = onAssignEnvelope
        self.onSetPositionEffort = onSetPositionEffort
        self.onSetPositionFastMode = onSetPositionFastMode
    }

    private var activeProfile: SZRoutingProfileRow? { profiles.first(where: \.isActive) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Routing").font(.system(size: 17, weight: .semibold))

            Text("New chats and runs resolve through the active profile; anything it doesn't map falls back to the default provider.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            profileBar

            if let name = editedProfileName {
                editorBar(name)
                ScrollView {
                    mappingForm
                }
            } else {
                Text("No profile active. Every agent runs on the default provider, exactly as before profiles existed.")
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
                Button("New Profile") { onCreateProfile() }
                    .controlSize(.small)
                    .help("Create an empty profile — everything starts on the default model")
            }
            if let pinned = envPinnedProfileName {
                Text("Pinned to \"\(pinned)\" by the launch environment — relaunch without SZ_MODEL_ROUTING to change it.")
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
        .help("The profile new chats and runs resolve through — switching is refused while a run is in flight")
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

    // MARK: - The mapping form (one grouped list: agents, queries, grades)

    /// Where the "Task Grading" header slots in — before the first grade row.
    private var firstGradeID: SZRoutingPosition? {
        positions.first { if case .grade = $0.position { true } else { false } }?.id
    }

    private var mappingForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(positions.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 14) }
                if row.id == firstGradeID { assessmentHeader }
                positionRow(row)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.82)))
    }

    private var assessmentHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Task Grading")
                .font(.system(size: 13, weight: .semibold))
            Text("During a run the Director grades each task it hands out; the grade picks which model implements it.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private func positionRow(_ row: SZRoutingPositionRow) -> some View {
        // Grade rows indent under their section header.
        let indented = if case .grade = row.position { true } else { false }
        return HStack(spacing: 10) {
            if let symbol = row.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .font(.system(size: 13, weight: row.symbol != nil ? .semibold : .regular))
                if let caption = row.caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            if row.isSet {
                effortMenu(row)
                fastToggle(row)
            }
            envelopeMenu(row)
        }
        .padding(.leading, indented ? 26 : 0)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func envelopeMenu(_ row: SZRoutingPositionRow) -> some View {
        Menu {
            Button {
                onAssignEnvelope(row.position, nil, nil)
            } label: {
                if !row.isSet { Label("Default", systemImage: "checkmark") }
                else { Text("Default") }
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
        .help("Pick the provider and model this runs on — Default inherits from the level above")
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
            .help("Reasoning effort for this model")
        }
    }

    /// Only where the ROUTED model honours it — an inert toggle is a lie.
    @ViewBuilder
    private func fastToggle(_ row: SZRoutingPositionRow) -> some View {
        if row.supportsFastMode {
            Button {
                onSetPositionFastMode(row.position, !row.fastModeEnabled)
            } label: {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(row.fastModeEnabled ? Color.yellow : Color.secondary.opacity(0.5))
            }
            .controlSize(.small)
            .help(row.fastModeEnabled ? "Fast mode is on" : "Turn on fast mode")
        }
    }
}
