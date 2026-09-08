// SPDX-License-Identifier: AGPL-3.0-only
// The toolchain probe: a filesystem answer to "can this Mac compile", over both developer
// directory layouts, with the directory and the file checks injected so no test touches the
// machine's real tools or spawns a process.
import Testing
@testable import SZRuntime

struct SZToolchainAvailabilityTests {

    private func probe(dir: String?, present: Set<String>) -> SZToolchainAvailability {
        SZToolchain.availability(developerDir: { dir }, fileExists: { present.contains($0) })
    }

    @Test func noDeveloperDirectoryIsMissing() {
        #expect(probe(dir: nil, present: []) == .missing)
        #expect(probe(dir: "", present: []) == .missing)
        #expect(probe(dir: "/Library/Developer/CommandLineTools", present: []) == .missing)
    }

    @Test func commandLineToolsLayoutIsReady() {
        let dir = "/Library/Developer/CommandLineTools"
        let present: Set<String> = [dir, "\(dir)/usr/bin/swiftc", "\(dir)/SDKs/MacOSX.sdk"]
        #expect(probe(dir: dir, present: present) == .ready(developerDir: dir))
    }

    @Test func xcodeLayoutIsReady() {
        let dir = "/Applications/Xcode.app/Contents/Developer"
        let present: Set<String> = [dir,
                                    "\(dir)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc",
                                    "\(dir)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"]
        #expect(probe(dir: dir, present: present) == .ready(developerDir: dir))
    }

    @Test func aDirectoryWithoutACompilerOrAnSDKIsMissing() {
        let dir = "/Library/Developer/CommandLineTools"
        #expect(probe(dir: dir, present: [dir, "\(dir)/SDKs/MacOSX.sdk"]) == .missing)
        #expect(probe(dir: dir, present: [dir, "\(dir)/usr/bin/swiftc"]) == .missing)
    }

    @Test func developerDirEnvironmentWinsOverXcodeSelect() {
        #expect(SZToolchain.activeDeveloperDir(environment: ["DEVELOPER_DIR": "/nonexistent"]) == "/nonexistent")
    }

    @Test func theToolsMissingMessageIsPlainWords() {
        let message = SZToolchain.CompileError.sdkNotFound(log: "xcrun: error").description
        #expect(message.hasPrefix("Apple's developer tools are not installed."))
        #expect(!message.contains("—"))
    }
}
