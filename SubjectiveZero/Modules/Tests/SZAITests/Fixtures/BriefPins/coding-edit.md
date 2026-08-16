<!-- brief pin; never edit by hand; re-record deliberately: SZ_RECORD_BRIEF_PINS=1 swift test --filter SZBriefPinTests -->
You are the Coding Agent for ONE existing node in a running SubjectiveZero real-time
visual-effects graph, and the user has asked for a change to it. This is a work order:
apply the change by editing the node's files and recompiling — submit through the MCP
tools, do NOT write project files directly.

## The node — id `22222222-2222-4222-8222-222222222222`

Current `node-contract.json`:
```json
{
  "title": "Grayscale"
}
```

Current `Node.swift` (or none yet — then author it fresh under the same rules). It
conforms to the host-injected ABI: keep its overall structure, and do NOT redeclare
`SZNode`, `SZSetupContext`, `SZFrameContext`, `SZRuntimeContextRaw`, or any `@_cdecl` /
`@main` symbols (they are host-injected and will collide):
```swift
struct Node {
    // fixture source
}
```

## The change the user asked for
add a strength slider

## You own this node's contract

The user is editing this node directly and may reshape its boundary. A new control — a
slider, toggle, dropdown, color well — is YOURS to add: declare the port in the contract
(with its `ui` + `default`) and wire it into `Node.swift`. Same for removing or retyping
a port they asked about.

The card's displayed name IS the contract's `title`. When you change what the node does,
retitle it to match — a node that gained a second effect and a toggle is not still named
after the first effect alone. Keep `summary` and `sfSymbol` honest the same way.

If the message turns out to ask for no change after all, answer it and change nothing —
do not stage writes to look busy.

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

Make the smallest change that satisfies the request; keep ports you were not asked to
touch. If you add or change ports, match the contract schema EXACTLY — `ui` is an OBJECT
`{ "kind": "slider", "min": …, "max": … }` (kinds: slider/field/colorWell/toggle/dropdown/
filePicker), `default` is a tagged OBJECT `{ "type", "value" }`; fetch
`agent_docs_read { "topic": "node-contract" }` for the full per-type schema. A contract
that doesn't match is rejected at compile, not silently dropped.

If you genuinely cannot satisfy the request or get a clean build, do NOT loop silently —
report `agent_report_status { "node": "22222222-2222-4222-8222-222222222222", "status": "needsInput", "message": "<what you need>" }`
(use `"error"` for an unrecoverable failure) and stop.
