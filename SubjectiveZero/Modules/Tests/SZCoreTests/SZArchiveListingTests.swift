// SPDX-License-Identifier: AGPL-3.0-only
// The gate a downloaded library passes before anything is written. Every hostile shape is a listing
// line here rather than a crafted tarball on disk, which is the reason the check reads text.
import Testing
@testable import SZCore

@Suite("Archive listing")
struct SZArchiveListingTests {
    /// A listing in the shape `tar -tv` prints.
    private func line(_ mode: String, _ size: Int, _ path: String) -> String {
        "\(mode) 0 clem staff \(size) 9 Sep 10:00 \(path)"
    }

    private var honest: [String] {
        [line("drwxr-xr-x", 0, "their-nodes-a1b2c3/"),
         line("-rw-r--r--", 120, "their-nodes-a1b2c3/library.json"),
         line("drwxr-xr-x", 0, "their-nodes-a1b2c3/gaussian-blur/"),
         line("-rw-r--r--", 900, "their-nodes-a1b2c3/gaussian-blur/node-contract.json"),
         line("-rw-r--r--", 4_000, "their-nodes-a1b2c3/gaussian-blur/Node.swift")]
    }

    @Test func anOrdinaryLibraryPasses() {
        #expect(SZArchiveListing.refusal(lines: honest) == nil)
    }

    /// Verbatim `tar -tvf` output from BSD tar on macOS, including a name with a space in it and a
    /// symlink, so the parser is pinned against the real format rather than only against the shape
    /// the other tests assume.
    @Test func realTarOutputIsReadTheSameWay() {
        let real = [
            "drwxr-xr-x  0 clem   wheel       0 Sep  9 13:31 their-nodes-a1b2c3/",
            "drwxr-xr-x  0 clem   wheel       0 Sep  9 13:31 their-nodes-a1b2c3/gaussian blur/",
            "-rw-r--r--  0 clem   wheel      41 Sep  9 13:31 their-nodes-a1b2c3/library.json",
            "-rw-r--r--  0 clem   wheel       3 Sep  9 13:31 their-nodes-a1b2c3/gaussian blur/node-contract.json",
        ]
        // A space inside a name is ordinary, and the path must survive whole or the depth and the
        // root-folder count are both measured against the wrong string.
        #expect(SZArchiveListing.refusal(lines: real) == nil)

        let withSymlink = real + [
            "lrwxr-xr-x  0 clem   wheel       0 Sep  9 13:31 their-nodes-a1b2c3/sneaky -> /etc/passwd",
        ]
        #expect(SZArchiveListing.refusal(lines: withSymlink)?.contains("other than files and folders") == true)

        // A file whose size reads like a year must not be mistaken for the date.
        let yearSized = ["-rw-r--r--  0 clem   wheel    2024 Sep  9 13:31 their-nodes-a1b2c3/Node.swift"]
        #expect(SZArchiveListing.refusal(lines: yearSized) == nil)
    }

    @Test func nothingButFilesAndFoldersIsAllowedThrough() {
        // A symlink or a hard link can name anything on the user's disk, and no library needs either.
        let link = honest + [line("lrwxr-xr-x", 0, "their-nodes-a1b2c3/escape -> /Users/clem/.ssh/id_ed25519")]
        #expect(SZArchiveListing.refusal(lines: link)?.contains("other than files and folders") == true)
        let hard = honest + [line("hrw-r--r--", 10, "their-nodes-a1b2c3/hard")]
        #expect(SZArchiveListing.refusal(lines: hard) != nil)
    }

    @Test func aPathThatClimbsOutIsRefused() {
        let unsafe = "That library couldn't be unpacked safely, so nothing was added."
        #expect(SZArchiveListing.refusal(lines: honest + [line("-rw-r--r--", 10, "../outside")]) == unsafe)
        #expect(SZArchiveListing.refusal(lines: honest + [line("-rw-r--r--", 10, "their-nodes-a1b2c3/../../outside")]) == unsafe)
        #expect(SZArchiveListing.refusal(lines: honest + [line("-rw-r--r--", 10, "/etc/passwd")]) == unsafe)
        // A name that is only whitespace-padded, or carries a control character, is not a real name.
        #expect(SZArchiveListing.refusal(lines: honest + [line("-rw-r--r--", 10, "their-nodes-a1b2c3/ sneaky")]) == unsafe)
    }

    @Test func sizeAndCountAreBounded() {
        let big = "That library is too big to add."
        #expect(SZArchiveListing.refusal(lines: honest + [line("-rw-r--r--", 9 << 20, "their-nodes-a1b2c3/huge.bin")]) == big)

        // Many small entries add up to the same refusal as one enormous one.
        let many = (0..<40).map { line("-rw-r--r--", 3 << 20, "their-nodes-a1b2c3/n\($0)/Node.swift") }
        #expect(SZArchiveListing.refusal(lines: honest + many) == big)

        let crowd = (0..<6_000).map { line("-rw-r--r--", 1, "their-nodes-a1b2c3/n\($0)") }
        #expect(SZArchiveListing.refusal(lines: crowd) == big)
    }

    @Test func aTreeMustNotBeSilly() {
        let deep = honest + [line("-rw-r--r--", 10, "their-nodes-a1b2c3/a/b/c/d/e/f/deep")]
        #expect(SZArchiveListing.refusal(lines: deep) != nil)
    }

    @Test func exactlyOneWrappingFolderIsWhatMakesStrippingItSafe() {
        // Every forge wraps a repository in one folder. Two roots means stripping one would leave
        // half the archive at the top level, so the whole thing is refused instead.
        let two = honest + [line("-rw-r--r--", 10, "somewhere-else/library.json")]
        #expect(SZArchiveListing.refusal(lines: two)?.contains("isn't packed the way libraries are") == true)
        #expect(SZArchiveListing.refusal(lines: [])?.contains("didn't give back a library archive") == true)
    }
}
