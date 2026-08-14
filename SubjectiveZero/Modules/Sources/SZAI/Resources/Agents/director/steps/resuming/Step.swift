// Does this chat turn resume an existing session? "yes" re-projects only the live graph
// over the session's memory; "no" opens a cold turn that re-projects the whole world.
let step = SZMessageCondition { $0.resuming }
