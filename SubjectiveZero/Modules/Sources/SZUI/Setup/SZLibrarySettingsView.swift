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
    private let myLibraryCanPublish: Bool
    private let added: [SZAddedLibrary]
    private let addedCounts: [String: Int]
    /// Added libraries whose folder is not there right now.
    private let missing: Set<String>
    private let onShowInFinder: () -> Void
    private let onMove: () -> Void
    private let onPublish: () async -> String
    private let onAdd: () -> Void
    private let onReveal: (SZAddedLibrary) -> Void
    private let onCheckForUpdate: (String) async -> String
    private let onApplyUpdate: (String) async -> String
    private let onRemove: (String) -> Void

    /// Per-library line under the row: what the last check or update said.
    @State private var notes: [String: String] = [:]
    @State private var busy: Set<String> = []
    /// Libraries whose check found something, so the row offers Update.
    @State private var updatable: Set<String> = []
    @State private var publishNote: String?
    @State private var publishing = false
    @State private var confirmingRemoval: String?

    public init(builtInCount: Int, myLibraryCount: Int?, myLibraryPath: String?,
                myLibraryCanPublish: Bool = false,
                added: [SZAddedLibrary] = [], addedCounts: [String: Int] = [:],
                missing: Set<String> = [],
                onShowInFinder: @escaping () -> Void, onMove: @escaping () -> Void,
                onPublish: @escaping () async -> String = { "" },
                onAdd: @escaping () -> Void = {},
                onReveal: @escaping (SZAddedLibrary) -> Void = { _ in },
                onCheckForUpdate: @escaping (String) async -> String = { _ in "" },
                onApplyUpdate: @escaping (String) async -> String = { _ in "" },
                onRemove: @escaping (String) -> Void = { _ in }) {
        self.builtInCount = builtInCount
        self.myLibraryCount = myLibraryCount
        self.myLibraryPath = myLibraryPath
        self.myLibraryCanPublish = myLibraryCanPublish
        self.added = added
        self.addedCounts = addedCounts
        self.missing = missing
        self.onShowInFinder = onShowInFinder
        self.onMove = onMove
        self.onPublish = onPublish
        self.onAdd = onAdd
        self.onReveal = onReveal
        self.onCheckForUpdate = onCheckForUpdate
        self.onApplyUpdate = onApplyUpdate
        self.onRemove = onRemove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Library").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Add Library…") { onAdd() }
                    .controlSize(.small)
            }

            Text("The nodes the Library panel offers. Save a node from its menu on the canvas to keep it in your own library, or add someone else's.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            ScrollView {
                VStack(spacing: 10) {
                    builtInRow
                    myLibraryRow
                    ForEach(added) { library in
                        addedRow(library)
                    }
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
            note: publishNote) {
            Button("Show in Finder") { onShowInFinder() }
            Button("Move…") { onMove() }
            if myLibraryCanPublish {
                Button(publishing ? "Publishing…" : "Publish") {
                    publishing = true
                    Task {
                        publishNote = await onPublish()
                        publishing = false
                    }
                }
                .disabled(publishing)
            }
        }
        .disabled(myLibraryCount == nil)
    }

    private func addedRow(_ library: SZAddedLibrary) -> some View {
        let key = library.key
        let working = busy.contains(key)
        let gone = missing.contains(key)
        return row(title: library.name,
                   detail: gone ? "This library isn't where it was" : nodes(addedCounts[key] ?? 0),
                   path: library.kind == .folder ? library.origin : library.origin,
                   note: notes[key] ?? library.revisionNote) {
            if library.kind == .folder {
                Button("Show in Finder") { onReveal(library) }
            } else if updatable.contains(key) {
                Button(working ? "Updating…" : "Update") {
                    run(key) { await onApplyUpdate(key) }
                    updatable.remove(key)
                }
                .disabled(working)
            } else {
                Button(working ? "Checking…" : "Check for Updates") {
                    run(key) {
                        let note = await onCheckForUpdate(key)
                        // The host says "up to date" when there is nothing to move to; anything
                        // else names what would change, which is what Update then applies.
                        if !note.lowercased().hasPrefix("up to date") { updatable.insert(key) }
                        return note
                    }
                }
                .disabled(working || gone)
            }
            if confirmingRemoval == key {
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
