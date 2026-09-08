// SPDX-License-Identifier: AGPL-3.0-only
// The Save to Library sheet (node context menu): a name and a one-line description, prefilled from
// the node, and a note on what the save does. A node that came from My Library updates its entry
// instead, and the note lists what differs. The host does the saving.
import SwiftUI

/// The sheet's words, kept out of the view so they can be pinned headlessly.
public enum SZSaveToLibraryWording {
    public static func title(updates: Bool) -> String { updates ? "Update Library Entry" : "Save to Library" }
    public static func button(updates: Bool) -> String { updates ? "Update Entry" : "Save" }

    /// The note under the fields: what happens to the node here, or what the saved copy gets.
    public static func note(updates: Bool, changes: [String]) -> String {
        guard updates else { return "The node in this project stays as it is." }
        guard !changes.isEmpty else { return "The saved copy already matches this node. Saving updates its name and description." }
        return "Replaces the saved copy: " + changes.joined(separator: ", ") + "."
    }
}

public struct SZSaveToLibrarySheet: View {
    private let updates: Bool
    private let changes: [String]
    private let onSave: (String, String) -> Void
    private let onCancel: () -> Void

    @State private var name: String
    @State private var line: String

    public init(name: String, line: String, updates: Bool, changes: [String],
                onSave: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
        self.updates = updates
        self.changes = changes
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: name)
        _line = State(initialValue: line)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(SZSaveToLibraryWording.title(updates: updates))
                .font(.system(size: 15, weight: .semibold))
                .padding(.bottom, 14)

            row("Name") {
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }
            row("What it does") {
                TextField("", text: $line)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }

            Text(SZSaveToLibraryWording.note(updates: updates, changes: changes))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            Divider().padding(.vertical, 12)
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(SZSaveToLibraryWording.button(updates: updates)) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
            .controlSize(.regular)
        }
        .padding(20)
        .frame(width: 380)
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        onSave(trimmedName, line.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            value()
        }
        .padding(.vertical, 5)
    }
}
