# UI Panels

**Package: SZUI.** Native panels only - **SwiftUI + AppKit.** The one WKWebView in the app is a web
project's viewport, a render surface the host owns and the tile hosts as a plain `NSView`; no panel
is web content. The UI is a function of
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
  freezes the cards. A web project's page renders only while its tile is in a window, so hiding
  that viewport does freeze them.
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
- In a web project the tile is `SZWebViewportPanel` instead: it re-parents the page view the host
  owns (a WKWebView, though SZUI only sees an `NSView`), so panel moves never reload the page, and
  it shows why in plain words while the page is not up. Node thumbnails and recording work as on
  the Mac (the page streams them, [RUNTIME.md](RUNTIME.md#web-runtime)); the recording edge and the
  framing editor are the same overlays the Metal tile wears. Clones and pop-outs are not there for
  a web project yet.

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
triages it and routes the work. What you see is one feed of everything the agents said — the whole
Director conversation, each node agent's own replies, and each coding agent's build turns as they
happen, attributed by node. A Director note written into a node's conversation is labelled with
the agent it is for.

- The feed is DERIVED (`SZHost.chatFeed`) from the per-scope transcripts, which remain the
  storage — sessions and cold-start recaps are per scope and stay that way. A node's messages join
  the feed if they are newer than the project's `feedEpoch` (a `.staging` marker written the first
  time the project opens under this build): older builds wrote their implementation turns into node
  transcripts with nothing marking them as fleet work, so without the epoch an old project's first
  open would fill the conversation with every coding turn it ever ran.

## HUD

- At-a-glance status: run/build state, fps, current display output, active agent count, errors.
- A quick entry point to logs (build / agent / runtime) - diagnostics are first-class, reachable
  in one click.
- **Record** (the dot in the playback group): one press starts a take with the saved settings;
  the dot goes red with an elapsed readout and every viewport wears a thin red edge. The sticky
  settings live in a Recording Options sheet (framing summary + Edit, resolution, frame rate,
  format, sound) reached from the gear menu / app menu, auto-opened on the dot's first-ever use.
  While a cropped take rolls the viewport outlines the recorded region and dims the rest. Edit
  framing opens a crop overlay on the largest visible viewport (dimmed surround, handles, ratio
  chips, Done/esc); the crop is global and picture-normalized. During a take the engine renders
  at the crop-derived size (long side capped 4K-class) and viewports aspect-fit. Pause pauses
  the writer with the clock - the paused span is absent from the file (the OBS/TouchDesigner
  behavior). Takes land in the project bundle's `recordings/` as `Recording N` (fragment-written
  .mov while rolling, so a crash leaves a playable file; h264/hevc rewrap to .mp4 on stop).
  Stopping shows a toast with thumbnail, length, dimensions, fps and Reveal; project switch,
  Save As, and quit finalize a rolling take. Sound is a source picker, Off by default: App
  captures only this app's audio, System everything the Mac is playing (via ScreenCaptureKit;
  needs the Screen Recording permission, and a refusal leaves the take video-only).

## File menu

`CommandGroup(replacing: .newItem)` - the document lifecycle
([STATE.md](STATE.md) has the on-disk story):

- **New Project** (⌘N) - a sheet asks where the project will run, **On this Mac** or **In a
  browser** (`SZNewProjectSheet`, preselecting last time's pick, under the hint "You can change
  this later in Settings"), then creates a fresh empty untitled project for that target
  (`SZUntitledProjects` home); no "unsaved changes" prompt ever
  (persistence is automatic; the previous untitled stays reachable via Open Recent). The same sheet
  serves the welcome screen's New Project, Esc from the welcome with nothing open, and a launch
  with nothing to reopen, where it has no Cancel.
- **Open…** (⌘O) - picks a `.subz` directory (validated on confirm; no registered document type
  yet).
- **Open Recent** - the MRU (cap 10), existence-filtered at menu build, plus Clear Menu.
- **Save…** (⌘S) - untitled projects only, and it opens the same panel Save As does. A placed
  project has no Save item: it is written as it changes, so one would imply dirty state that
  doesn't exist.
- **Save As…** (⇧⌘S) - copies the bundle, then makes the copy the live project in place, reloading
  nothing. Replacing `.newItem` also drops "New Window" - intended (single-window app).
- **Target Platform…** - opens Settings on its Target Platform pane, where the open project is
  switched between this Mac and the browser in place (below). Disabled with no project open.
- **Export as Web App…** (⇧⌘E) and **Open in Browser** - web projects only: one self-contained
  `.html` (the page runtime, three.js and every node inlined), saved where you choose, or written
  to the project's `exports/` folder and handed to the default browser.
- New / Open / Open Recent disable while a run or chat turn is in flight; Save and Save As stay
  live, because they write without swapping the project ([STATE.md](STATE.md)). Every method guards
  too - the MCP surface can race a click.
- The **window title** (project name, with a "not saved" suffix while untitled) draws as a dim
  non-hit-testing overlay in the titlebar safe-area strip - `.hiddenTitleBar` hides the native
  text, and the strip stays the window-drag zone.

## Settings

- **Settings sheet** - on ⌘, (`CommandGroup(replacing: .appSettings)`), the gear menu's
  Settings… item, the chat ⋯ menu's "AI Settings" item, and auto-presented on first run until a
  default provider is confirmed. Titled "Settings", with a sidebar of three panes, **Target
  Platform | Providers | Routing**; Target Platform is listed only while a project is open, and
  File ▸ Target Platform… opens the sheet straight on it.
- **Target Platform** (`SZTargetPlatformPane`) - where the open project runs, switched in place.
  One row per platform, This Mac and Browser (BETA), each with its description, an ACTIVE badge on
  the current one and "N of M nodes built" (a source file for that platform that is not behind the
  contract). Clicking the other row picks it: the footer says what the switch would convert and what
  comes from the library, and a Switch button confirms it; the sheet then closes, since the
  conversion is a run followed in the chat like any other. The switch (`SZHost.setProjectTarget`)
  flips and persists the target (a web project pins its
  three.js version), every node placed from a library node that ships a file for the new platform
  gets that twin copied in without an agent (`SZNode.libraryID`), the renderer is remounted
  (Metal keeps an empty graph for a web project; the page is mounted for the browser), and a run
  with the intent `convert` is minted over the nodes still missing a source
  ([AGENT_GRAPHS.md](AGENT_GRAPHS.md)). Each node keeps one source per platform side by side, so
  switching back needs nothing once both exist ([GRAPH_AND_NODES.md](GRAPH_AND_NODES.md)).
  Refused while a run owns the project. Until its
  source lands, a node wears the pill "Not built for this platform" and stays out of the render
  graph. While the run works the pane shows a report, one line per node the switch touched:
  READY with "copied from the library" or "regenerated from its prompt", CONVERTING, QUEUED,
  NOT ON BROWSER / NOT ON MAC with the agent's reason (it answered `needsInput`), or FAILED; Stop
  cancels the run and leaves converted nodes converted, and the finished header reads
  "N regenerated · N from the library · N not available". On a ready web project the action row
  carries Open in Browser and Export as Web App… instead.
- **Providers** - provider cards with live status badges (Ready / Verified / Not Installed /
  Login Needed / Failing), inline remedies (copyable
  install command; "Open Terminal to Log In" - a `.command` file handed to Terminal.app, no
  Apple-Events prompt), a per-card Test running the one-shot prompt probe, and a 3s cheap-tier
  re-check loop while open so remedies flip cards green on their own. First run: Confirm
  persists `defaultProviderID`, Skip returns next launch. Settled installs pick by clicking:
  selecting a READY card switches the active provider on the spot, and the Active capsule
  marks the provider actually in use ([AI_PROVIDERS.md](AI_PROVIDERS.md)).
- **Routing** - the Providers pane holds the global default envelope (active provider +
  model / effort / fast per provider; generation controls live there, not in the composer).
  Routing ([AI_PROVIDERS.md](AI_PROVIDERS.md#model-routing)) refines it: an Enable Model Routing toggle (off
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
- **Native and lean.** No panel is a WebView, so the UI has no web asset bridge and no native↔web
  state drift. A web project's viewport is a WKWebView, but it only renders the graph: the page
  receives the graph from the host and reports errors back, and holds no UI state.

## Test scenarios

- A `ui_update_node` (from an agent or a test) reflows a node's ports identically to a user edit.
- Toggling display on a different texture output updates the viewport with no rebuild.
- A mention of a node reaches that node's agent, through the Director.
- Provider health and permission states render correctly for each combination.
