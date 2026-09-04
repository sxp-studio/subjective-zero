// SPDX-License-Identifier: AGPL-3.0-only
// The Target Platform pane of the Settings sheet: one card per platform in the provider cards'
// look, the active one marked. Clicking another card picks it; the footer then says what the switch
// would convert and asks for it, so nothing starts on a click. Below the cards the conversion report
// while the fleet converts the project. Pure SZUI: the host maps the values and owns the actions.
import SwiftUI
import SZCore

/// One platform row.
public struct SZTargetPlatformRow: Identifiable, Equatable, Sendable {
    public var id: SZProjectTarget
    public var name: String
    public var description: String
    public var beta: Bool
    public var active: Bool
    public var builtCount: Int
    public var nodeCount: Int
    /// A conversion for this platform is running.
    public var converting: Bool
    /// Every generated node has this platform's source; nil when the project has none to build.
    public var ready: Bool?
    /// The row's tooltip ("three.js 0.185.1" on the browser row).
    public var help: String?

    public init(id: SZProjectTarget, name: String, description: String, beta: Bool, active: Bool,
                builtCount: Int, nodeCount: Int, converting: Bool, ready: Bool? = nil,
                help: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.beta = beta
        self.active = active
        self.builtCount = builtCount
        self.nodeCount = nodeCount
        self.converting = converting
        self.ready = ready
        self.help = help
    }

    var symbol: String {
        switch id {
        case .native: "desktopcomputer"
        case .web: "globe"
        }
    }

    var builtLine: String {
        if nodeCount == 0 { return "no nodes yet" }
        if converting { return "converting, \(builtCount) of \(nodeCount) built" }
        return "\(builtCount) of \(nodeCount) nodes built"
    }
}

/// One node in the conversion report.
public struct SZConversionRow: Identifiable, Equatable, Sendable {
    public enum Outcome: Sendable { case ready, converting, queued, unavailable, failed }

    public var id: SZNodeID
    public var title: String
    /// The grey line after the title: the agent's own status message, or "from the library".
    public var reason: String?
    public var outcome: Outcome

    public init(id: SZNodeID, title: String, reason: String?, outcome: Outcome) {
        self.id = id
        self.title = title
        self.reason = reason
        self.outcome = outcome
    }
}

/// The conversion in flight or just finished.
public struct SZConversionReport: Equatable, Sendable {
    public var target: SZProjectTarget
    public var done: Int
    public var total: Int
    public var running: Bool
    /// The finished line: "5 nodes", with ", 1 not available" or ", 1 failed" when it applies.
    public var summary: String?
    public var rows: [SZConversionRow]

    public init(target: SZProjectTarget, done: Int, total: Int, running: Bool, summary: String?,
                rows: [SZConversionRow]) {
        self.target = target
        self.done = done
        self.total = total
        self.running = running
        self.summary = summary
        self.rows = rows
    }

    /// The platform in words: "the browser" / "this Mac".
    public var targetName: String {
        switch target {
        case .native: "this Mac"
        case .web: "the browser"
        }
    }

    var unavailableLabel: String {
        switch target {
        case .native: "NOT ON MAC"
        case .web: "NOT ON BROWSER"
        }
    }
}

public struct SZTargetPlatformPane: View {
    private let rows: [SZTargetPlatformRow]
    private let report: SZConversionReport?
    private let note: String
    private let webActions: (open: () -> Void, export: () -> Void)?
    /// What switching to a platform would do, in one sentence, for the footer while it is picked.
    private let preview: (SZProjectTarget) -> String
    private let onSwitch: (SZProjectTarget) -> Void
    private let onStop: () -> Void
    private let onDone: () -> Void
    /// The card picked but not yet confirmed.
    @State private var picked: SZProjectTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(rows: [SZTargetPlatformRow], report: SZConversionReport?, note: String,
                webActions: (open: () -> Void, export: () -> Void)?,
                preview: @escaping (SZProjectTarget) -> String,
                onSwitch: @escaping (SZProjectTarget) -> Void,
                onStop: @escaping () -> Void,
                onDone: @escaping () -> Void) {
        self.rows = rows
        self.report = report
        self.note = note
        self.webActions = webActions
        self.preview = preview
        self.onSwitch = onSwitch
        self.onStop = onStop
        self.onDone = onDone
    }

    private var converting: Bool { report?.running ?? false }
    private var pickedRow: SZTargetPlatformRow? { rows.first { $0.id == picked && !$0.active } }

    // The Providers pane's rhythm: title row, 12pt copy, the cards, the footer row.
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Target Platform").font(.system(size: 17, weight: .semibold))
                Spacer()
            }

            Text("Where this project runs. Switching converts the nodes that need it. Builds for the other platform are kept, so switching back costs nothing.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(rows) { row in
                        platformCard(row)
                    }
                    if let report {
                        reportCard(report)
                    }
                }
            }
            .modifier(SZScrollBottomFade())
            .frame(minHeight: 260)

            HStack(spacing: 10) {
                Text(pickedRow.map { preview($0.id) } ?? note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                if let pickedRow {
                    Button("Cancel") { picked = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Switch to \(pickedRow.name)") {
                        picked = nil
                        onSwitch(pickedRow.id)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                } else if converting {
                    Button("Stop") { onStop() }
                } else if let webActions {
                    Button("Open in Browser") { webActions.open() }
                    Button("Export as Web App…") { webActions.export() }
                        .buttonStyle(.borderedProminent)
                }
                // Done is the prominent button only when it stands alone (the Providers pane's
                // Confirm is the model); beside Stop or the export it steps back to bordered, and
                // while a card is picked the switch button takes its place.
                if pickedRow != nil {
                    EmptyView()
                } else if converting || webActions != nil {
                    Button("Done") { onDone() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { onDone() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Platform card (the provider card's look; the active or picked row is the selected card)

    @ViewBuilder
    private func platformCard(_ row: SZTargetPlatformRow) -> some View {
        // one radio: the picked card while one is picked, else the active one
        let selected = pickedRow.map { $0.id == row.id } ?? row.active
        HStack(alignment: .top, spacing: 12) {
            // Fixed frames on the glyph and the ACTIVE slot: the rows must not shift when the
            // active one changes.
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 15))
                .frame(width: 16, height: 16)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: row.symbol)
                        .font(.system(size: 13))
                        .frame(width: 16, height: 16)
                    Text(row.name).font(.system(size: 13, weight: .semibold))
                    if row.beta { SZSetupBadge(label: "BETA", color: .orange) }
                    Spacer()
                    // The right column: the pills on one line (ACTIVE always laid out, so the
                    // line keeps its height), the count beneath.
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 6) {
                            SZSetupBadge(label: "ACTIVE", color: .accentColor)
                                .hidden(!row.active)
                            if let ready = row.ready {
                                SZSetupBadge(label: ready ? "READY" : "NEEDS BUILD", color: ready ? .green : .orange)
                            }
                        }
                        Text(row.builtLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(row.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SZSetupCardStyle(selected: selected))
        .contentShape(Rectangle())
        .onTapGesture {
            picked = row.active ? nil : row.id
        }
        .help(row.help ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Report card

    private func reportCard(_ report: SZConversionReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if report.running {
                    Text("Converting for \(report.targetName)").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(report.done) of \(report.total)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Converted for \(report.targetName)").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let summary = report.summary {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(report.rows) { row in
                HStack(spacing: 8) {
                    Text(row.title).font(.system(size: 11))
                    if let reason = row.reason, !reason.isEmpty {
                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(reason)
                    }
                    Spacer(minLength: 8)
                    outcomeBadge(row.outcome, in: report)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SZSetupCardStyle(selected: false))
    }

    @ViewBuilder
    private func outcomeBadge(_ outcome: SZConversionRow.Outcome, in report: SZConversionReport) -> some View {
        switch outcome {
        case .ready: SZSetupBadge(label: "READY", color: .green)
        case .converting:
            HStack(spacing: 5) {
                if !reduceMotion { ProgressView().controlSize(.mini) }
                SZSetupBadge(label: "CONVERTING", color: .orange)
            }
        case .queued: SZSetupBadge(label: "QUEUED", color: .secondary)
        case .unavailable: SZSetupBadge(label: report.unavailableLabel, color: .red)
        case .failed: SZSetupBadge(label: "FAILED", color: .red)
        }
    }
}

private extension View {
    /// Keep the space, drop the pixels: the slot stays laid out either way.
    @ViewBuilder
    func hidden(_ hidden: Bool) -> some View {
        if hidden { self.hidden() } else { self }
    }
}
