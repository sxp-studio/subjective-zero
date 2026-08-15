<!-- brief pin; never edit by hand; re-record deliberately: SZ_RECORD_BRIEF_PINS=1 swift test --filter SZBriefPinTests -->
The built-in node library, by category. Each line: what the node does, its typed I/O, and whether its
source drops in unchanged (`copy-as-is`) or is only worth reading (`reference-only`).

A node is a reference because it does YOUR node's job. A similar name, or the same port shape, is not that.
If nothing here does it, write the node yourself — that is the ordinary outcome, not a failed search.

## Sources
- `camera.macos` — the live camera


For a node that really does the job: `agent_library_card { "node": "<id>" }` for its gotchas and setup
caveats, then `agent_library_source { "node": "<id>" }` for its `Node.swift`.
