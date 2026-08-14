// SPDX-License-Identifier: AGPL-3.0-only
// The build-tool plugin wiring the spec into the step runtime: applied to SZRuntime it
// emits SZStepSDKGenerated.swift — the verbatim spec region of SZCore's
// AgentFacts/SZFacts.swift plus its conveniences, which the step SDK splices into every
// step build so both sides of the ABI compile the same source.
import Foundation
import PackagePlugin

@main
struct SZFactGenPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard target.name == "SZRuntime" else {
            return []   // the plugin is only meaningful on the step runtime
        }
        let spec = try specURL(in: context)
        let tool = try context.tool(named: "SZFactGenTool")
        let output = context.pluginWorkDirectoryURL.appending(path: "SZStepSDKGenerated.swift")
        return [
            .buildCommand(
                displayName: "SZFactGen: facts-section from SZFacts.swift",
                executable: tool.url,
                arguments: ["facts-section", spec.path, output.path],
                inputFiles: [spec],
                outputFiles: [output]
            )
        ]
    }

    /// The one spec file, found in SZCore's sources so the SZRuntime command reaches the
    /// same bytes SZCore itself compiles.
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
