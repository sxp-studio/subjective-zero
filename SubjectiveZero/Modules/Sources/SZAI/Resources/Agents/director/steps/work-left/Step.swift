// Does the settled run still hold unimplemented work? "yes" routes to the reconcile turn;
// an unwired "no" ends the traversal — the run is done.
let step = SZBuildCondition { $0.hasWorkLeft }
