// SPDX-License-Identifier: AGPL-3.0-only
// The process entry point. SwiftUI's SZApp.main() runs only when no CLI flag claims the process:
// `--verify-agent-providers [--probe] [--json]` prints the provider health report (JSON is the
// only format; --json is accepted for the APP_SETUP.md contract's readability) and exits before
// any window / Metal / runtime spin-up — setup agents run the bare binary
// (SubjectiveZero.app/Contents/MacOS/SubjectiveZero --verify-agent-providers --json). Exit codes: 0 = ≥1 provider
// ready · 1 = none ready · 2 = internal verifier error.
import Foundation
import SZAI
import SZCore
import SZRuntime

@main
enum SZMain {
    static func main() {
        // Line-buffer stdout so [SZHost]/[SZ*Orchestrator] logs flush per line when run from a
        // terminal (block-buffered logs are lost when the process is killed mid-run) — and so the
        // verifier's JSON lands even through a pipe.
        setvbuf(stdout, nil, _IOLBF, 0)

        let arguments = CommandLine.arguments
        if arguments.contains("--verify-agent-providers") {
            runProviderVerifier(probe: arguments.contains("--probe"))
        }
        // Release-time flags (SZPrebuiltSteps.swift): the shipped agent steps, prebuilt into the
        // bundle by the release script and verified after signing.
        if let dir = value(after: "--prebuild-steps", in: arguments) {
            SZPrebuiltSteps.prebuild(into: URL(fileURLWithPath: dir))
        }
        if let dir = value(after: "--verify-prebuilt-steps", in: arguments) {
            SZPrebuiltSteps.verify(in: URL(fileURLWithPath: dir))
        }
        SZApp.main()
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    /// Bridge the async verifier onto the not-yet-running main thread: no runloop exists this
    /// early, so a semaphore blocks main while the health subprocesses run on the cooperative
    /// pool — nothing here ever hops back to main, so the block can't deadlock.
    private static func runProviderVerifier(probe: Bool) -> Never {
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let appBuild = info?["CFBundleVersion"] as? String ?? "dev"
        let defaultProviderID = SZAppStateIO.load()?.defaultProviderID

        // The semaphore's signal/wait pair is the happens-before for this handoff.
        nonisolated(unsafe) var report: SZProviderVerificationReport?
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            report = await SZProviderVerifier.run(defaultProviderID: defaultProviderID,
                                                  appVersion: appVersion, appBuild: appBuild,
                                                  probe: probe)
            done.signal()
        }
        done.wait()

        guard let report else {
            FileHandle.standardError.write(Data("verifier produced no report\n".utf8))
            exit(2)
        }
        print(SZProviderVerifier.json(report))
        exit(report.ok ? 0 : 1)
    }
}
