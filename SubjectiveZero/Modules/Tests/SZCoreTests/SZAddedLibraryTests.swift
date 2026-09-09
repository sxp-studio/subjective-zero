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

    @Test func anUpdateSaysOnlyWhatChanged() {
        #expect(SZLibraryUpdate(revision: "a", note: "", added: [], changed: [], removed: []).isEmpty)
        #expect(SZLibraryUpdate(revision: "a", note: "", added: [], changed: [], removed: []).summary
                == "No node changed")
        #expect(SZLibraryUpdate(revision: "a", note: "", added: ["x"], changed: [], removed: []).summary
                == "1 node added")
        #expect(SZLibraryUpdate(revision: "a", note: "", added: ["x", "y"], changed: ["z"], removed: ["w"]).summary
                == "2 nodes added, 1 changed, 1 removed")
    }
}
