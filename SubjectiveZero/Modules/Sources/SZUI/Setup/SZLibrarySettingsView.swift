// SPDX-License-Identifier: AGPL-3.0-only
// The Library pane of the Settings sheet: one row per library, the built-in one and the user's own,
// with node counts, the folder of the user's and the two things to do with it (show, move). Pure SZUI:
// the host hands in the values and owns the actions.
import SwiftUI
import SZCore

public struct SZLibrarySettingsView: View {
    private let builtInCount: Int
    /// nil until the first save creates the library.
    private let myLibraryCount: Int?
    private let myLibraryPath: String?
    private let onShowInFinder: () -> Void
    private let onMove: () -> Void

    public init(builtInCount: Int, myLibraryCount: Int?, myLibraryPath: String?,
                onShowInFinder: @escaping () -> Void, onMove: @escaping () -> Void) {
        self.builtInCount = builtInCount
        self.myLibraryCount = myLibraryCount
        self.myLibraryPath = myLibraryPath
        self.onShowInFinder = onShowInFinder
        self.onMove = onMove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Library").font(.system(size: 17, weight: .semibold))

            Text("The nodes the Library panel offers. Save a node from its menu on the canvas to keep it in your own library.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            VStack(spacing: 10) {
                row(title: SZLibrarySourceID.builtIn.displayName,
                    detail: "\(nodes(builtInCount)), ships with the app", path: nil) {
                    EmptyView()
                }
                row(title: SZLibrarySourceID.mine.displayName,
                    detail: myLibraryCount.map(nodes) ?? "Created the first time you save a node",
                    path: myLibraryCount == nil ? nil : myLibraryPath) {
                    Button("Show in Finder") { onShowInFinder() }
                    Button("Move…") { onMove() }
                }
                .disabled(myLibraryCount == nil)
            }

            Text("Adding a library by link and updating it are coming.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func nodes(_ count: Int) -> String { count == 1 ? "1 node" : "\(count) nodes" }

    private func row(title: String, detail: String, path: String?,
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
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { actions() }
                .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
    }
}
