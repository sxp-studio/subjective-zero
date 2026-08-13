// Does this node chat resume an existing session? "yes" rides the session raw — the user's
// message and nothing else; "no" seeds a cold turn with the node's contract and source.
let step = SZChatCondition { $0.resuming }
