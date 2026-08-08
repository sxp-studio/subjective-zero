// SPDX-License-Identifier: AGPL-3.0-only
// The build-tool plugin wiring one spec into two targets: applied to SZCore it emits
// SZFactCatalog.generated.swift, applied to SZRuntime it emits SZStepSDKGenerated.swift.
// Both commands read the SAME input (SZCore's AgentFacts/SZFacts.swift), so an edit to the
// spec re-runs both and the catalog and the step SDK can never drift apart.
import Foundation
import PackagePlugin

@main
struct SZFactGenPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let mode: String
        let outputName: String
        switch target.name {
        case "SZCore":
            mode = "catalog"
            outputName = "SZFactCatalog.generated.swift"
        case "SZRuntime":
            mode = "facts-section"
            outputName = "SZStepSDKGenerated.swift"
        default:
            return []   // the plugin is only meaningful on the two targets above
        }

        let spec = try specURL(in: context)
        let tool = try context.tool(named: "SZFactGenTool")
        let output = context.pluginWorkDirectoryURL.appending(path: outputName)
        return [
            .buildCommand(
                displayName: "SZFactGen: \(mode) from SZFacts.swift",
                executable: tool.url,
                arguments: [mode, spec.path, output.path],
                inputFiles: [spec],
                outputFiles: [output]
            )
        ]
    }

    /// The one spec file, found in SZCore's sources so the SZRuntime command reaches the
    /// same bytes the SZCore command read.
    private func specURL(in context: PluginContext) throws -> URL {
        guard let core = context.package.targets.first(where: { $0.name == "SZCore" }) as? SourceModuleTarget else {
            throw SZFactGenPluginError.message("SZFactGen: no SZCore source target in this package")
        }
        guard let spec = core.sourceFiles(withSuffix: "swift").first(where: { $0.url.lastPathComponent == "SZFacts.swift" }) else {
            throw SZFactGenPluginError.message("SZFactGen: SZCore has no SZFacts.swift to generate from")
        }
        return spec.url
    }
}

enum SZFactGenPluginError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}
