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
        .target(name: "SZCore"),
        .target(
            name: "SZAI",
            dependencies: ["SZCore"],
            resources: [
                .copy("Resources/Prompts"),    // agent prompts as bundled .md.mustache files
                .copy("Resources/Docs"),       // agent-fetchable reference docs (agent_docs_*)
                .copy("Resources/Extensions"), // staged CLI extensions (pi's MCP bridge)
            ]
        ),
        .target(name: "SZRuntime", dependencies: ["SZCore"]),
        .target(name: "SZUI", dependencies: ["SZCore"]),
        .testTarget(name: "SZCoreTests", dependencies: ["SZCore"]),
        .testTarget(name: "SZAITests", dependencies: ["SZAI"]),
        .testTarget(name: "SZRuntimeTests", dependencies: ["SZRuntime"]),
        .testTarget(name: "SZUITests", dependencies: ["SZUI"])
    ],
    swiftLanguageModes: [.v6]
)
