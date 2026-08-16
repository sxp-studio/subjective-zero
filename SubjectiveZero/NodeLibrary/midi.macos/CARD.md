# MIDI Input — `midi.macos`

Hardware MIDI controllers as live control values. The **source** node of a physical-control
pipeline: knob → CoreMIDI → this node's float outputs → data edges into any float input. No
permission involved (CoreMIDI is not TCC-gated), no DSP, no routing logic beyond the binding table.

- **Reuse:** `copy-as-is` — copy this folder's `Node.swift` + `node-contract.json`. Don't re-derive
  the CoreMIDI client/port/connect boilerplate.
- **Bindings are data, not code.** The `mappings` input holds a JSON array
  `[{"key": "ch1/cc21", "port": "blur-radius", "min": 0, "max": 20, "label": "Blur radius"}]`.
  Each entry surfaces as a float output named `port` on the node INSTANCE's contract, emitting
  `min + (max - min) * cc/127` every frame once that controller has been seen. The node's code is
  mapping-generic — committing/removing a binding edits this JSON and the instance contract's
  output list; `Node.swift` never changes and never needs a rebuild. `key` is the wire identity
  `ch<1-16>/cc<0-127>` (channels 1-based as controllers label them).
- **Learn:** `lastEvent` (float2 `[seq, value01]`) + `lastKey` (string, the key above) — `seq`
  increments on every CC received, bound or not. An observer that snapshots `seq`, asks the user
  to wiggle a knob, and watches for the advance knows exactly which control the hand is on. The
  host's binding-learn layer (`binding_*` tools, the card's Learn button) is built on exactly this;
  any node with a `mappings` string input + `lastKey` string output is a binding source.
- **Card:** `Card.swift` — a Learn button, one strip per binding (label · key · live bar · ✕),
  the newest event's key. Mounted by default (the contract declares `card`).
- **Inputs (live):** `source` — dynamic dropdown of MIDI sources (by stable unique id; "All
  sources" default). Hot-plug and virtual sources are picked up via the CoreMIDI setup-change
  notification; selection switches reconnect live. `mappings` — the binding table (see above);
  parsed once per edit, not per frame.
- **Until a mapping's CC is first seen, its output is not emitted** — a connected target keeps its
  own default on project open instead of snapping to the mapping's `min` before the hardware
  says anything.
- **Hot-reload safe:** `teardown()` disposes the port and client **before** the module unloads, so
  no CoreMIDI callback can land in unloaded code.
- **Scope:** MIDI 1.0 channel-voice **CC only** (14-bit CC pairs, notes, pitch-bend, NRPN are out
  of scope). A binding matches one (channel, cc) pair exactly. USB/wired only — no network MIDI.
