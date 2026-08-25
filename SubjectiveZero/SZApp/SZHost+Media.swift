// SPDX-License-Identifier: AGPL-3.0-only
// Bringing a picked or dropped file INTO the project, so a `.subz` is self-contained.
//
// A file port holds a bundle-relative path (`media/<uuid>/<name>`, see SZProjectMedia). Everything
// that writes one funnels through `SZHost.setInputDefault`, so the import hangs off its tail plus
// the one writer that bypasses it (`createMediaNodes`, which pins the default into the contract
// directly).
//
// The copy is TWO-STAGE and never blocks the main actor — which drives the render loop, so a
// blocking copy would freeze the whole graph, and the slow cases are real (an external SSD is ~10s
// for 4 GB, a camera card far worse). Stage one leaves the node on the original absolute path, which
// exists and renders today; stage two flips it to the bundle copy when the bytes have landed. On an
// internal disk the clone is instant and the flip is imperceptible.
import Foundation
import Darwin
import SZCore

@MainActor
extension SZHost {
    /// What the RUNTIME should hold for a string value: a file port's portable value resolved against
    /// the bundle, anything else verbatim. Mirrors what `SZRuntime.loadProject` seeds.
    func runtimeString(_ value: String, port: SZPort?) -> String {
        guard port?.ui?.kind == .filePicker, let projectURL = loadedProjectURL else { return value }
        return SZProjectMedia.resolve(value, in: projectURL)
    }

    /// Copy a file port's newly-set file into the project, then re-point the port at the copy. No-op
    /// unless the value names a file OUTSIDE the bundle — which is what makes it idempotent: the
    /// value it writes back can never satisfy the guard a second time.
    func importMediaIfExternal(node: SZNodeID, port: String, value: SZPortValue,
                               origin: SZMutationOrigin = .user) {
        guard case .string(let path) = value,
              let projectURL = loadedProjectURL,
              store.project?.graph.node(id: node)?.contract?.inputs
                  .first(where: { $0.name == port })?.ui?.kind == .filePicker,
              SZProjectMedia.needsImport(path, in: projectURL)
        else { return }

        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let filename = source.lastPathComponent
        let (relative, destination) = SZProjectMedia.destination(for: filename, in: projectURL)
        status = "bringing \(filename) into the project…"

        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Self.copyIntoBundle(source, to: destination)
                }.value
            } catch {
                self?.status = "could not bring \(filename) into the project: \(error.localizedDescription)"
                print("[SZHost] media import failed for \(source.path): \(error)")
                return
            }
            guard let self else { return }
            // The copy took time, so re-establish everything it assumed. If the project moved, the node
            // went away, or the port was set to something else meanwhile, the copy is an orphan: delete
            // it rather than leave bytes nothing references.
            guard self.loadedProjectURL == projectURL,
                  case .string(path)? = self.store.project?.graph.node(id: node)?.contract?.inputs
                      .first(where: { $0.name == port })?.def
            else {
                try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
                return
            }
            // Back through the funnel: persists, pushes the resolved path into the runtime live, and
            // re-audits the port. A node the fence holds refuses, which leaves the port on the original
            // file — still rendering, and the next committed write imports it.
            self.setInputDefault(node: node, port: port, value: .string(relative), origin: origin)
            self.status = "\(filename) is in the project"
        }
    }

    /// The byte copy. `COPYFILE_CLONE` clones on APFS (instant, no extra space — the same-disk case)
    /// and falls back to a real copy across volumes by itself; `COPYFILE_RECURSIVE` covers a
    /// folder-shaped file (a package), which cloning does not do. Symlinks are resolved first, or the
    /// bundle would hold a link out to a file that can go away.
    nonisolated static func copyIntoBundle(_ source: URL, to destination: URL) throws {
        let resolved = source.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_RECURSIVE)
        guard copyfile(resolved.path, destination.path, nil, flags) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path,
                                                           NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
    }
}
