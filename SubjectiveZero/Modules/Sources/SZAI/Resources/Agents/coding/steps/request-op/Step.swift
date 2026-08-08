// Which graph operation does this request carry? The `op` fact IS the answer — the graph
// draws one edge per operation to the matching seed brief.
let step = SZRequestRouter("split", "merge") { $0.op }
