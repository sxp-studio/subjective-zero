// SPDX-License-Identifier: AGPL-3.0-only
// GUI launch options parsed from the process arguments (distinct from SZMain's headless
// `--verify-agent-providers` flag, which claims the process before any window). These shape the cold
// launch inside `SZHost.start()`:
//   --skip-welcome        skip the welcome/home surface and open the initial (last / sample) project
//                         directly — the deterministic entry point for automated tests, which need a
//                         rendered viewport (welcome renders nothing, so agent_view_frame has no frame).
//   --open <path.subz>    open a specific project at launch. A positional `*.subz` path works too.
//                         Specifying a project implies --skip-welcome (the user already has intent).
import Foundation

struct SZLaunchOptions {
    var skipWelcome: Bool
    var projectURL: URL?

    /// Parse the GUI launch options. A specified project auto-skips welcome.
    static func parse(_ arguments: [String] = CommandLine.arguments) -> SZLaunchOptions {
        var projectURL: URL?
        if let i = arguments.firstIndex(of: "--open"), i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") {
            projectURL = URL(fileURLWithPath: arguments[i + 1])
        } else if let path = arguments.dropFirst().first(where: { $0.hasSuffix(".subz") }) {
            projectURL = URL(fileURLWithPath: path)
        }
        // A specified project carries its own intent, so it skips welcome exactly like a Finder open.
        let skipWelcome = arguments.contains("--skip-welcome") || projectURL != nil
        return SZLaunchOptions(skipWelcome: skipWelcome, projectURL: projectURL)
    }
}
