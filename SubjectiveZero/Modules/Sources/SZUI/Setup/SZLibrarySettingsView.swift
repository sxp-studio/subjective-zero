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
        row(symbol: "shippingbox.fill", tint: .secondary,
            title: SZLibrarySourceID.builtIn.displayName,
            count: builtInCount,
            detail: "Ships with the app", path: nil, note: nil, updateReady: false) {
            EmptyView()
        }
    }

    private var myLibraryRow: some View {
        row(symbol: "square.and.pencil", tint: Self.mine,
            title: SZLibrarySourceID.mine.displayName,
            count: myLibraryCount,
            detail: myLibraryCount == nil ? "Created the first time you save a node" : "Yours to write to",
            path: myLibraryCount == nil ? nil : myLibraryPath,
            note: nil, updateReady: false) {
            Button("Show in Finder") { onShowInFinder() }
            Button("Move…") { onMove() }
        }
        .disabled(myLibraryCount == nil)
    }

    private func addedRow(_ library: SZAddedLibrary) -> some View {
        let key = library.key
        let working = busy.contains(key)
        let gone = missing.contains(key)
        let ready = updatable.contains(key)
        // A folder is read where it lives; a link was downloaded. Different things, different glyph.
        let fromFolder = library.kind == .folder
        return row(symbol: fromFolder ? "folder.fill" : "arrow.down.circle.fill",
                   tint: fromFolder ? Self.folder : Self.fetched,
                   title: library.name,
                   count: gone ? nil : addedCounts[key],
                   // Who made it, under what license, and which app it was made with: what a person
                   // needs to decide whether to keep running someone else's code.
                   detail: gone ? "This library isn't where it was" : (library.provenance ?? "Added by you"),
                   path: library.origin,
                   note: notes[key] ?? library.versionNote,
                   updateReady: ready) {
            if fromFolder {
                Button("Show in Finder") { onReveal(library) }
            } else if ready {
                Button(working ? "Updating…" : "Update") {
                    // Disarmed when the work finishes, not when the click lands: doing it here would
                    // flip the row to the check branch and label the update "Checking…".
                    run(key) {
                        let note = await onApplyUpdate(key)
                        updatable.remove(key)
                        return note
                    }
                }
                .buttonStyle(.borderedProminent)
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

    /// Three kinds of library, told apart by their glyph rather than by reading: one ships with the
    /// app, one is yours to write to, one came from somewhere else.
    private static let mine = Color(red: 0.878, green: 0.643, blue: 0.290)
    private static let folder = Color(red: 0.635, green: 0.518, blue: 0.851)
    private static let fetched = Color(red: 0.349, green: 0.663, blue: 0.867)
    private static let ready = Color(red: 0.408, green: 0.741, blue: 0.510)

    private func row(symbol: String, tint: Color, title: String, count: Int?, detail: String,
                     path: String?, note: String?, updateReady: Bool,
                     @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                if let count {
                    // The one number that says what is in here, where the eye lands first.
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 34)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if updateReady {
                        // A state, not a note: the row has something waiting and says so where the
                        // name is, rather than in the dimmest line on the card.
                        Text("Update available")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Self.ready)
                            .padding(.horizontal, 6)
                            .frame(height: 15)
                            .background(Capsule().fill(Self.ready.opacity(0.16)))
                    }
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                if let path {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(updateReady ? AnyShapeStyle(Self.ready) : AnyShapeStyle(.tertiary))
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
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(updateReady ? Self.ready.opacity(0.35) : .clear)
        )
    }
}
