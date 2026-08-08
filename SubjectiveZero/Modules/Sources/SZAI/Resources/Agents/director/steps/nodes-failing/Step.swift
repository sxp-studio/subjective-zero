// Is the fleet failing rather than progressing — a node stuck on a terminal status, or
// compile errors left by the last build? "yes" routes to the recovery turn; an unwired
// "no" ends the traversal — a healthy fleet needs no rescue.
let step = SZBuildCondition { $0.fleetIsFailing }
