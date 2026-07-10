# UI Panels

**Package: SZUI.** Native panels only - **SwiftUI + AppKit, no WebView.** The UI is a function of
[SZCore state](STATE.md); every meaningful interaction has a matching `ui_` MCP command so the
same surface is drivable by agents and by tests ([MCP.md](MCP.md)).

## Layout

The window is a **freely rearrangeable panel layout** (this supersedes the earlier "node editor
floats over the viewport" sketch - panels are tiled sections, not overlays): a binary split tree
(`SZPanelLayoutState`, SZCore) whose leaves are the panels, rendered by SZUI's
`SZPanelLayoutContainerView` as rounded tiles on a near-black window background.

- Every panel wears a thin **name header** (`SZPanelChromeView`): the drag handle, plus a ✕.
- **Drag a header onto another panel** to rearrange: edge zones split that panel (a tinted overlay
  + label explain the pending change), the center zone swaps the two. Dropping runs a quick
  autolayout (`normalize()`: fraction clamping + tree sanitizing).
- **Dividers** (the gaps between tiles) drag to resize, with per-orientation resize cursors and
  per-panel minimum sizes.
- **Closing** a panel collapses its split and remembers its spot; reopening (View-menu toggles,
  ⌘⌥1/2/3 - chat also via the HUD message icon) restores it.
- The layout persists per machine in `app-state.json` (`SZAppState` via `SZAppStateIO`, Application
  Support) - deliberately **not** in the project: a `.subz` is a portable document.
- Panel tiles render as a flat ZStack keyed by panel identity, so rearranging never tears down
  panel internals (the Metal viewport, canvas zoom/pan, and chat drafts survive every move).

```
┌─ SZApp window ──────────────────────────────────┐
│ ┌ Viewport ────────────────┐  ┌ Chat ─────────┐ │
│ │  (Metal live render)     │  │  Director /   │ │
│ ├ Node Editor ─────────────┤  │  node tabs    │ │
│ │  ●Camera ─▶ ●Grayscale   │  │               │ │
│ │            [HUD capsule] │  │  composer     │ │
│ └──────────────────────────┘  └───────────────┘ │
└──────────────────────────────────────────────────┘
    (default arrangement - every panel can move)
```

## ViewportPanel

- An `MTKView` (or `CAMetalLayer`-backed `NSView`) wrapped for SwiftUI via
  `NSViewRepresentable`. This is the only place Metal touches the UI.
- Displays whatever texture output is currently marked for display
  ([RUNTIME.md](RUNTIME.md) blits it to the drawable). The user changes the displayed output with
  the per-output **display** toggle in the node editor (`ui_toggle_display`).
- Owns viewport interactions tied to `Project` state: zoom, translation, fps readout.

## Node Editor

A classic node-graph editor rendered natively over the viewport. Two node kinds
([GRAPH_AND_NODES.md](GRAPH_AND_NODES.md)):

- **Prompt node (pre-gen):** prompt text + pending/busy indicator. No typed ports yet.
- **Generated node (post-gen):** header (title + SF Symbol) and one port row per declared
  input/output; unconnected inputs render their compatible control (slider, toggle, dropdown,
  field, file picker); texture outputs show a **display** toggle.

Node anatomy should be **compact and sleek** (right anatomy, minimal bulk). The whole node view
is derived from the node's contract, so reflow on `ui_update_node` is
a state-driven re-render - no per-node-type view code.

Interactions (each backed by a `ui_` command): add prompt node, move, connect/disconnect (flow vs
data), edit input defaults, toggle display. Split/merge and run are asked for in MESSAGES now -
see the context menu below; the deterministic ops live on as the agents' `ui_split_node` /
`ui_merge_nodes` / `ui_run` tools.

## Canvas context menu - right-click = "what can I say here"

Right-click (ctrl-click / two-finger tap) opens a custom floating menu (`SZCanvasContextMenuView`,
deliberately NOT an NSMenu: rows are draft messages, there's an inline free-text field, and a
later pass sends in place from the same surface). Rows ARE messages (locked ruling: suggestions
are REAL messages to real agents; determinism stays in the agents' `ui_*` tools):

- **A node** → "@\<node\> fix this: \<blocker\>" (when its agent reported error/needsInput),
  "@project implement @\<node\>" (prompt node) or "@project split @\<node\> into two stages"
  (generated), plus **Open Transcript** (`text.quote` - read) and **Open Node.swift** (`doc.text`)
  action rows. Right-click also selects the node (a multi-selection member keeps the set).
- **A multi-selection** → "@project merge @A, @B and @C into one node".
- **Empty canvas** → "@project implement the N pending nodes".
- Every menu has a **free-text row** seeded with the target's mention - the recipient is always
  explicit in the message itself.

Clicking a row lands the draft in the composer (panel auto-opens on the recipient's tab, send
pulses until acted on - V1 ruling: compose, never auto-send). The node card has NO buttons
anymore (speech bubble and file button both removed): the card renders state, acting on a node is
the right-click menu's job. Suggestion derivation is host-side
(`SZHost+CanvasSuggestions.swift`); the menu renders dumb values only.

## Chat panel

- Converse with the **Director Agent** (the **Project** tab - the tab names the place, the agent
  keeps its role name) or with a **single node's Coding Agent**.
- Messages map to `ui_send_chat`; agent responses stream back into the transcript.
- **@mentions** are the addressing substrate: `@project`, `@all`, `@<node title>` - typed via an
  autocomplete (`@` at a word boundary), inserted as atomic accent tokens, stored as canonical
  markup (`@[Blur](node:UUID)`, SZCore `SZMentionMarkup`), expanded for the CLI at every egress
  (send + recap: inline `@display` + a manifest of uuid + live title), and rendered as accent
  chips in the transcript (a deleted node's mention dims + strikes through).
- **Routing** (`SZChatRouting.resolveRecipient` - the one swappable policy function): a message
  that LEADS with a mention goes to that entity's agent (node → its Coding Agent direct;
  `@project`/`@all` → the Director Agent); no leading mention → the shown tab's agent. Other
  mentions are references. The composer's **→ recipient indicator** mirrors the rule live.
- **Tab activity dots**: pulsing while that scope's agent streams; AMBER while the agent is
  blocked on the user (`needsInput` - persists until the state resolves); a static blue unread
  dot once a turn finishes off-screen, until the tab is visited.
- **The send slot is THE action slot** (one place, three states - a stop that wanders reads as
  two controls): whole-run **Stop** on the Project tab while a run is in flight; per-turn **Stop**
  while the shown tab's own interactive turn streams (session + partial reply survive); else
  send. Click only - Return never stops anything. Other tabs disable send mid-run with the reason
  shown in the indicator slot (mid-run user messaging is deferred - drafts still compose). The
  Project composer's placeholder hints the paradigm when nodes are pending ("Try: @project -
  implement the N pending nodes").
- The **composer** is a Codex-style rounded two-row card floating on the panel
  background: the growing text field on top; a bottom bar with `+` attach (left) and the
  **provider generation picker** + circular send (right). (A project context chip
  under the card was tried and CUT - it duplicated the window title and wasn't interactive; a
  chip row can return when chips do something.) The picker (`SZProviderGenerationPickerView`)
  is one pill (`[health dot] [bolt] model · effort ⌄`) opening a nested menu: providers
  (unhealthy = dimmed), model / reasoning-effort (hidden for a CLI with no effort concept) /
  fast-mode submenus, and "Agent Providers…" into the setup sheet. Selection is **global**
  (one selection, every tab, always what Run uses - per-agent-type overrides deliberately
  deferred to agent profiles); a provider *switch* resets agent sessions (transcripts stay;
  the next message cold-starts on the transcript recap) and is refused while agents are busy.
- A **streaming turn's working row** shows dots + elapsed only; stopping lives in the composer's
  action slot (see above) - per-turn for the shown tab's interactive turn, whole-run on the
  Project tab. A stopped turn keeps its session and partial reply.
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
- **Save As…** (⇧⌘S) - duplicate-and-switch; there is deliberately **no Save** (it would imply
  dirty state that doesn't exist). Replacing `.newItem` also drops "New Window" - intended
  (single-window app).
- All items disable while a run or chat turn is in flight (the methods are guarded too).
- The **window title** (project name, with a "not saved" suffix while untitled) draws as a dim
  non-hit-testing overlay in the titlebar safe-area strip - `.hiddenTitleBar` hides the native
  text, and the strip stays the window-drag zone.

## Settings

- **Agent Providers sheet (shipped)** - the app's only settings surface today, on ⌘,
  (`CommandGroup(replacing: .appSettings)`), the HUD picker's "Agent Providers…" menu item, and
  auto-presented on first run until a default is confirmed. Provider cards with live status
  badges (Ready / Verified / Not Installed / Login Needed / Failing), inline remedies (copyable
  install command; "Open Terminal to Log In" - a `.command` file handed to Terminal.app, no
  Apple-Events prompt), a per-card Test running the one-shot prompt probe, and a 3s cheap-tier
  re-check loop while open so remedies flip cards green on their own. Confirm persists
  `defaultProviderID`; Skip returns next launch ([AI_PROVIDERS.md](AI_PROVIDERS.md)).
- Provider selection lives in the chat composer's `SZProviderGenerationPickerView` (Task 5 -
  the old HUD `SZProviderPickerView` is deleted; the HUD is canvas tools only: chat · add ·
  delete, with a working dot on the chat toggle while agents run with the panel closed).
  Unhealthy providers render dimmed but visible; runs and new chats on an unhealthy
  provider refuse and open the sheet instead of failing silently; the pill wears a warning dot
  while the ACTIVE provider is unhealthy (the menu's "Agent Providers…" item is the way in).
- **macOS permissions dashboard (future)** - camera, microphone, etc.: current status + a way to
  request, reflecting what the runtime holds ([RUNTIME.md](RUNTIME.md)).
- Per-agent-type (Director vs Coding) generation overrides remain future work - likely as agent
  profiles; the shipped selection is deliberately global (the pill sits next to Run and must
  always describe what Run will do).

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
- Chat scoped to a node sends messages only to that node's agent.
- Provider health and permission states render correctly for each combination.
