# UI Panels

**Package: SZUI.** Native panels only - **SwiftUI + AppKit, no WebView.** The UI is a function of
[SZCore state](STATE.md); every meaningful interaction has a matching `ui_` MCP command so the
same surface is drivable by agents and by tests ([MCP.md](MCP.md)).

## Layout

The window is a **freely rearrangeable panel layout** — panels are tiled sections, not
overlays: a binary split tree
(`SZPanelLayoutState`, SZCore) whose leaves are the panels, rendered by SZUI's
`SZPanelLayoutContainerView` as rounded tiles on a near-black window background.

- Every panel wears a thin **name header** (`SZPanelChromeView`): the drag handle, plus a ✕.
- **Panel identity is `SZPanelID`** - a kind plus an instance ordinal, addressed everywhere by
  one string token: `viewport` (the primary), `viewport:2`, … Identity is stable - closing an
  instance never renumbers another's token, and the next clone fills the lowest free number.
  Kinds may repeat up to `SZPanelKind.maxInstances` (viewport 8, everything else 1); each
  `SZPanelID` appears at most once. **Titles are positional, not identities**
  (`SZPanelID.displayTitles`): a lone viewport is "Viewport"; several live ones (tiles +
  pop-out windows) are always a dense "Viewport 1..n" in instance order, renumbering as
  instances come and go - so what users SEE always counts 1..n while records/agents hold
  stable tokens underneath.
- **Clone** (header button / View ▸ Clone Viewport / `ui_clone_panel`): splits the source tile
  50/50 with a new instance of its kind - the lowest free number, so closed numbers are reused.
  Only the viewport is cloneable today; every viewport shows the same render, with per-clone
  render routing as the planned follow-on.
- **Render resolution: the drivership ladder** (`SZViewportDriverRegistry`, recomputed on
  visibility and size edges from the viewport views actually in a window) - fullscreen
  pop-outs > windowed pop-outs > the primary tile. Fullscreen a pop-out on a projector and the
  graph renders at projector resolution while the editor tiles show a crisp downscale; fullscreen
  outranks floating windows regardless of area (an accidentally-enlarged preview window must
  never steal native resolution from the stage output). Within a rung, largest drawable area
  wins with ~15% hysteresis. With everything docked, the primary tile drives unconditionally -
  tiles never compete by area, so no divider drag can reshape the frame and docking a window
  back restores normal tile rendering. Mirrors are aspect-fit, letterboxed when shapes differ.
  With no viewport showing at all (closed, maximized-away), the runtime's loop keeps running for
  the node editor's live thumbnails as long as any are watched - closing the viewport never
  freezes the cards.
- **Pop out** (header button / View ▸ Pop Out Viewport / `ui_popout_panel` — or **drag the tile's
  header out of the window**: releasing outside the container tears it out into a window under
  the cursor): moves a viewport into its own floating window; via the button it opens exactly
  over its tile (the tile detaches in place; the layout closes the gap behind it). The window is fullscreen-capable (green button - the projector case).
  Pop-outs are children of the main window's lifetime: closing the main window closes them first
  (quit-on-close is unchanged), and they hide behind the welcome surface. The window's ✕/⌘W
  **docks the panel back**; View-menu off / `ui_close_panel` closes it for real. View ▸ Auto-Hide
  Panel Headers applies to pop-outs too: the strip slides away and hovering the window's top band
  summons it (the traffic lights stay).
- **Dock back**: the pop-out header's dock button returns the panel to its remembered spot
  (animating the window home first), or **drag the pop-out window - titlebar or anywhere on its
  body - over the main window** to dock it at any edge zone, with the same tinted drop preview as
  internal drags (`SZPopoutDockSession` owns the hit-testing; the manager reconstructs native
  window drags from move events + the mouse button, since AppKit has no end-of-drag API).
  `ui_dock_panel` mirrors both paths.
- **Drag a header onto another panel** to rearrange: edge zones split that panel (a tinted overlay
  + label explain the pending change), the center zone swaps the two. **Drag it to the window's
  border** instead and the panel pins to that whole side, spanning it with everything else beside
  it - the one arrangement an onto-a-panel drop can't make, since that always pairs it with exactly
  one other panel. The border wins over the panel under it, but only once the drag has clearly
  begun, so a slip on a header stays the cancel it has always been. Dropping runs a quick
  autolayout (`normalize()`: fraction clamping + tree sanitizing, including stripping instances
  beyond a kind's cap).
- **Dividers** (the gaps between tiles) drag to resize, with per-orientation resize cursors and
  per-panel minimum sizes.
- **Closing** a panel collapses its split and remembers its spot; reopening (View-menu toggles,
  ⌘⌥1/2/3 - chat also via the HUD message icon) restores it.
- The layout persists per machine in `app-state.json` (`SZAppState` via `SZAppStateIO`, Application
  Support) - deliberately **not** in the project: a `.subz` is a portable document. Popped-out
  windows persist beside it (`poppedOutPanels`, screen frames sanitized against the current
  displays on restore), so the whole arrangement - windows included - survives a relaunch.
- Panel tiles render as a flat ZStack keyed by panel identity, so rearranging never tears down
  panel internals (the Metal viewport, canvas zoom/pan, and chat drafts survive every move).
  Popping out / docking intentionally recreates the panel's view in its new window (render state
  lives in the runtime).

```
┌─ SZApp window ──────────────────────────────────┐
│ ┌ Viewport ────────────────┐  ┌ Chat ─────────┐ │
│ │  (Metal live render)     │  │  one feed     │ │
│ ├ Node Editor ─────────────┤  │               │ │
│ │  ●Camera ─▶ ●Grayscale   │  │  run strip    │ │
│ │            [HUD capsule] │  │  composer     │ │
│ └──────────────────────────┘  └───────────────┘ │
└──────────────────────────────────────────────────┘
    (default arrangement - every panel can move)
```

## ViewportPanel

- A `CAMetalLayer`-backed `NSView` wrapped for SwiftUI via `NSViewRepresentable` - a *surface* of
  the runtime's render loop: it reports attach / resize / detach to the host, which attaches its
  layer to the runtime. This is the only place Metal touches the UI.
- Displays whatever texture output is currently marked for display
  ([RUNTIME.md](RUNTIME.md) blits it to the drawable). The user changes the displayed output with
  the per-output **display** toggle in the node editor (`ui_toggle_display`).

## Node Editor

A classic node-graph editor rendered natively over the viewport. Two node kinds
([GRAPH_AND_NODES.md](GRAPH_AND_NODES.md)):

- **Prompt node (pre-gen):** prompt text + pending/busy indicator. Usually no typed ports yet;
  a wire-spawned node carries its one seeded port.
- **Generated node (post-gen):** header (title + SF Symbol) and one port row per declared
  input/output; unconnected inputs render their compatible control (slider, toggle, dropdown,
  field, file picker); texture outputs show a **display** toggle. Between header and rows sits the
  **body region**: the live preview of a texture output by default, or the node's **custom card**
  when it ships a `Card.swift` and the body is set to custom ([GRAPH_AND_NODES.md](GRAPH_AND_NODES.md#custom-card-cardswift)).
  A backdrop card (corner-pin) shows the output under its handles and sizes the region to the
  render aspect; the inputs the card owns (`card.plumbing`) get no row while it shows.
- **A row the running build has no port for is read-only.** An agent declares a node's ports before
  its code exists, so a card can grow a row minutes before anything reads it. Those rows (the ports
  in the contract that the build stamp never saw) dim their label, hollow their socket dot, and show
  their control in the card's read-only form until the node is rebuilt. A knob that changes nothing
  is worse than one you cannot turn. While an agent is actually writing that code the row breathes,
  phase-locked to the status pill off the shared `SZPulse`; a row nobody is building sits still,
  because a declared port can stay unbuilt for hours after a run ends and a canvas may be on a wall.
  Nothing re-lays-out: `controlWidth` reserves by port type and never asks what the build knows, so
  no socket or edge moves when a port is declared.
- **A node an agent is working on wears a padlock and cannot be deleted.** The badge means held, not
  frozen: the node keeps rendering, and its knobs, wires, position and viewport toggle stay the
  user's, whoever is rewriting its source. What counts as work depends on the holder: a node chat's
  claim lasts exactly as long as its turn, so holding it IS the work, while a run holds its whole
  work set to the end, so there the work is the node still needing implementation and the hold lifts
  at that node's own promote. A node that needs a rebuild with nobody on it is not held and deletes
  normally. **Greying the card is the separate, stricter state**, and it means only one thing: there
  is no build to touch yet. A node being built for the first time greys; so does an original mid
  split/merge. A node that renders never does.
- **Folding the plugs:** a card with a body can put its port rows away (chevron pill under the card,
  or right-click → **Hide Plugs**), so the preview or the custom card IS the card. The card keeps its
  **top edge** and folds up under its header; the fold always drops a whole number of grid cells, so
  every edge stays on grid. Ports stay wired and connectable: a socket with a wire in it keeps its
  dot, stacked against the body edge in port order, and the rest come back when the card is selected
  or a wire is in flight looking for a target. A card with no body to show is not offered the fold.

Node anatomy should be **compact and sleek** (right anatomy, minimal bulk). The whole node view
is derived from the node's contract, so reflow on `ui_update_node` is
a state-driven re-render - no per-node-type view code.

Interactions (each backed by a `ui_` command): add prompt node, move, connect/disconnect (flow vs
data), edit input defaults, toggle display. Dragging a fresh wire into empty canvas spawns a
prompt node joined by that wire: a flow wire adds a flow edge; a data wire also seeds the new
node's contract with one port of the dragged port's exact type (`input`/`output`, the
contract-draft naming) so the typed edge is legal immediately. Split/merge and run are asked for
in MESSAGES now - see the context menu below; the deterministic ops live on as the agents'
`ui_split_node` / `ui_merge_nodes` / `ui_run` tools.

## Canvas context menu - right-click = "what can I say here"

Right-click (ctrl-click / two-finger tap) opens a custom floating menu (`SZCanvasContextMenuView`,
deliberately NOT an NSMenu: rows are draft messages, there's an inline free-text field, and a
later pass sends in place from the same surface). Rows ARE messages (locked ruling: suggestions
are REAL messages to real agents; determinism stays in the agents' `ui_*` tools):

- **A node** → "@\<node\> fix this: \<blocker\>" (when its agent reported error/needsInput),
  "@project implement @\<node\>" (prompt node) or "@project split @\<node\> into two stages"
  (generated), plus **Mention in Chat** (`text.bubble` — puts the node in the composer, since one
  conversation has no tab to open) and **Open Node.swift** (`doc.text`) action rows. A generated node with a `Card.swift` adds **Show Custom Card / Hide Custom Card** and
  **Open Card.swift**; one without adds **New Custom Card…** (scaffolds a starter and opens it).
  A generated node with a body region also adds **Hide Plugs / Show Plugs**.
  Right-click also selects the node (a multi-selection member keeps the set).
- **A multi-selection** → "@project merge @A, @B and @C into one node".
- **Empty canvas** → "@project implement the N pending nodes".
- Every menu has a **free-text row** seeded with the target's mention - the recipient is always
  explicit in the message itself.

Clicking a canned row SENDS it — those rows are whole instructions ("merge A and B into one
node"), so staging one only asked you to press send on a sentence you had already chosen. The
free-text row still lands in the composer, because that one you are still writing. The node card
has NO buttons
anymore (speech bubble and file button both removed): the card renders state, acting on a node is
the right-click menu's job. Suggestion derivation is host-side
(`SZHost+CanvasSuggestions.swift`); the menu renders dumb values only.

## Chat panel

**One conversation.** There are no tabs: every message goes to the Director's door, which
triages it and routes the work. What you see is one feed of what agents said to YOU — the whole
Director conversation, plus each node agent's own replies, attributed by node. The fleet's
implementation turns are not in it by default: they carry the run they belong to and are read in
the Agent Graph panel, or in the conversation under **View ▸ Display ▸ Show Agent Activity**.

- The feed is DERIVED (`SZHost.chatFeed`) from the per-scope transcripts, which remain the
  storage — sessions and cold-start recaps are per scope and stay that way. A node's messages join
  the feed if they are unstamped (or activity is on) AND newer than the project's `feedEpoch` (a
  `.staging` marker written the first time the project opens under this build): older builds wrote
  their implementation turns into node transcripts with nothing marking them as fleet work, so
  without the epoch an old project's first open would fill the conversation with every coding turn
  it ever ran. The epoch therefore gates BOTH ways — activity on never reaches prehistory.
- **Show Agent Activity** (off by default, persisted per machine in `SZAppState`) puts each coding
  agent's own turn in the feed WHILE it builds, under the node's name and glyph, its tool calls and
  reasoning behind the same `THINKING` chevron the Director's turns use — so a ten-minute build is
  something to read rather than a bare clock. Nothing new is captured: the stream already lands in
  the node's transcript, so turning it on reveals past builds too. The turns persist after the
  build settles, alongside its receipt: the receipt says what a build did, the turns say what its
  agents tried.
- **An empty transcript asks a question.** "What are we making?" over a quieter line about nodes
  getting created, wired and coded for you — centred in the panel, outside the ScrollView, since a
  placeholder has nothing to scroll. While a project opens (its nodes compile off the main thread,
  see RUNTIME's build & hot reload) that slot shows a spinner and "Loading conversation" instead;
  a feed that already has messages keeps showing them rather than blanking.
- The panel has NO header row. One conversation had nothing to name, so its actions —
  **AI Settings…** (the provider + routing sheet) and **Clear Transcript & Reset Agent**, which
  clears every scope the feed is made of — moved into a ⋯ menu beside the composer's +.
- **@mentions** are the addressing substrate turned into a targeting HINT: `@project`, `@all`,
  `@<node title>` — typed via an autocomplete (`@` at a word boundary), inserted as atomic accent
  tokens, stored as canonical markup (`@[Blur](node:UUID)`, SZCore `SZMentionMarkup`), expanded
  for the CLI at every egress, and rendered as accent chips (a deleted node's mention dims +
  strikes through). A mention no longer routes: the Director's triage reads it.
- **A node card's chat button MENTIONS that node** — it inserts the token at the caret (through
  the composer's own relay, so it lands in the sentence you were already writing) and focuses the
  field. The context-menu row is "Mention in Chat".
- **The run strip** sits between the transcript and the composer, outside the ScrollView (a run
  is a state, not a message — it must not enter the LazyVStack the bottom-pin anchor drives). It
  draws a small process tree: one group per LIVE BUILD — the Director's own lane, then the coding
  agents it dispatched, indented on a drawn connector (`├─`/`└─`), live children first so the
  cap never hides the agents actually working. A live Director lane carries the ■ that stops THAT
  build; it is the only per-build stop (the HUD has none, and Graph ▸ Stop All Builds / ⌘. stops
  everything). Under the groups sit the SCHEDULED tasks: what was asked, what it is behind, and a
  ✕ to drop it. Every row is a door into the Agent Graph panel. Presence, not a lock. The lanes are
  the strip's own, not `SZAgentSubagentLane`: inside a dispatch card a lane fills the card's width,
  which out here read as a stack of full-width buttons. The shared thing is the vocabulary
  (`SZRunBadge`: running / end / stopped / declined / failed).
- **A finished build settles into the transcript as a RECEIPT** — the same lane, at the point in
  time where it ended (`SZChatReceipt`, rendered by `SZChatReceiptRow` over the shared
  `SZLanePill`). A run is a state while it happens and a receipt once it is over: presence, then
  record. The host says nothing at the start (the strip is already there, saying more) and nothing
  about queueing (a scheduled row says it, and names the blocker) — **only the ending is news**.
  The receipt names the WORK, not a count — `built Warm Orange`, `built 3 nodes`, `built 2 of 3`,
  `1 node unfinished` — because concurrent one-node builds used to finish as the same sentence
  repeated. It wears the `hammer` (a work lane; `eyeglasses` stays the Director's own lane), takes
  the `SZRunBadge` vocabulary only for endings that are NOT clean, carries a failure's reason as a
  quiet line beneath, and is the transcript's jump into the Agent Graph via `graphRunID`. It is
  deliberately NOT a turn: no rail, no `DIRECTOR AGENT` header — the host is not the Director, and
  a host line dressed as one is what this replaced. Its label aligns with the turns' text column,
  not their rails.
- **The send slot is THE action slot** (one place, two states): per-turn **Stop** while an
  interactive turn streams (session + partial reply survive); else send. It never stops a BUILD —
  with several in flight a composer button cannot say which one it means, so that lives on the
  build's own lane in the strip. Click only — Return never stops anything. The composer is never disabled:
  a send while something streams simply queues, with a chip on its bubble.
- The **composer** is a Codex-style rounded two-row card floating on the panel background: the
  growing text field on top; a bottom bar with `+` attach and the ⋯ menu (left) and the circular
  send (right). The provider pill is GONE: the forward-looking selection lives in the **AI
  Settings sheet** (⌘,, or the ⋯ menu's "AI Settings…"), and the backward-looking truth is the
  **receipt caption** under each finished reply — `Worked for 12s · gpt-5.6-terra · fast · tok
  21.5k in / 1.2k out` — whose hover reveals the full envelope (provider · model · effort · fast)
  and the routing rule that chose it (`via`). Tokens ride the caption unconditionally, carry `tok`
  as their unit so the numbers cannot read as anything else a turn counts, and are simply absent
  for a CLI that reports no usage. A provider *switch* still resets agent sessions (transcripts stay) and
  is refused while agents are busy; with a routing profile active, different graph positions may
  run different envelopes, and the receipts are how you see what actually ran
  ([AI_PROVIDERS.md](AI_PROVIDERS.md#model-routing)).
- A **streaming turn's working row** shows dots + elapsed only; stopping lives in the composer's
  action slot. A stopped turn keeps its session and partial reply.
- This is a **from-scratch** design - keep it clean and native.

## HUD

- At-a-glance status: run/build state, fps, current display output, active agent count, errors.
- A quick entry point to logs (build / agent / runtime) - diagnostics are first-class, reachable
  in one click.

## File menu

`CommandGroup(replacing: .newItem)` - the document lifecycle
([STATE.md](STATE.md) has the on-disk story):

- **New Project** (⌘N) - a fresh empty untitled project (`SZUntitledProjects` home); no "unsaved
  changes" prompt ever (persistence is automatic; the previous untitled stays reachable via Open
  Recent).
- **Open…** (⌘O) - picks a `.subz` directory (validated on confirm; no registered document type
  yet).
- **Open Recent** - the MRU (cap 10), existence-filtered at menu build, plus Clear Menu.
- **Save…** (⌘S) - untitled projects only, and it opens the same panel Save As does. A placed
  project has no Save item: it is written as it changes, so one would imply dirty state that
  doesn't exist.
- **Save As…** (⇧⌘S) - copies the bundle, then makes the copy the live project in place, reloading
  nothing. Replacing `.newItem` also drops "New Window" - intended (single-window app).
- New / Open / Open Recent disable while a run or chat turn is in flight; Save and Save As stay
  live, because they write without swapping the project ([STATE.md](STATE.md)). Every method guards
  too - the MCP surface can race a click.
- The **window title** (project name, with a "not saved" suffix while untitled) draws as a dim
  non-hit-testing overlay in the titlebar safe-area strip - `.hiddenTitleBar` hides the native
  text, and the strip stays the window-drag zone.

## Settings

- **Agent Providers** - the provider half of the AI Settings sheet, on ⌘,
  (`CommandGroup(replacing: .appSettings)`), the chat ⋯ menu's "AI Settings…" item, and
  auto-presented on first run until a default is confirmed. Provider cards with live status
  badges (Ready / Verified / Not Installed / Login Needed / Failing), inline remedies (copyable
  install command; "Open Terminal to Log In" - a `.command` file handed to Terminal.app, no
  Apple-Events prompt), a per-card Test running the one-shot prompt probe, and a 3s cheap-tier
  re-check loop while open so remedies flip cards green on their own. First run: Confirm
  persists `defaultProviderID`, Skip returns next launch. Settled installs pick by clicking:
  selecting a READY card switches the active provider on the spot, and the Active capsule
  marks the provider actually in use ([AI_PROVIDERS.md](AI_PROVIDERS.md)).
- **AI Settings sheet** - the provider cards above sit behind a two-item sidebar,
  **Providers | Routing**. Providers is the card surface described above (active provider +
  model / effort / fast per provider — the global default envelope; generation controls live
  here, not in the composer). **Routing**
  ([AI_PROVIDERS.md](AI_PROVIDERS.md#model-routing)): an Enable Model Routing toggle (off
  hides the rest and says where everything runs; a (?) bubble carries the explainer) over a
  Profiles list where the SELECTED row is both what runs and what the cards below edit —
  double-click renames in place, + creates and selects, the toolbar deletes and duplicates.
  Two shipped read-only starters seed once their provider is usable (Claude Routing and
  Codex Routing, both "(sxp.studio)"): locked rows, no edit or rename or delete — Duplicate
  births an editable copy. Below, one tinted card per agent, one row per declared slot with
  the pack author's caption (the built-ins: the Director's Plan/Chat/Sort, Coding's Build
  rows the task grades pick among plus Edit for a change asked of a built node, Debug's
  Assistant). Switching governs NEW conversations
  only and is refused while a run is in flight. The
  unhealthy-provider **warning dot** lost its composer home: it lives on the sheet's surfaces (the
  provider card / sidebar badge) — runs and new chats on an unhealthy provider still refuse and
  open the sheet instead of failing silently.
- **Envelopes are visible where work is**: each finished reply's receipt caption in the
  transcript; the RUNS panel's cards show `duration · envelope` per turn plus the node's grade
  tag on fleet work. The receipts are the ground truth a routing profile is judged against.
- **macOS permissions dashboard (future)** - camera, microphone, etc.: current status + a way to
  request, reflecting what the runtime holds ([RUNTIME.md](RUNTIME.md)).

## Principles

- **State-derived views.** Panels bind to the `SZCore` `@Observable` `Store` and don't hold canonical
  state; they emit `Command`s / intents that the **host** executes
  ([ARCHITECTURE.md](ARCHITECTURE.md#the-host-seam)). Agent edits and user edits flow through the same
  commands, so the UI looks identical regardless of who acted.
- **1:1 with MCP.** If a user can do it here, there's a `ui_` command for it - this is what makes
  the app testable headlessly while agents build it.
- **Native and lean.** No WebView, no web asset bridge, no native↔web state drift (the failure
  mode a WebView UI is prone to).

## Test scenarios

- A `ui_update_node` (from an agent or a test) reflows a node's ports identically to a user edit.
- Toggling display on a different texture output updates the viewport with no rebuild.
- A mention of a node reaches that node's agent, through the Director.
- Provider health and permission states render correctly for each combination.
