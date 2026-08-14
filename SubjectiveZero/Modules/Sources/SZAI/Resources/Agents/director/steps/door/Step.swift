// The director's door — where every delivery is decided. A granted build goes straight to
// work: the grant arrives PRE-RULED (the Build press, or a previous turn's own ruling), and
// re-triaging it would spend a token to maybe drop a build. Prose is triaged by the model;
// an `implement` ruling requests the build — the run is the reply — and everything else is
// answered in conversation, cold or resumed.
struct Ruling: Codable { let outcome: String }

let step = SZStep(outcomes: ["build", "answer", "answer-resumed", "implement"]) { ctx in
    if ctx.run != nil { return "build" }
    let ruling = try await ctx.ask("triage", as: Ruling.self)
    if ruling.outcome == "implement" {
        return .outcome("implement", effects: [.requestBuild])
    }
    return ctx.resuming ? "answer-resumed" : "answer"
}
