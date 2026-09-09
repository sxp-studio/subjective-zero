// SPDX-License-Identifier: AGPL-3.0-only
// What a library link is allowed to be, how a new library gets a key nothing else has taken, and how
// an update describes itself.
import Testing
@testable import SZCore

@Suite("Added libraries")
struct SZAddedLibraryTests {
    @Test func aLinkIsAnHTTPSRepositoryOrTheOwnerRepoShorthand() {
        #expect(SZLibraryLink.parse("https://github.com/someone/their-nodes")
                == SZLibraryLink(url: "https://github.com/someone/their-nodes", shortName: "someone/their-nodes"))
        // A trailing slash and the .git suffix are the two things people paste by accident.
        #expect(SZLibraryLink.parse("https://github.com/someone/their-nodes.git")?.shortName == "someone/their-nodes")
        #expect(SZLibraryLink.parse("https://github.com/someone/their-nodes/")?.shortName == "someone/their-nodes")
        // The shorthand means GitHub, because that is the only place it means anything.
        #expect(SZLibraryLink.parse("someone/their-nodes")?.url == "https://github.com/someone/their-nodes")
        // Any other host is fine: a library is a repository, not a GitHub account.
        #expect(SZLibraryLink.parse("https://gitlab.com/team/nodes")?.shortName == "team/nodes")
    }

    @Test func aLinkIsRefusedWhenItIsNotOne() {
        #expect(SZLibraryLink.parse("") == nil)
        #expect(SZLibraryLink.parse("   ") == nil)
        // Plain http and ssh are out: one is not private, the other would need the user's key.
        #expect(SZLibraryLink.parse("http://github.com/someone/nodes") == nil)
        #expect(SZLibraryLink.parse("git@github.com:someone/nodes") == nil)
        // A local path is the folder case, not a link.
        #expect(SZLibraryLink.parse("/Users/someone/nodes") == nil)
        // Traversal never survives parsing, since the last segment becomes a folder name.
        #expect(SZLibraryLink.parse("https://github.com/someone/..") == nil)
        #expect(SZLibraryLink.parse("../../etc") == nil)
    }

    @Test func aKeyNeverShadowsALibraryThatExists() {
        let taken: Set<String> = ["builtin", "mine"]
        #expect(SZLibraryKey.make(from: "Their Nodes", taken: taken) == "their-nodes")
        // The two built-in ids are always taken, so nobody can add a library that hides them.
        #expect(SZLibraryKey.make(from: "Built in", taken: taken) == "built-in")
        #expect(SZLibraryKey.make(from: "mine", taken: taken) == "mine-2")
        #expect(SZLibraryKey.make(from: "Their Nodes", taken: taken.union(["their-nodes"])) == "their-nodes-2")
        #expect(SZLibraryKey.make(from: "Their Nodes", taken: taken.union(["their-nodes", "their-nodes-2"]))
                == "their-nodes-3")
    }

    @Test func versionsCompareByFieldNotByText() {
        // The reason a text compare will not do: "0.10.0" is newer than "0.9.0" but sorts before it.
        #expect(SZAppVersionOrder.atLeast("0.10.0", "0.9.0"))
        #expect(!SZAppVersionOrder.atLeast("0.9.0", "0.10.0"))
        #expect(SZAppVersionOrder.atLeast("0.4.0", "0.4.0"))
        #expect(SZAppVersionOrder.atLeast("1.0", "0.9.9"))
        #expect(SZAppVersionOrder.atLeast("0.4", "0.4.0"))          // missing fields are zero
        #expect(SZAppVersionOrder.atLeast("0.5.0-beta.2", "0.5.0")) // a pre-release suffix is ignored
        #expect(SZAppVersionOrder.atLeast("nonsense", "0.0.0"))     // unparseable never blocks anything
    }

    @Test func onlyMinAppVersionRefusesALibrary() {
        let plain = SZLibraryManifest(name: "Their Nodes")
        #expect(plain.refusal(appVersion: "0.4.0") == nil)

        let future = SZLibraryManifest(name: "Their Nodes", minAppVersion: "0.9.0")
        let refusal = try? #require(future.refusal(appVersion: "0.4.0"))
        #expect(refusal?.contains("0.9.0") == true && refusal?.contains("0.4.0") == true)
        #expect(future.refusal(appVersion: "0.9.0") == nil)
        #expect(future.refusal(appVersion: "1.0.0") == nil)
        // A dev build has no version to be judged against, so it is never told it is too old.
        #expect(future.refusal(appVersion: "dev") == nil)
        // madeWith and abi are advisory: neither ever refuses.
        #expect(SZLibraryManifest(name: "N", madeWith: "9.9.9", abi: 99).refusal(appVersion: "0.4.0") == nil)
    }

    @Test func provenanceNamesOnlyWhatTheAuthorFilledIn() {
        #expect(SZAddedLibrary(key: "k", name: "N", kind: .folder, origin: "/p").provenance == nil)
        let full = SZAddedLibrary(key: "k", name: "N", kind: .folder, origin: "/p",
                                  manifest: SZLibraryManifest(name: "N", author: "Someone",
                                                              license: "MIT", madeWith: "0.4.0", abi: 9))
        #expect(full.provenance == "by Someone · MIT · made with 0.4.0 · node format v9")
        // The row says a version, never a commit id: people do not read those.
        #expect(full.versionNote == nil)
        let versioned = SZAddedLibrary(key: "k", name: "N", kind: .link, origin: "https://example.com/a/b",
                                       manifest: SZLibraryManifest(name: "N", version: "1.2.0"))
        #expect(versioned.versionNote == "Version 1.2.0")
    }

    @Test func aLibraryVersionIsExactlyThreeNumbersOrNothing() {
        // Stricter than the app version on purpose: a library version we cannot read must fall back
        // to comparing files, not guess an order and offer the wrong update.
        #expect(SZLibraryVersion.parse("1.2.3") != nil)
        #expect(SZLibraryVersion.parse("v1.2.3") == nil)
        #expect(SZLibraryVersion.parse("1.2") == nil)
        #expect(SZLibraryVersion.parse("1.2.3-rc.1") == nil)
        #expect(SZLibraryVersion.parse("2026-09-09") == nil)
        #expect(SZLibraryVersion.parse(nil) == nil)

        #expect(SZLibraryVersion.isNewer("1.3.0", than: "1.2.9"))
        #expect(SZLibraryVersion.isNewer("0.10.0", than: "0.9.9"))     // by field, not by text
        #expect(!SZLibraryVersion.isNewer("1.2.0", than: "1.2.0"))
        #expect(!SZLibraryVersion.isNewer("1.1.0", than: "1.2.0"))
        #expect(!SZLibraryVersion.isNewer("1.3.0", than: nil))          // unreadable: never an update
        #expect(!SZLibraryVersion.isNewer("v2.0.0", than: "1.0.0"))
    }

    @Test func aLinkKnowsWhereToDownloadItsArchiveFrom() {
        func archive(_ text: String) -> String? {
            SZLibraryLink.parse(text)?.archiveURL?.absoluteString
        }
        #expect(archive("https://github.com/someone/their-nodes")
                == "https://github.com/someone/their-nodes/archive/HEAD.tar.gz")
        #expect(archive("someone/their-nodes")
                == "https://github.com/someone/their-nodes/archive/HEAD.tar.gz")
        #expect(archive("https://codeberg.org/someone/their-nodes")
                == "https://codeberg.org/someone/their-nodes/archive/HEAD.tar.gz")
        // GitLab nests its archives, and names the file after the repository.
        #expect(archive("https://gitlab.com/team/nodes")
                == "https://gitlab.com/team/nodes/-/archive/HEAD/nodes.tar.gz")
        // A link that already names an archive is taken as it is.
        #expect(archive("https://example.com/downloads/nodes.tar.gz")
                == "https://example.com/downloads/nodes.tar.gz")
    }

    @Test func anUpdateSaysOnlyWhatChanged() {
        #expect(SZLibraryUpdate(note: "", offered: false).isEmpty)
        #expect(SZLibraryUpdate(note: "", offered: false).summary == "No node changed")
        #expect(SZLibraryUpdate(note: "", offered: true, added: ["x"]).summary == "1 node added")
        #expect(SZLibraryUpdate(note: "", offered: true, added: ["x", "y"], changed: ["z"], removed: ["w"]).summary
                == "2 nodes added, 1 changed, 1 removed")
    }
}
