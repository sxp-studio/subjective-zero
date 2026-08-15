<!-- brief pin; never edit by hand; re-record deliberately: SZ_RECORD_BRIEF_PINS=1 swift test --filter SZBriefPinTests -->
Live graph state, as of this message. This and `agent_read_graph` are authoritative — trust them over any description of the graph earlier in our conversation, which may predate a run.

Nodes:
- `11111111-1111-4111-8111-111111111111` "MacBook Camera" — generated, contract[in: mirror:bool, aspectFit:bool, camera:enum; out: texture:texture] — prompt: "Live Mac camera feed delivered as a texture output — the canonical macOS camera source node."
- `22222222-2222-4222-8222-222222222222` "Grayscale Effect" — prompt, no contract yet — prompt: "Convert the incoming camera texture to grayscale (per-pixel luminance)."

Flow edges (drawing intent — realize each into typed data wiring; laying the data edge resolves the arrow): 11111111 → 22222222
Data edges: 11111111.texture → 22222222.input
Render endpoint (blitted to the viewport): 22222222.output

---

now dim the highlights a little