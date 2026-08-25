// The coding agent's whole decision surface. Assigned work forks on the attempt: a retry
// continues the node's own session when there is one to continue, else starts over on its
// blocker. Anything else is the user's prose, and the model judges it: a change request
// takes the edit lane (re-grounded on the node's live files); a question is conversation,
// forked on whether this scope already knows us.
struct Ruling: Codable { let outcome: String }

let step = SZStep(outcomes: ["implement", "continue", "edit", "chat", "chat-resumed"]) { ctx in
    if let job = ctx.assignment { return job.attempt > 1 && ctx.resuming ? "continue" : "implement" }
    let ruling = try await ctx.ask("triage", as: Ruling.self)
    if ruling.outcome == "edit" { return "edit" }
    return ctx.resuming ? "chat-resumed" : "chat"
}
