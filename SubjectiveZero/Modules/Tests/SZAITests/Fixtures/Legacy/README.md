# Legacy fixtures (historical — no gate reads these)

These five `.txt` fixtures pinned the RETIRED strategies' dispatch event shape and claude argv
assembly. Their subject was deleted in the orchestration cutover (the graph engine is the only
orchestrator), so they are kept here as a historical record only: no test renders or compares
them, and nothing regenerates them. The living gate is `SZEquivalenceGateTests` over
`../Equivalence/*.md`, which stay byte-pinned and untouched.
