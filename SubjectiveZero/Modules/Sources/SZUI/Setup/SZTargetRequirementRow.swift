// SPDX-License-Identifier: AGPL-3.0-only
// What a project target needs before it can render, and the row that shows it with the fix on it:
// the New Project sheet under its cards, the Target Platform pane under its rows. Pure SZUI: the
// host decides whether a requirement stands and owns the install and the re-check.
import AppKit
import SwiftUI

/// One unmet requirement of a target, as the host describes it.
public struct SZTargetRequirement: Equatable, Sendable {
    public var title: String
    public var message: String
    /// The Terminal line that does the same as the Install button, for the copy button.
    public var command: String

    public init(title: String, message: String, command: String) {
        self.title = title
        self.message = message
        self.command = command
    }
}

/// The requirement with its remedies: Install (the host runs it) and the copyable command.
public struct SZTargetRequirementRow: View {
    private let requirement: SZTargetRequirement
    private let onInstall: () -> Void

    public init(requirement: SZTargetRequirement, onInstall: @escaping () -> Void) {
        self.requirement = requirement
        self.onInstall = onInstall
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
                Text(requirement.title).font(.system(size: 12.5, weight: .semibold))
            }
            Text(requirement.message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Install Apple's developer tools") { onInstall() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Text(requirement.command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(requirement.command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .controlSize(.small)
                .help("Copy the Terminal command")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.3), lineWidth: 1))
    }
}
