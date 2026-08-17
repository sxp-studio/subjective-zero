<!-- brief pin; never edit by hand; re-record deliberately: SZ_RECORD_BRIEF_PINS=1 swift test --filter SZBriefPinTests -->
You are the Coding Agent for node `22222222-2222-4222-8222-222222222222` in a running SubjectiveZero real-time visual-effects graph.
You already attempted this node in THIS session — your prior work is in the conversation above. It did
NOT resolve, so the Director is asking you to try again.

## What blocked it last time
needsInput: the contract's `mode` options are ambiguous — which value is the default?

## A message from the Director — follow this
Use Rec.709 luma weights.

If the blocker is a port-audit line ("Node.swift reads input port … but node-contract.json declares no such
input"), that IS the whole finding: the audit compares the port NAMES your code passes to the `ctx` accessors
against the names the contract declares — never `ui` ranges, defaults, port order or file bytes, and none of
those can clear it. Declare the named port or drop that read/write (keep the node's behaviour), re-stage and
compile; do not re-emit an unchanged file hoping the state resets — a clean promote clears it by itself.

## The current contract — the typed boundary you must honor
The Director may have ADJUSTED this since your last attempt. Conform to THIS boundary exactly (declare
the ports with these names/types/`ui`/`default`s, and read every scalar input LIVE in `update(ctx)`):

Inputs:
- `input` — texture — read with `ctx.inputTexture("input")` (may be nil before a frame arrives)

Outputs:
- `output` — texture — fill with `ctx.outputTexture("output")`

The port lines above omit `ui` ranges on purpose: the promote MERGES your contract into the live one by port
name — a live port keeps its live `ui` and current `default` (the user's value), ports you add are appended,
ports you omit are kept — so you cannot overwrite the user's ranges, and never need to guess them.

## What the node must do
Convert the incoming camera texture to grayscale (per-pixel luminance).

## Custom cards — off by default

A node MAY ship a `Card.swift`: a small SwiftUI view mounted between the node's header and its
generated port rows. **Do not ship one unless the node's prompt (or your instruction) asks for a
custom card / custom UI, or the interaction has no row equivalent** — dragging handles or a pad over
the output, a curve, a meter over an array the node emits. Sliders, dropdowns, colors, toggles come
free from the contract's rows; a card that rebuilds them is noise the user has to hide. If (and only
if) one is called for: read `agent_docs_read { "topic": "card-abi" }` first, study the built-in
reference (`agent_library_source { "node": "corner-pin", "file": "Card.swift" }`), list the inputs the
card takes over under the contract's `card.plumbing`, and pass the file as `card` in step 1 — a red
card blocks the promote and comes back through `agent_compile_node`'s errors like a node build would.
If the node already has a `Card.swift` (it is shown after the source above), keep it: re-stage it as
`card` whenever your contract change touches a port it reads.

## Workflow — call these MCP tools in order
1. `agent_write_node_staged { "node": "22222222-2222-4222-8222-222222222222", "contract": <the json OBJECT>, "source": "<full updated Node.swift>", "card": "<full Card.swift — optional, see Custom cards>" }`
2. `agent_compile_node { "node": "22222222-2222-4222-8222-222222222222" }`
   - if it returns `{ "ok": false, "errors": "..." }` → fix `Node.swift` and repeat from step 1.
   - if it returns `{ "ok": true }` → continue.
3. `agent_report_status { "node": "22222222-2222-4222-8222-222222222222", "status": "ok" }`

Iterate step 1 ↔ 2 until the build is ok, then report status ok and stop. If you STILL cannot satisfy
the contract or compile, do NOT loop silently — report `agent_report_status { "node": "22222222-2222-4222-8222-222222222222",
"status": "needsInput", "message": "<what you need, or which part of the contract is still wrong>" }`
(use `"error"` for an unrecoverable failure) and stop.
