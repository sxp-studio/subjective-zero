// The director's door — where every delivery is decided. A granted build goes straight to work:
// the grant arrives PRE-RULED (the Build press, or a previous turn's own ruling), and re-triaging
// it would spend a token to maybe drop a build. Prose is triaged by the model; `implement`
// requests the build — the run is the reply — `amend` folds words into work already scheduled or
// already building, and everything else is answered in conversation, cold or resumed.
struct Ruling: Codable { let outcome: String }

let step = SZStep(outcomes: ["build", "answer", "answer-resumed", "implement", "amend"]) { ctx in
    if ctx.run != nil { return "build" }
    let ruling = try await ctx.ask("triage", as: Ruling.self)
    // With nothing scheduled and nothing running there is nothing to fold into, so the ruling
    // cannot stand and the ask becomes a fresh one. Here rather than in the prompt because a
    // hallucinated amend would otherwise route to a turn with no work to do. Running work counts:
    // folding into it is what stops a repeat of a live ask from building the same thing twice.
    if ruling.outcome == "amend", !ctx.pendingTasks.isEmpty || !ctx.runningTasks.isEmpty {
        return "amend"
    }
    if ruling.outcome == "implement" || ruling.outcome == "amend" {
        return .outcome("implement", effects: [.requestBuild])
    }
    return ctx.resuming ? "answer-resumed" : "answer"
}
