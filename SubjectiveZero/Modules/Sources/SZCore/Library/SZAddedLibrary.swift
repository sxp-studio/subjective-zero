// SPDX-License-Identifier: AGPL-3.0-only
// Libraries the user added beyond the two the app knows about: a folder on this Mac, or a git
// repository fetched from a link and pinned to one commit. Pure values; the host does the fetching.
import Foundation

/// A library's own `library.json`: what it calls itself, and which node ABI it was written against.
public struct SZLibraryManifest: Codable, Equatable, Sendable {
    public var name: String
    public var abi: Int?
    public var minAppVersion: String?

    public init(name: String, abi: Int? = nil, minAppVersion: String? = nil) {
        self.name = name
        self.abi = abi
        self.minAppVersion = minAppVersion
    }
}

/// One library the user added, as remembered in the prefs.
public struct SZAddedLibrary: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A folder on this Mac, read where it is and never written to.
        case folder
        /// A git repository cloned under Application Support, pinned to `revision`.
        case link
    }

    /// The `SZLibrarySourceID` raw value: unique among libraries, and stable, because placed nodes
    /// record it as where they came from.
    public var key: String
    /// What the library calls itself in its `library.json`, else a name read off the link or folder.
    public var name: String
    public var kind: Kind
    /// The folder path, or the link it was fetched from.
    public var origin: String
    /// The commit it sits on. Updating moves it; nothing moves it on its own.
    public var revision: String?
    /// Short commit + subject of the revision, for the settings row.
    public var revisionNote: String?

    public var id: String { key }
    public var source: SZLibrarySourceID { SZLibrarySourceID(rawValue: key) }

    public init(key: String, name: String, kind: Kind, origin: String,
                revision: String? = nil, revisionNote: String? = nil) {
        self.key = key
        self.name = name
        self.kind = kind
        self.origin = origin
        self.revision = revision
        self.revisionNote = revisionNote
    }
}

/// What a link points at, once it is recognised. Only https git remotes are accepted: an ssh remote
/// would need the user's key, and a bare path is the folder case.
public struct SZLibraryLink: Equatable, Sendable {
    public var url: String
    /// "owner/repo" when the link is a recognisable forge URL, else the last path component.
    public var shortName: String

    /// Accepts `https://host/owner/repo`, with or without `.git` or a trailing slash, and the
    /// `owner/repo` shorthand, which is read as GitHub because that is what the shorthand means.
    public static func parse(_ text: String) -> SZLibraryLink? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.hasSuffix("/") { raw.removeLast() }
        if raw.lowercased().hasSuffix(".git") { raw.removeLast(4) }

        // owner/repo shorthand: two plain segments, no scheme, no dots in the first.
        if !raw.contains("://") {
            let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, parts.allSatisfy(isSegment) else { return nil }
            return SZLibraryLink(url: "https://github.com/\(parts[0])/\(parts[1])",
                                 shortName: "\(parts[0])/\(parts[1])")
        }
        guard raw.lowercased().hasPrefix("https://"),
              let url = URL(string: raw), let host = url.host(), host.contains(".") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy(isSegment) else { return nil }
        let short = parts.count >= 2 ? "\(parts[parts.count - 2])/\(parts[parts.count - 1])" : parts[0]
        return SZLibraryLink(url: raw, shortName: short)
    }

    /// One path segment: letters, digits and the few punctuation marks forge names use.
    private static func isSegment(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".."
            && s.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }
}

public enum SZLibraryKey {
    /// A folder-name-safe, unique key for a new library. `taken` are the keys already in use, which
    /// includes the two built-in ones, so nobody can add a library that shadows them.
    public static func make(from name: String, taken: Set<String>) -> String {
        let base = SZLibrarySlug.make(name)
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}

/// What changed between the revision a library sits on and the one it would move to.
public struct SZLibraryUpdate: Equatable, Sendable {
    public var revision: String
    public var note: String
    public var added: [String]
    public var changed: [String]
    public var removed: [String]

    public var isEmpty: Bool { added.isEmpty && changed.isEmpty && removed.isEmpty }

    public init(revision: String, note: String, added: [String], changed: [String], removed: [String]) {
        self.revision = revision
        self.note = note
        self.added = added
        self.changed = changed
        self.removed = removed
    }

    /// "3 nodes added, 1 changed" — the counts that are not zero, in a sentence.
    public var summary: String {
        guard !isEmpty else { return "No node changed" }
        var parts: [String] = []
        if !added.isEmpty { parts.append("\(added.count) \(added.count == 1 ? "node" : "nodes") added") }
        if !changed.isEmpty { parts.append("\(changed.count) changed") }
        if !removed.isEmpty { parts.append("\(removed.count) removed") }
        return parts.joined(separator: ", ")
    }
}
