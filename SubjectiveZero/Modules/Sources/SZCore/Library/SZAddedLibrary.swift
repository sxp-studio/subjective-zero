// SPDX-License-Identifier: AGPL-3.0-only
// Libraries the user added beyond the two the app knows about: a folder on this Mac, or a git
// repository fetched from a link and pinned to one commit. Pure values; the host does the fetching.
import Foundation

/// A library's own `library.json`: what it calls itself, who made it, how it may be used, and which
/// SubjectiveZero it was written against. Only `name` is required, because a folder of node folders is
/// already a working library; everything else is what makes one safe to hand to somebody else.
public struct SZLibraryManifest: Codable, Equatable, Sendable {
    /// What the library is called wherever it is listed. Required.
    public var name: String
    /// One line on what the library is for.
    public var description: String?
    /// Who made it. A person or a project, not an id.
    public var author: String?
    /// How the nodes may be used, as an SPDX id ("MIT", "AGPL-3.0-only"). A node is code someone
    /// copies into their own project, so a library with no license says nothing about whether they may.
    public var license: String?
    /// Where the library lives, for the person who wants to see the source or file an issue.
    public var homepage: String?
    /// The SubjectiveZero it was written and last tested against ("0.4.0"). Advisory: it is what a
    /// person reads when a node misbehaves on a much later build.
    public var madeWith: String?
    /// The earliest SubjectiveZero that can run these nodes. Checked: an app older than this refuses
    /// the library rather than letting every node fail to build one at a time.
    public var minAppVersion: String?
    /// The node ABI the author wrote against, if they tracked it (RUNTIME.md numbers these). Shown,
    /// never checked: the app has no ABI number of its own to compare with.
    public var abi: Int?

    public init(name: String, description: String? = nil, author: String? = nil, license: String? = nil,
                homepage: String? = nil, madeWith: String? = nil, minAppVersion: String? = nil,
                abi: Int? = nil) {
        self.name = name
        self.description = description
        self.author = author
        self.license = license
        self.homepage = homepage
        self.madeWith = madeWith
        self.minAppVersion = minAppVersion
        self.abi = abi
    }
}

/// Comparing "0.4.0" with "0.10.2" the way people mean it: field by field, numerically, missing
/// fields are zero. Anything unparseable sorts as 0, so a garbled version never blocks a library.
public enum SZAppVersionOrder {
    public static func fields(_ version: String) -> [Int] {
        version.split(separator: "-").first.map(String.init)?
            .split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 } ?? [0]
    }

    /// True when `version` is at least `required`.
    public static func atLeast(_ version: String, _ required: String) -> Bool {
        let a = fields(version), b = fields(required)
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0, r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return true
    }
}

public extension SZLibraryManifest {
    /// Why this app cannot run the library, in a sentence for the person. nil when it can.
    /// Only `minAppVersion` refuses: it is the one claim whose failure means nothing would work.
    func refusal(appVersion: String) -> String? {
        guard let required = minAppVersion, !required.isEmpty else { return nil }
        // A build with no version of its own (a dev run) is not told it is too old.
        guard appVersion != "dev", !SZAppVersionOrder.atLeast(appVersion, required) else { return nil }
        return "\(name) needs SubjectiveZero \(required) or newer, and this is \(appVersion)."
    }

    /// What is missing before this library is fit to hand to someone else, for the Publish path.
    var missingForSharing: [String] {
        var missing: [String] = []
        if (author ?? "").isEmpty { missing.append("an author") }
        if (license ?? "").isEmpty { missing.append("a license") }
        return missing
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
    /// What the library's own `library.json` said when it was added or last updated.
    public var manifest: SZLibraryManifest?

    public var id: String { key }
    public var source: SZLibrarySourceID { SZLibrarySourceID(rawValue: key) }

    public init(key: String, name: String, kind: Kind, origin: String,
                revision: String? = nil, revisionNote: String? = nil,
                manifest: SZLibraryManifest? = nil) {
        self.key = key
        self.name = name
        self.kind = kind
        self.origin = origin
        self.revision = revision
        self.revisionNote = revisionNote
        self.manifest = manifest
    }

    /// "by Someone · MIT · made with 0.4.0" — the provenance line under a settings row, only the
    /// parts the author actually filled in.
    public var provenance: String? {
        var parts: [String] = []
        if let author = manifest?.author, !author.isEmpty { parts.append("by \(author)") }
        if let license = manifest?.license, !license.isEmpty { parts.append(license) }
        if let made = manifest?.madeWith, !made.isEmpty { parts.append("made with \(made)") }
        if let abi = manifest?.abi { parts.append("node format v\(abi)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
