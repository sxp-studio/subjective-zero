// Does the settled run still owe work? "yes" routes to the reconcile turn; an unwired "no"
// ends the traversal — the run is done.
let step = SZStep(outcomes: ["yes", "no"]) { $0.hasWorkLeft ? "yes" : "no" }
