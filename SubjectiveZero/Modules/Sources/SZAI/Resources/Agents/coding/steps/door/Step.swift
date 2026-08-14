// The coding agent's whole decision surface. Assigned work forks on the attempt — a retry
// continues the node's own session, re-grounded on its blocker; anything else is
// conversation, forked on whether this scope already knows us.
let step = SZStep(outcomes: ["implement", "continue", "chat", "chat-resumed"]) { ctx in
    if let job = ctx.assignment { return job.attempt > 1 ? "continue" : "implement" }
    return ctx.resuming ? "chat-resumed" : "chat"
}
