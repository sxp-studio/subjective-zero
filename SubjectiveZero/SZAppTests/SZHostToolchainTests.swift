// SPDX-License-Identifier: AGPL-3.0-only
// Apple's developer tools as a requirement of the Mac target: the requirement the sheets render,
// the guards that refuse a build on a Mac project without the tools (and let a browser project
// through), the retarget belt, the funnel event, and the shipped steps the release prebuilds.
import Foundation
import SZAI
import SZCore
import SZRuntime
import SZUI
import Testing
@testable import SubjectiveZero

@MainActor
struct SZHostToolchainTests {

    /// A host in the workspace with a project of the given target set on the store and nothing else
    /// running: no MCP bus, no provider polling.
    private static func host(target: SZProjectTarget, tools: SZToolchainAvailability) -> SZHost {
        let host = SZHost()
        host.providerSetupAutoPresented = true
        host.welcomePresented = false
        host.toolchainAvailability = tools
        host.store.setProject(SZProject(name: "t", target: target))
        return host
    }

    @Test func theRequirementStandsOnlyWhileTheToolsAreMissing() {
        let missing = Self.host(target: .native, tools: .missing)
        let requirement = missing.nativeRequirement
        #expect(requirement?.title == "Needs Apple's developer tools")
        #expect(requirement?.command == "xcode-select --install")
        #expect(missing.targetPlatformRows.first { $0.id == .native }?.requirement != nil)
        #expect(missing.targetPlatformRows.first { $0.id == .web }?.requirement == nil)

        let ready = Self.host(target: .native, tools: .ready(developerDir: "/Library/Developer/CommandLineTools"))
        #expect(ready.nativeRequirement == nil)
        #expect(ready.targetPlatformRows.allSatisfy { $0.requirement == nil })
    }

    @Test func aMacProjectWithoutToolsIsRefusedAndPointedAtTargetPlatform() {
        let host = Self.host(target: .native, tools: .missing)
        let note = host.toolchainRefusal()
        defer { host.skipProviderSetup() }
        #expect(note == SZHost.toolsMissingMessage)
        #expect(note?.contains("—") == false)
        #expect(host.providerSetupPresented)
        #expect(host.setupSection == .target)
    }

    @Test func aBrowserProjectOrAMacWithToolsIsNotRefused() {
        #expect(Self.host(target: .web, tools: .missing).toolchainRefusal() == nil)
        #expect(Self.host(target: .native, tools: .ready(developerDir: "/x")).toolchainRefusal() == nil)
    }

    @Test func switchingToThisMacWithoutToolsIsRefused() async throws {
        let host = Self.host(target: .web, tools: .missing)
        let url = try host.makeFreshUntitledProject(target: .web)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        host.loadedProjectURL = url
        defer { host.skipProviderSetup() }

        await host.setProjectTarget(.native)

        #expect(host.store.project?.target == .web)
        #expect(host.status.contains("developer tools"))
        #expect(host.providerSetupPresented)
    }

    @Test func nodeIsOnlyAskedForByNpmInstalls() {
        #expect(!SZHost.installNeedsNode("curl -fsSL https://claude.ai/install.sh | bash"))
    }

    @Test func theShippedStepsAreTheOnesTheReleasePrebuilds() throws {
        let root = try #require(SZAgentPackLoader.bundledRoot)
        let keys = SZPrebuiltSteps.stepSources(under: root).map { "\($0.key.agent)/\($0.key.step)" }
        #expect(keys == ["coding/door", "debug/door", "director/door", "director/work-left"])
    }
}
