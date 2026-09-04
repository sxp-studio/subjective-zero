// SPDX-License-Identifier: AGPL-3.0-only
// A new project is asked where it runs. The New Project sheet is the one door: the menu, the
// welcome's New and a cold launch with nothing to reopen all present it, and Create is what
// writes the target into the bundle.
import Testing
import Foundation
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostNewProjectTargetTests {

    /// A host on the welcome screen with nothing loaded, as a cold launch routed there leaves it.
    private static func hostOnEmptyHome() -> SZHost {
        let host = SZHost()
        host.welcomePresented = true
        host.loadedProjectURL = nil
        // A unit test is not a first run: never start the provider sheet's health polling.
        host.providerSetupAutoPresented = true
        return host
    }

    /// The bundle a fresh project writes for the given target, read back as text. The untitled home
    /// has no override, so the `Projects/<uuid>/` wrapper is removed afterwards.
    private static func freshProjectJSON(target: SZProjectTarget) throws -> (String, SZProject) {
        let url = try SZHost().makeFreshUntitledProject(target: target)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let json = try String(contentsOf: url.appending(path: "project.json"), encoding: .utf8)
        return (json, try SZProjectIO.load(from: url))
    }

    @Test func aWebProjectWritesItsTargetAndWebBlock() throws {
        let (json, project) = try Self.freshProjectJSON(target: .web)
        #expect(json.contains("\"target\" : \"web\""))
        #expect(json.contains("\"web\" : {"))
        #expect(project.target == .web)
        #expect(project.web != nil)
    }

    @Test func aNativeProjectWritesItsTargetAndNoWebBlock() throws {
        let (json, project) = try Self.freshProjectJSON(target: .native)
        #expect(json.contains("\"target\" : \"native\""))
        #expect(!json.contains("\"web\""))
        #expect(project.target == .native)
        #expect(project.web == nil)
    }

    /// Continuing from the welcome with nothing loaded asks where the project runs, and the welcome
    /// stays up behind the sheet so Cancel has somewhere to land.
    @Test func continuingFromAnEmptyWelcomePresentsTheSheet() {
        let host = Self.hostOnEmptyHome()

        host.continueFromWelcome()

        #expect(host.newProjectPresented)
        #expect(!host.newProjectRequired)
        #expect(host.welcomePresented)

        host.cancelNewProject()
        #expect(!host.newProjectPresented)
        #expect(host.welcomePresented, "Cancel leaves the welcome up")
    }

    /// Create drops the sheet before anything else happens, and remembers the pick.
    @Test func createClearsTheSheetSynchronouslyAndRemembersTheTarget() {
        // Create persists the pick to the real app-state.json: put it back the way it was.
        let saved = SZAppStateIO.load()
        defer {
            if let saved { try? SZAppStateIO.save(saved) }
            else { try? FileManager.default.removeItem(at: SZAppStateIO.defaultURL) }
        }
        let host = Self.hostOnEmptyHome()
        host.presentNewProject()
        #expect(host.newProjectPresented)
        // Refuse the switch itself: this test is about the flags, not about writing a bundle.
        host.openingProject = "Something"

        host.createNewProject(target: .web)

        #expect(!host.newProjectPresented)
        #expect(host.lastProjectTarget == .web)
    }

    /// The two sheets never stack: while the New Project sheet is up, the first-run provider sheet
    /// waits, and keeps its once-per-launch chance.
    @Test func providerSetupWaitsWhileTheNewProjectSheetIsUp() {
        let host = SZHost()
        host.defaultProviderID = nil
        host.providerSetupAutoPresented = false
        host.welcomePresented = false
        host.newProjectPresented = true

        host.autoPresentProviderSetupIfNeeded()

        #expect(!host.providerSetupPresented)
        #expect(!host.providerSetupAutoPresented, "the once-per-launch chance is not spent")
    }
}
