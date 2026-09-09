// SPDX-License-Identifier: AGPL-3.0-only
// The gate a downloaded library archive passes before a single file is written to disk.
//
// It reads a `tar -tv` listing, which is why it lives here as pure text in, sentence out: every
// hostile shape is a string in a test rather than a crafted tarball on disk. Refusing at the listing
// is the point. A pass that walked the tree after unpacking would have let the hostile tree exist
// first, and would be reading a tree that may be too deep to walk correctly.
import Foundation

public enum SZArchiveListing {
    public struct Limits: Sendable {
        /// Files an honest library has. The built-in one has about 120.
        public var entries: Int
        /// Everything the archive declares, unpacked. The built-in library is 556 KB.
        public var totalBytes: Int
        /// One file. A node is source text and a small card.
        public var entryBytes: Int
        /// `<node>/<file>` is 2. Four leaves room without letting a tree get silly.
        public var depth: Int
        public var component: Int

        public init(entries: Int = 5_000, totalBytes: Int = 64 << 20,
                    entryBytes: Int = 4 << 20, depth: Int = 4, component: Int = 255) {
            self.entries = entries
            self.totalBytes = totalBytes
            self.entryBytes = entryBytes
            self.depth = depth
            self.component = component
        }
    }

    /// Why this archive must not be unpacked, in a sentence, or nil when it is fine.
    ///
    /// `lines` is `tar -tv` output. The one refusal that is not about safety is the last: an archive
    /// must wrap everything in exactly one folder, both because that is what every forge produces and
    /// because it is what makes stripping that folder on extract safe.
    public static func refusal(lines: [String], limits: Limits = Limits()) -> String? {
        var entries = 0
        var total = 0
        var roots: Set<String> = []

        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            guard let entry = Entry(listing: text) else { continue }
            entries += 1
            if entries > limits.entries { return tooBig }

            // Only plain files and folders. A symlink or a hard link can point anywhere, including
            // at the user's own files, and nothing a library needs is either.
            guard entry.kind == "-" || entry.kind == "d" else {
                return "That library contains something other than files and folders, so nothing was added."
            }
            guard entry.size <= limits.entryBytes else { return tooBig }
            total += entry.size
            guard total <= limits.totalBytes else { return tooBig }

            let path = entry.path
            guard !path.hasPrefix("/") else { return unsafePath }
            let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.isEmpty else { continue }
            guard components.count <= limits.depth + 1 else { return unsafePath }
            for component in components {
                guard component != "..", component != ".",
                      component.utf8.count <= limits.component,
                      !component.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
                      component == component.trimmingCharacters(in: .whitespaces)
                else { return unsafePath }
            }
            roots.insert(components[0])
        }

        guard entries > 0 else { return "That link didn't give back a library archive." }
        guard roots.count == 1 else {
            return "That library isn't packed the way libraries are, so nothing was added."
        }
        return nil
    }

    private static let tooBig = "That library is too big to add."
    private static let unsafePath = "That library couldn't be unpacked safely, so nothing was added."

    /// One `tar -tv` line: mode, links, owner, group, size, a three-part date, then the path.
    ///
    /// The path is taken by field position, not by searching for a separator: a name may contain
    /// spaces, and a size like "2024" is indistinguishable from a year if you go looking for one.
    /// A line we cannot read is skipped rather than trusted, since the archive is refused on the
    /// ones we can read.
    private struct Entry {
        var kind: Character
        var size: Int
        var path: String

        init?(listing: String) {
            guard let kind = listing.first else { return nil }
            let fields = Self.fields(of: listing)
            guard fields.count >= 6 else { return nil }
            // The size is the last number among the fields between the mode and the date: BSD tar
            // prints links, owner and group, GNU prints owner/group as one.
            guard let sizeIndex = (1..<min(5, fields.count)).last(where: { Int(fields[$0].text) != nil }),
                  let size = Int(fields[sizeIndex].text),
                  // month, day, time-or-year, then everything left is the path
                  fields.count > sizeIndex + 3
            else { return nil }

            var path = String(listing[fields[sizeIndex + 3].end...]).dropFirst()
            // A link listing carries " -> target"; links are refused above, but the arrow must not
            // become part of a path we then measure.
            if let arrow = path.range(of: " -> ") { path = path[..<arrow.lowerBound] }
            guard !path.isEmpty else { return nil }
            self.kind = kind
            self.size = size
            self.path = String(path)
        }

        /// Each whitespace-separated field with where it ends, so the path can be cut by position.
        private static func fields(of line: String) -> [(text: String, end: String.Index)] {
            var out: [(String, String.Index)] = []
            var index = line.startIndex
            while index < line.endIndex {
                while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
                guard index < line.endIndex else { break }
                let start = index
                while index < line.endIndex, line[index] != " " { index = line.index(after: index) }
                out.append((String(line[start..<index]), index))
            }
            return out
        }
    }
}
