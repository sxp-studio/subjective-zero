// SPDX-License-Identifier: AGPL-3.0-only
// The rule: picking the project already open is not an open at all. It leaves Home and lands back in
// that project, whatever URL flavor it arrives as and whatever the fleet is doing at the time.
//
// It used to dead-end instead: an open panel's `…/A.subz/` and a recents row's `…/A.subz` compared
// unequal, so the no-op was skipped and the open went on to take an instance lock this app already
// holds — reported to the user as "already open in another SubjectiveZero instance".
import Testing
import Foundation
import SZAI
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostReopenLiveProjectTests {

    private static func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sz-reopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A host on a real bundle, sitting on the Home screen with that project still loaded behind it
    /// (what gear ▸ Welcome leaves behind). `loadedProjectURL` is directory-flavored, as a URL that
    /// came from the open panel is.
    private static func hostOnHome(at dir: URL) throws -> (SZHost, URL) {
        let url = dir.appending(path: "A.subz")
        try SZProjectIO.save(SZProject(name: "A"), to: url)
        let host = SZHost()
        host.store.setProject(try SZProjectIO.load(from: url))
        host.loadedProjectURL = URL(fileURLWithPath: url.path, isDirectory: true)
        host.welcomePresented = true
        // Leaving Home is where a first run would meet the provider sheet; a unit test is not that
        // run, and it must not start the sheet's health polling.
        host.providerSetupAutoPresented = true
        return (host, url)
    }

    /// THE regression test: the recents row hands back a plain path string.
    @Test func pickingTheLiveProjectOnHomeReturnsToIt() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (host, url) = try Self.hostOnHome(at: dir)

        host.openProject(at: URL(filePath: url.path))   // the Home recents row, verbatim

        #expect(!host.welcomePresented, "picking the open project takes you back to it")
        #expect(host.loadedProjectURL != nil, "and it is still the loaded project")
        #expect(host.status.contains("already open"))
    }

    /// The same round trip while the fleet is mid-run. Home is reachable during a run, so the way
    /// back has to be too: nothing is torn down by returning to a project already loaded.
    @Test func pickingTheLiveProjectWorksWhileAgentsOwnIt() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (host, url) = try Self.hostOnHome(at: dir)
        let run = SZRunState(taskID: UUID(), claim: SZClaimToken(label: "run"),
                             instruction: "build", ownsGraphOp: false, workSet: [])
        host.activeRuns[run.taskID] = run
        #expect(host.isBusyForProjectSwitch, "a switch is refused, and that is not what this is")

        host.openProject(at: URL(filePath: url.path))

        #expect(!host.welcomePresented)
    }

    /// The guard is about identity, not about being on Home: a DIFFERENT project is a real open, and
    /// must not be swallowed as "already open" (it can't run here — no runtime — but it must not
    /// short-circuit before it gets there).
    @Test func pickingADifferentProjectIsStillARealOpen() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (host, _) = try Self.hostOnHome(at: dir)
        let other = dir.appending(path: "B.subz")
        try SZProjectIO.save(SZProject(name: "B"), to: other)

        #expect(!host.reopenedLiveProject(at: other))
        #expect(host.welcomePresented, "an open that has yet to succeed leaves Home up")
    }

    /// An open in flight is the one thing that does refuse: `loadedProjectURL` still names the
    /// project being left, so answering for it would dismiss Home moments before the other project
    /// lands. Reachable from Finder, which is not disabled the way the menu and the Home list are.
    @Test func aFinderOpenOfTheLiveProjectWaitsWhileAnotherOpenIsInFlight() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (host, url) = try Self.hostOnHome(at: dir)
        host.openingProject = "B"

        host.openProject(at: URL(filePath: url.path))

        #expect(host.welcomePresented, "the open under way decides where we land, not this click")
    }
}
