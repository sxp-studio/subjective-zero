// SPDX-License-Identifier: AGPL-3.0-only
// Adding a library: paste a link or choose a folder. The note above the button is the whole trust
// story, said once, at the moment the person decides: a library's nodes are code that runs inside
// SubjectiveZero with the same reach the app has, and no check we could run would change that.
import SwiftUI
import SZCore

public struct SZAddLibrarySheet: View {
    private let onChooseFolder: () -> String?
    /// Returns nil when the library was added, else the sentence to show.
    private let onAdd: (String) async -> String?
    private let onCancel: () -> Void

    @State private var text = ""
    @State private var folder: String?
    @State private var problem: String?
    @State private var working = false
    @FocusState private var fieldFocused: Bool

    public init(onChooseFolder: @escaping () -> String?,
                onAdd: @escaping (String) async -> String?,
                onCancel: @escaping () -> Void) {
        self.onChooseFolder = onChooseFolder
        self.onAdd = onAdd
        self.onCancel = onCancel
    }

    private var entry: String { folder ?? text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAdd: Bool { !entry.isEmpty && !working }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Library").font(.system(size: 15, weight: .semibold))

            Text("A library is a folder of nodes. Paste a link to one, or choose a folder on this Mac.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("https://github.com/someone/their-nodes", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($fieldFocused)
                    .disabled(folder != nil || working)
                    .onSubmit { if canAdd { add() } }
                Button("Choose Folder…") {
                    if let picked = onChooseFolder() {
                        folder = picked
                        problem = nil
                    }
                }
                .disabled(working)
            }

            if let folder {
                HStack(spacing: 6) {
                    Text(folder)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        self.folder = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .disabled(working)
                }
            }

            // Said once, here, because this is the moment the decision is actually made.
            Text("Nodes from a library run inside SubjectiveZero with the same access to your Mac as the app has. Only add libraries from people you trust.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.05)))

            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button(working ? "Adding…" : "Add Library") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { fieldFocused = true }
    }

    private func add() {
        let entry = entry
        guard !entry.isEmpty else { return }
        working = true
        problem = nil
        Task {
            problem = await onAdd(entry)
            working = false
        }
    }
}
