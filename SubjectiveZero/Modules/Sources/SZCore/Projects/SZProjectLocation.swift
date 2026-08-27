// SPDX-License-Identifier: AGPL-3.0-only
// Project identity on disk. The same `.subz` reaches the app as a URL from several places — an open
// panel, a Finder launch, a remembered path string — and those URLs are not interchangeable: a URL
// carries a directory flag as well as a path, so `…/A.subz/` and `…/A.subz` name one project and
// still compare unequal. Everything asking "is this the project I already have?" asks it here,
// because the wrong answer sends the caller on to take a lock this process already holds, and
// `flock` refuses a second descriptor of our own as readily as it refuses another app.
import Foundation

public enum SZProjectLocation {
    /// The canonical path of a project bundle: symlinks resolved, path standardized, no trailing
    /// slash (`URL.path` drops the directory flag). Compare bundles with `isSame` rather than this:
    /// on disk, one bundle can have more than one canonical path. Not a key — the recents list and
    /// the agent-session map key on `standardizedFileURL.path`, which keeps symlinks.
    public static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Do these two URLs name the same project bundle? Compare this, never two `URL`s.
    public static func isSame(_ one: URL, _ other: URL) -> Bool {
        if canonicalPath(one) == canonicalPath(other) { return true }
        // Two spellings can still be one bundle: a case-insensitive volume (the default) reads
        // `Depth.subz` and `depth.subz` as one file, and a hard link or firmlink resolves no better.
        // Where both exist, the filesystem answers what the strings cannot.
        guard let oneID = fileIdentifier(one), let otherID = fileIdentifier(other) else { return false }
        return oneID.isEqual(otherID)
    }

    /// The volume's own identity for a file, nil for anything that isn't there yet (a Save As
    /// destination) — which is why it is a fallback and not the answer.
    private static func fileIdentifier(_ url: URL) -> (NSCopying & NSSecureCoding & NSObjectProtocol)? {
        try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    }
}
