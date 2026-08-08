// swift-tools-version: 6.0

import PackageDescription

// The four supporting modules for SubZ, as library targets in one local
// package. Dependency rule (docs/ARCHITECTURE.md): everything depends on SZCore;
// siblings (SZAI/SZRuntime/SZUI) do not depend on each other. SZApp (the host app
// target) lives outside this package and links these products.
let package = Package(
    name: "Modules",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SZCore", targets: ["SZCore"]),
        .library(name: "SZAI", targets: ["SZAI"]),
        .library(name: "SZRuntime", targets: ["SZRuntime"]),
        .library(name: "SZUI", targets: ["SZUI"])
    ],
    targets: [
        .target(name: "SZCore", plugins: ["SZFactGen"]),
        .target(
            name: "SZAI",
            dependencies: ["SZCore"],
            resources: [
                .copy("Resources/Agents"),     // the shipped agent packs (tests also read them via #filePath)
                .copy("Resources/Prompts"),    // agent prompts as bundled .md.mustache files
                .copy("Resources/Docs"),       // agent-fetchable reference docs (agent_docs_*)
                .copy("Resources/Extensions"), // staged CLI extensions (pi's MCP bridge)
            ]
        ),
        .target(name: "SZRuntime", dependencies: ["SZCore"], plugins: ["SZFactGen"]),
        .target(name: "SZUI", dependencies: ["SZCore"]),
        // SZFactGen: the spec (SZCore/AgentFacts/SZFacts.swift) compiles twice — normally
        // into SZCore, and through this build-tool plugin into two generated artifacts
        // (the fact catalog for SZCore, the verbatim facts section for SZRuntime's step
        // SDK). The parsing core is a library so the tests can prove the grammar and the
        // determinism directly.
        .target(name: "SZFactGenCore", path: "Plugins/SZFactGenCore"),
        .executableTarget(
            name: "SZFactGenTool",
            dependencies: ["SZFactGenCore"],
            path: "Plugins/SZFactGenTool"
        ),
        .plugin(
            name: "SZFactGen",
            capability: .buildTool(),
            dependencies: ["SZFactGenTool"],
            path: "Plugins/SZFactGen"
        ),
        .testTarget(name: "SZCoreTests", dependencies: ["SZCore"]),
        .testTarget(name: "SZFactGenTests", dependencies: ["SZFactGenCore", "SZCore", "SZRuntime"]),
        .testTarget(name: "SZAITests", dependencies: ["SZAI"]),
        // SZRuntimeTests also links SZAI (tests only — the library siblings stay
        // independent): the step-tier integration proofs drive a REAL compiled step's
        // `askModel` through the real SZAI query service as its ask runner.
        .testTarget(name: "SZRuntimeTests", dependencies: ["SZRuntime", "SZAI"]),
        .testTarget(name: "SZUITests", dependencies: ["SZUI"])
    ],
    swiftLanguageModes: [.v6]
)
