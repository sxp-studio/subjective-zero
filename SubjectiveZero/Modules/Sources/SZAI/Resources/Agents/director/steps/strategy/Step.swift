// Which build strategy this run takes. The host passes the requested name through verbatim
// (env > the persisted choice > ""), and the DEFAULT lives here rather than in a manifest
// key — an unknown or empty name is agentic, the strategy the app opens on.
//
// Note `recovery` is reachable from both the build port and the settled re-entry, while
// `procedural` is only wired on the build port: a procedural run's first settle routes
// nowhere and ends the thread, which is how "no retry rounds" is spelled now.
let step = SZBuildRouter("agentic", "procedural", "recovery") {
    ["procedural", "recovery"].contains($0.runVariant) ? $0.runVariant : "agentic"
}
