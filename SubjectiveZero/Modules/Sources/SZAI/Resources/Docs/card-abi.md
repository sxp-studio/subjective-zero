# Card ABI — authoring a node's `Card.swift`

A node MAY ship a **custom card**: a `Card.swift` beside its `Node.swift`, compiled at runtime the same
way, whose SwiftUI view is mounted as a REGION of the node card in the editor — between the header
and the generated port rows, exactly where the live preview would sit. Everything else stays
system-generated: the header, the input rows (controls + sockets), the output rows (monitor toggle
+ sockets). Inputs your card takes over are listed as `plumbing` in the contract's `card` block, and
their generated rows step aside while the card shows. Cards are **off by default**: ship one only when
the user asked for custom UI (the node's prompt says so) or the interaction has no row equivalent —
handles or a pad over the output, a curve, a meter/scope over an array the node emits. Never one that
redecorates a slider, dropdown, or color the plain rows already give for free.

Your `Card.swift` is compiled together with a host-owned support file (the card kit) that already
defines the ABI. Do **NOT** redeclare `SZCardState`, `SZCardPort`, `SZCardRoot`, `SZCardHostRaw`,
`SZCardInstance`, or any `@_cdecl` symbols — they are host-injected and will collide.

## The shape your file must define

```swift
import SwiftUI

struct MyCard: View {
    @ObservedObject var state: SZCardState     // the ONE object you talk to
    @State private var drag: Double?           // the hand's value while dragging (see below)

    var body: some View { /* your controls */ }
}

enum SZCardMain { static func make(_ state: SZCardState) -> AnyView { AnyView(MyCard(state: state)) } }
```

That is the whole contract: `SZCardMain.make(_:)` returns your root view. `import SwiftUI` (and
`AppKit` if you embed an `NSViewRepresentable`) is fine; there is no Metal, no file or network access
worth reaching for — a card is UI over the node's ports, nothing else.

## `SZCardState` — what a card can see and do

```swift
final class SZCardState: ObservableObject {           // @Published: re-renders on every host push
    var title: String                                  // the node's title
    var inputs: [SZCardPort]; var outputs: [SZCardPort]
    func input(_ name: String) -> SZCardPort?          // a declared input, by contract name
    func output(_ name: String) -> SZCardPort?
    var connectedInputs: Set<String>                   // inputs driven by a wire — show, don't fight
    var renderSize: CGSize?                            // the graph's render size in pixels
    var bodySize: CGSize?                              // the card body's committed footprint, points
    var backdrop: CGRect?                              // where the host draws the node's live output UNDER
                                                       // the card (card-body points) — nil without one
    func values(_ outputPort: String) -> [Double]      // telemetry: the node's latest float/floatArray
                                                       // OUTPUT values (~30 Hz, lossy, latest-wins)
    func string(_ outputPort: String) -> String?       // telemetry: a string/enum OUTPUT's latest value
    var learn: SZCardLearn?                            // controller nodes only: {armed, seen, key, value01}
                                                       // — the host's binding-learn state, same cadence
    func live(_ port: String, _ value: Double)         // stream a gesture tick — the render follows,
    func live(_ port: String, _ values: [Double])      // nothing persists
    func commit(_ port: String, _ value: Double)       // ONE store write + persist, at gesture end
    func commit(_ port: String, _ values: [Double])
    func call(_ tool: String, argsJSON: String = "{}") // a named HOST VERB for this node (below); no
                                                       // return value — read the outcome from `learn`/state
}
struct SZCardPort {
    let name: String; let type: String                 // contract type: float, float2, float3, float4,
                                                       // colorRGB, colorRGBA, bool, string, enum, texture…
    var defaultDouble: Double?                         // committed value: a scalar (bool as 0/1)
    var defaultDoubles: [Double]                       // committed value as numbers ([x, y] for float2 …)
    var defaultString: String?; var defaultBool: Bool?
    let uiMin: Double?; let uiMax: Double?; let uiStep: Double?   // the contract's `ui` range
}
```

Writes are by PORT NAME and go through the same funnel the plain rows use: the host clamps to the
contract's `ui` range, snaps to `step`, pushes the runtime live, writes the store, persists. Only
numeric ports (float, vectors, colors, bool) can be written from a card — an enum/string input stays on
the plain rows (the user flips with right-click → "Show Rows").

**Host verbs** (`call`) exist only for controller nodes — a contract with a `mappings` string input and
a `lastKey` string output (MIDI Input, OSC Input): `learn_arm`, `learn_cancel`, `learn_commit`
(`{"label": …}` optional — commits the learned control as a NEW output socket the user wires by hand),
`remove_binding` (`{"port": …}`). Anything else is dropped; a card can only act on its own node.
`state.learn` is how the card knows the arm was taken and which control moved.

## The gesture rule (get this right)

- `live` on every drag tick, `commit` **exactly once** when the gesture ends. `live` costs nothing and
  never touches disk; `commit` is a project write and an undo step.
- Render the COMMITTED value from the snapshot (`state.input("x")?.defaultDouble`) except while the
  hand owns the control: keep a local `@State` drag value, show it while dragging, clear it on commit
  — the next snapshot then agrees with what you committed, so the control never snaps back.
- Controls with no editing-ended callback (a `ColorPicker`) commit after a settle (~400 ms after the
  last change) instead.
- Sliders: `Slider(value: binding, in: range, onEditingChanged:)` — set → `live`, `!editing` → `commit`.
  Handles: `DragGesture(minimumDistance: 0, coordinateSpace: .named("sz-card-body"))` — `.onChanged` →
  `live`, `.onEnded` → `commit`. Read ranges from `uiMin/uiMax`, never hardcode them.

## Sizing, plumbing, backdrop

- The card region is clipped to its footprint (`bodySize`: the card's width × rows × 24 pt). Declare
  it in the CONTRACT: `"card": { "cols": 12, "rows": 8, "backdrop": "output", "plumbing": [...] }`
  (all optional; defaults 9 × 8; `cols` is a MINIMUM width — the generated rows, or a backdrop
  filling its rows, may widen the card). A library node whose contract declares a `card` block (even
  `{}`) mounts its card by default when added; a Card.swift without one waits in the context menu.
  Your view's natural height is measured and the rows auto-grow to fit unless the user pinned the
  size — but design for the declared footprint, and size explicit canvases to `bodySize`.
- `backdrop` names a TEXTURE OUTPUT the host draws as a live thumbnail INSIDE the region (square
  corners, 8 pt margins, then a gap and a 20 pt footer band under it for your own controls). The region then
  follows the render aspect automatically — you don't size it. `state.backdrop` is the image rect
  in region points: a normalized point `(x, y)` sits at `backdrop.origin + (x·width, y·height)`, and
  a drag maps back the same way. That is how a corner-pin or crop card lines up with the pixels.
- `"plumbing": ["tl", "tr", …]` names the inputs your card OWNS (a handle IS the port): their
  generated rows — control and socket — step aside while the card shows, so a value is never
  presented twice. They stay settable over MCP; the user flips to rows to wire one. Anything you do
  NOT list keeps its normal row below the card (the texture `input`, an enum the card can't write).

## Rules

- **Never redeclare** the injected types or `@_cdecl` symbols; never touch `SZCardHostRaw`.
- Nothing crosses from your card except calls on `state`. Don't keep global mutable state
  (`static var`) — a hot reload swaps modules and it evaporates.
- Cards are cheap UI, not logic: the graph stays self-describing without the card (deleting the card
  changes nothing about rendering — the values are port data). Anything a wire may drive, show as
  driven (`connectedInputs`) and don't write to.
- Keep it crisp at zoom: plain SwiftUI shapes/text; no bitmaps.

## Worked example — a slider per float input

This is also the starter the app scaffolds for "New Custom Card…" (it compiles for any node):

```swift
// Custom card for this node — edit and save: the card hot-reloads (a compile error keeps the
// last good build mounted and shows a warning chip). Docs: agent_docs_read { topic: "card-abi" }
// (or read the built-in card: corner-pin in the node library).
//
// The card is the region between the header and the port rows. List the inputs it takes over
// under "card": { "plumbing": [...] } in node-contract.json so their rows step aside.
import SwiftUI

struct MyCard: View {
    @ObservedObject var state: SZCardState
    @State private var dragging: [String: Double] = [:]   // the hand's value while a slider moves

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(state.inputs.filter { $0.type == "float" }, id: \.name) { port in
                slider(port)
            }
            if !state.inputs.contains(where: { $0.type == "float" }) {
                Text("no float inputs to drive — edit Card.swift").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func slider(_ port: SZCardPort) -> some View {
        let range = (port.uiMin ?? 0)...(port.uiMax ?? 1)
        let committed = min(max(port.defaultDouble ?? range.lowerBound, range.lowerBound), range.upperBound)
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(port.name.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(dragging[port.name] ?? committed, format: .number.precision(.fractionLength(2)))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            Slider(value: Binding(get: { dragging[port.name] ?? committed },
                                  set: { v in dragging[port.name] = v; state.live(port.name, v) }),   // stream
                   in: range,
                   onEditingChanged: { editing in
                       guard !editing, let v = dragging[port.name] else { return }
                       state.commit(port.name, v)                                                  // once
                       dragging[port.name] = nil
                   })
            .controlSize(.small)
            .disabled(state.connectedInputs.contains(port.name))   // a wire drives it — show, don't fight
        }
    }
}

enum SZCardMain { static func make(_ state: SZCardState) -> AnyView { AnyView(MyCard(state: state)) } }
```

## Shipping it

Stage the card WITH the node: `agent_write_node_staged { "node", "source", "contract", "card": "<full
Card.swift>" }`, then `agent_compile_node` — a red card blocks the promote and comes back as
`{ ok: false, errors: "Card.swift failed to compile …" }`. On the first promote with a card the node's
body switches to the card; the user can flip rows↔card any time (right-click, or `ui_set_node_body
{ mode: "custom" | "none" }`). Editing `Card.swift` on disk hot-reloads it; a red edit keeps the last
good build mounted with a warning chip.

Reference card in the built-in library (fetch with `agent_library_source { node: "corner-pin", file:
"Card.swift" }`): draggable handles over the output backdrop — live/commit, `state.backdrop`, corners
as `plumbing`, a footer readout + Reset. Cards are the exception, not the rule: most nodes are best
served by their generated rows; ship one only when direct manipulation genuinely beats a row.
