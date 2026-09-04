// SPDX-License-Identifier: AGPL-3.0-only
// The New Project sheet: one question, where the project will run. Two cards, Create. Pure SZUI:
// the host owns the choice and what happens with it. `required` is the cold-launch case with no
// project to fall back to: no Cancel, no Esc, the sheet stays until a target is picked.
import SwiftUI
import SZCore

public struct SZNewProjectSheet: View {
    private let required: Bool
    private let onCreate: (SZProjectTarget) -> Void
    private let onCancel: () -> Void

    @State private var selection: SZProjectTarget
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(initial: SZProjectTarget, required: Bool,
                onCreate: @escaping (SZProjectTarget) -> Void,
                onCancel: @escaping () -> Void) {
        _selection = State(initialValue: initial)
        self.required = required
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Project")
                .font(.system(size: 15, weight: .semibold))
            Text("Where will it run?")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            HStack(spacing: 12) {
                SZTargetCard(symbol: "desktopcomputer",
                             title: "On this Mac",
                             text: "High performance with Metal. Full access to this Mac's hardware, files and accessories.",
                             selected: selection == .native,
                             animated: !reduceMotion) { selection = .native }
                SZTargetCard(symbol: "globe",
                             title: "In a browser",
                             badge: "BETA",
                             text: "Runs in any web browser (desktop or mobile). Limited to browser capabilities.",
                             selected: selection == .web,
                             animated: !reduceMotion) { selection = .web }
            }
            .padding(.top, 16)

            Text("You can change this later in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 14)

            Divider().padding(.vertical, 12)
            HStack {
                Spacer(minLength: 20)
                if !required {
                    Button("Cancel") { onCancel() }
                        .keyboardShortcut(.cancelAction)
                }
                Button("Create") { onCreate(selection) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(SZWelcomeStyle.accent)
            }
            .controlSize(.regular)
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(required)
        // Arrow keys and Tab move between the cards, 1 / 2 pick one directly. The container takes
        // focus so the keys reach it without a click.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { selection = .native; return .handled }
        .onKeyPress(.rightArrow) { selection = .web; return .handled }
        .onKeyPress(.tab) { selection = selection == .native ? .web : .native; return .handled }
        .onKeyPress("1") { selection = .native; return .handled }
        .onKeyPress("2") { selection = .web; return .handled }
    }
}

/// One selectable target card.
private struct SZTargetCard: View {
    let symbol: String
    let title: String
    /// A short mark beside the title, "BETA" on the browser card; nil for none.
    var badge: String? = nil
    let text: String
    let selected: Bool
    let animated: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(SZWelcomeStyle.text)
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(SZWelcomeStyle.accentSoft)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(SZWelcomeStyle.accentSoft.opacity(0.45), lineWidth: 1))
                    }
                }
                .padding(.top, 10)
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(width: 250, height: 156, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(stroke, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(SZWelcomeStyle.accent)
                        .padding(12)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(animated ? .easeInOut(duration: 0.15) : nil, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fill: Color {
        if selected { return SZWelcomeStyle.primaryFill }
        return Color.white.opacity(hover ? 0.10 : 0.07)
    }

    private var stroke: Color {
        if selected { return SZWelcomeStyle.accent.opacity(hover ? 0.75 : 0.5) }
        return Color.white.opacity(hover ? 0.18 : 0.10)
    }
}
