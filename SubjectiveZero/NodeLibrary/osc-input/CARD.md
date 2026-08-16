# OSC Input — `osc-input`

A phone/tablet OSC app (TouchOSC, Lemur, …) — or any program on the network — as live control
values: the **wifi controller**. The **source** node of a control pipeline over the network:
fader on the phone → UDP/OSC → this node's float outputs → data edges into any float input. No
third-party library (OSC 1.0 decoded inline), no routing logic beyond the binding table.

- **Reuse:** `copy-as-is` — copy this folder's `Node.swift` + `node-contract.json`. Don't re-derive
  the listener/decoder boilerplate.
- **Same binding contract as `midi.macos`.** `mappings` holds a JSON array
  `[{"key": "/1/fader1", "port": "blur-radius", "min": 0, "max": 20, "label": "Blur radius"}]`;
  `key` is the OSC address (a message with several numeric args yields `/addr`, `/addr[1]`, …).
  Each row surfaces as a float output named `port` on the node INSTANCE's contract, emitting
  `min + (max - min) * value01` once that address has been seen. The node's code is mapping-generic
  — committing/removing a binding edits this JSON and the instance contract; `Node.swift` never
  changes and never needs a rebuild.
- **Learn:** `lastEvent` (float2 `[seq, value01]`) + `lastKey` (string, the address) — the same
  learn signal as MIDI, so the host's `binding_*` tools and the controller card work unchanged.
- **Inputs (live):** `port` — the UDP port to listen on (default 8000, TouchOSC's default); a
  change relistens. `mappings` — the binding table (parsed once per edit).
- **Discovery:** advertised over Bonjour as `_osc._udp` under the Mac's name, so controller apps
  list it; otherwise point the app at the Mac's IP + port. Values: floats as sent (TouchOSC sends
  0…1), ints clamped 0…1, T/F as 1/0; bundles are unpacked.
- **Card:** the shared controller card — Learn button, one strip per binding.
- **Hot-reload safe:** `teardown()` cancels the listener before the module unloads; `setPaused`
  stops it with the transport.
- **Scope:** receive only (no OSC output), numeric/bool arguments only (strings/blobs skipped),
  no address-pattern matching (`*`, `?`) — a binding matches one address exactly.
