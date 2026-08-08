// Is this delivery a re-attempt on the same work item? `attempt` is 1-based, so anything
// past the first dispatch continues the earlier session, re-grounded on the blocker.
let step = SZItemCondition { $0.attempt > 1 }
