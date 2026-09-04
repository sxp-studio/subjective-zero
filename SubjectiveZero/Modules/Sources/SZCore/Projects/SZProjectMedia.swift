// SPDX-License-Identifier: AGPL-3.0-only
// Media files that travel inside the `.subz`, and the one rule for reading a file port's value.
//
// A file port (a `string` input with `ui.kind == .filePicker`) holds the PORTABLE form: a path
// relative to the project bundle, `media/<uuid>/<filename>`. The uuid dir preserves the exact
// filename, so two nodes can hold same-named files without a collision — the shape
// `attachments/<uuid>/<filename>` already uses for chat attachments.
//
// THE RULE: a file-port value that is not absolute resolves against the project bundle; an absolute
// one is used as-is. That second branch is not a migration path — it is what lets a project written
// before media moved in-bundle keep rendering, forever, with no fixup pass.
//
// Pure path math over Foundation: no Darwin, no copying. The copy itself is the host's (it needs
// `copyfile` and an off-main task) — see SZHost+Media.swift.
import Foundation

public enum SZProjectMedia {
    /// The bundle subdirectory holding files brought into the project.
    public static let directoryName = "media"

    /// The bundle subdirectory holding recorded videos.
    public static let recordingsDirectoryName = "recordings"

    /// The next recording's number and file URL inside `recordings/`: one past the highest
    /// existing "Recording N" of any extension, bumped further if the candidate name is somehow
    /// taken. Pure path math plus one directory listing; the caller creates the directory.
    public static func nextRecording(in projectURL: URL, fileExtension: String) -> (number: Int, url: URL) {
        let dir = projectURL.appending(path: recordingsDirectoryName)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let taken = existing.compactMap { name -> Int? in
            guard name.hasPrefix("Recording ") else { return nil }
            return Int((name.dropFirst(10) as NSString).deletingPathExtension)
        }
        var number = (taken.max() ?? 0) + 1
        var url = dir.appending(path: "Recording \(number).\(fileExtension)")
        while FileManager.default.fileExists(atPath: url.path) {
            number += 1
            url = dir.appending(path: "Recording \(number).\(fileExtension)")
        }
        return (number, url)
    }

    /// THE RULE. An empty value stays empty (unset is not a path); an absolute one is returned as
    /// itself (tilde expanded — the render loop has no home directory); anything else joins the bundle.
    public static func resolve(_ value: String, in projectURL: URL) -> String {
        guard !value.isEmpty else { return value }
        guard !isAbsolute(value) else { return expanded(value) }
        return projectURL.appending(path: value).path
    }

    /// The bundle-relative form of a file that already lives inside `projectURL`, else nil. Lets a
    /// pick of a file the project already holds become a reference rather than a second copy.
    /// Symlinks are resolved on BOTH sides before comparing: an open panel hands back the resolved
    /// path (`/private/var/…`) while a project opened through `/var/…` would otherwise look like a
    /// different place, and the file would be copied into the very bundle it already lives in.
    public static func relativePath(for url: URL, in projectURL: URL) -> String? {
        let base = projectURL.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    /// Where a file called `filename` lands when it is brought in: `media/<uuid>/<filename>`.
    public static func destination(for filename: String, in projectURL: URL) -> (relative: String, url: URL) {
        let relative = "\(directoryName)/\(UUID().uuidString)/\(filename)"
        return (relative, projectURL.appending(path: relative))
    }

    /// Whether this value names a file OUTSIDE the bundle that should be brought in. False for an
    /// unset value, for an already-relative one, and for an absolute path already inside the bundle
    /// — which is what makes the import idempotent however many times a value is re-committed.
    public static func needsImport(_ value: String, in projectURL: URL) -> Bool {
        guard !value.isEmpty, isAbsolute(value) else { return false }
        return relativePath(for: URL(fileURLWithPath: expanded(value)), in: projectURL) == nil
    }

    /// A leading `~` counts as absolute: it names a place on this machine, not a place in the bundle.
    static func isAbsolute(_ value: String) -> Bool { value.hasPrefix("/") || value.hasPrefix("~") }

    static func expanded(_ value: String) -> String { (value as NSString).expandingTildeInPath }
}

public extension SZGraph {
    /// This graph with every file port's default resolved to an absolute path — what the RUNTIME
    /// loads. A projection, like `SZGraph.renderable`: the model itself keeps the portable form, so
    /// only the code that opens files ever sees a machine path.
    func resolvingFilePaths(in projectURL: URL) -> SZGraph {
        var copy = self
        for n in copy.nodes.indices {
            guard copy.nodes[n].contract != nil else { continue }
            for i in copy.nodes[n].contract!.inputs.indices {
                let port = copy.nodes[n].contract!.inputs[i]
                guard port.ui?.kind == .filePicker, case .string(let value)? = port.def else { continue }
                copy.nodes[n].contract!.inputs[i].def = .string(SZProjectMedia.resolve(value, in: projectURL))
            }
        }
        return copy
    }
}
