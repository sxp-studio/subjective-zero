// SPDX-License-Identifier: AGPL-3.0-only
// The untitled projects' home — where a File ▸ New project lives until Save As gives it a
// user-chosen one: `~/Library/Application Support/SubjectiveZero/Projects/<uuid>/<Name>.subz`
// (a minimal workspace-home pattern — deliberately NOT named "workspace": these projects
// aren't temporary or a working set, they're merely unplaced). "Untitled" is DERIVED, not stored:
// a project is untitled iff its URL is under this directory (`contains`), so there's no flag to
// drift. Quit with an untitled project silently keeps it here and reopens it next launch; Save As
// out of here deletes the source folder (the host's job — this type only answers path questions).
import Foundation

public enum SZUntitledProjects {
    /// `~/Library/Application Support/SubjectiveZero/Projects`
    public static var projectsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SubjectiveZero").appending(path: "Projects")
    }

    /// A fresh `Projects/<uuid>/` directory for one new untitled project (created on disk). The
    /// caller drops its `<Name>.subz` bundle inside; the uuid layer keeps N untitled projects with
    /// the same display name from colliding.
    public static func newProjectDirectory() throws -> URL {
        let dir = projectsDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Is this URL inside the untitled projects' directory? THE definition of "untitled" —
    /// standardized-path prefix match, no stored flag.
    public static func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(projectsDirectory.standardizedFileURL.path + "/")
    }
}
