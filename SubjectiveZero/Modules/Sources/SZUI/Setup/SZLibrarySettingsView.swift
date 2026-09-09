// SPDX-License-Identifier: AGPL-3.0-only
// The Library pane of the Settings sheet: one row per library, with node counts, where it came from,
// and what can be done with it. Adding one takes a folder or a link; checking for a newer version is
// always something the person asks for, never something that happens on its own. Pure SZUI: values in,
// closures out, and the async closures hand back the sentence to show.
import SwiftUI
import SZCore

public struct SZLibrarySettingsView: View {
    private let builtInCount: Int
    /// nil until the first save creates the library.
    private let myLibraryCount: Int?
    private let myLibraryPath: String?
    private let added: [SZAddedLibrary]
    private let addedCounts: [String: Int]
    /// Added libraries whose folder is not there right now.
    private let missing: Set<String>
    private let onShowInFinder: () -> Void
    private let onMove: () -> Void
    private let onAdd: () -> Void
    private let onReveal: (SZAddedLibrary) -> Void
    /// The sentence to show, and whether there is actually something to move to. Two values, because
    /// a failed check has a sentence too and must not arm the Update button.
    private let onCheckForUpdate: (String) async -> (note: String, hasUpdate: Bool)
    private let onApplyUpdate: (String) async -> String
    private let onRemove: (String) -> Void

    /// Per-library line under the row: what the last check or update said.
    @State private var notes: [String: String] = [:]
    @State private var busy: Set<String> = []
    /// Libraries whose check found something, so the row offers Update.
    @State private var updatable: Set<String> = []
    @State private var confirmingRemoval: String?

    public init(builtInCount: Int, myLibraryCount: Int?, myLibraryPath: String?,
                added: [SZAddedLibrary] = [], addedCounts: [String: Int] = [:],
                missing: Set<String> = [],
                onShowInFinder: @escaping () -> Void, onMove: @escaping () -> Void,
                onAdd: @escaping () -> Void = {},
                onReveal: @escaping (SZAddedLibrary) -> Void = { _ in },
                onCheckForUpdate: @escaping (String) async -> (note: String, hasUpdate: Bool) = { _ in ("", false) },
                onApplyUpdate: @escaping (String) async -> String = { _ in "" },
                onRemove: @escaping (String) -> Void = { _ in }) {
        self.builtInCount = builtInCount
        self.myLibraryCount = myLibraryCount
        self.myLibraryPath = myLibraryPath
        self.added = added
        self.addedCounts = addedCounts
        self.missing = missing
        self.onShowInFinder = onShowInFinder
        self.onMove = onMove
        self.onAdd = onAdd
        self.onReveal = onReveal
        self.onCheckForUpdate = onCheckForUpdate
        self.onApplyUpdate = onApplyUpdate
        self.onRemove = onRemove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Library").font(.system(size: 17, weight: .semibold))

            Text("Where the nodes you place come from. Save a node from its menu on the canvas to keep it, add someone else's from a link or a folder, or ask your agent to do any of it.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    builtInRow
                    myLibraryRow
                    ForEach(added) { library in
                        addedRow(library)
                    }
                    // Under the rows, where it reads as "and one more", rather than up in the title.
                    Button { onAdd() } label: {
                        Label("Add Library…", systemImage: "plus")
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var builtInRow: some View {
        row(title: SZLibrarySourceID.builtIn.displayName,
            detail: "\(nodes(builtInCount)), ships with the app", path: nil, note: nil) {
            EmptyView()
        }
    }

    private var myLibraryRow: some View {
        row(title: SZLibrarySourceID.mine.displayName,
            detail: myLibraryCount.map(nodes) ?? "Created the first time you save a node",
            path: myLibraryCount == nil ? nil : myLibraryPath,
            note: nil) {
            Button("Show in Finder") { onShowInFinder() }
            Button("Move…") { onMove() }
        }
        .disabled(myLibraryCount == nil)
    }

    private func addedRow(_ library: SZAddedLibrary) -> some View {
        let key = library.key
        let working = busy.contains(key)
        let gone = missing.contains(key)
        // Who made it, under what license, and which app it was made with: what a person needs to
        // decide whether to keep running someone else's code.
        let detail = gone ? "This library isn't where it was" : nodes(addedCounts[key] ?? 0)
        return row(title: library.name,
                   detail: [detail, library.provenance].compactMap { $0 }.joined(separator: " · "),
                   path: library.origin,
                   note: notes[key] ?? library.versionNote) {
            if library.kind == .folder {
                Button("Show in Finder") { onReveal(library) }
            } else if updatable.contains(key) {
                Button(working ? "Updating…" : "Update") {
                    // Disarmed when the work finishes, not when the click lands: doing it here would
                    // flip the row to the check branch and label the update "Checking…".
                    run(key) {
                        let note = await onApplyUpdate(key)
                        updatable.remove(key)
                        return note
                    }
                }
                .disabled(working)
            } else {
                Button(working ? "Checking…" : "Check for Updates") {
                    run(key) {
                        let result = await onCheckForUpdate(key)
                        if result.hasUpdate { updatable.insert(key) }
                        return result.note
                    }
                }
                .disabled(working || gone)
            }
            if confirmingRemoval == key {
                // A way out, in the same cluster: without one, a second click on the trailing button
                // lands on the armed Remove and takes the library (and a fetched one's folder) away.
                Button("Cancel") { confirmingRemoval = nil }
                Button("Remove", role: .destructive) {
                    confirmingRemoval = nil
                    onRemove(key)
                }
            } else {
                Button("Remove…") { confirmingRemoval = key }
            }
        }
    }

    /// Runs one row's action, keeping it busy and parking whatever it says under the row.
    private func run(_ key: String, _ work: @escaping () async -> String) {
        busy.insert(key)
        Task {
            let note = await work()
            notes[key] = note.isEmpty ? nil : note
            busy.remove(key)
        }
    }

    private func nodes(_ count: Int) -> String { count == 1 ? "1 node" : "\(count) nodes" }

    private func row(title: String, detail: String, path: String?, note: String?,
                     @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                if let path {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if let note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { actions() }
                .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
    }
}
