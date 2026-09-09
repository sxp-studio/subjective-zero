# Grid Warp — `grid-warp`

Projection mapping onto a surface that is not flat: a cylinder, a corner of a room, a stack of boxes,
a stretched cloth. The input is pulled over a 4×4 net of control points and everything outside the
mesh is black, so the rest of the projector's throw stays dark. `corner-pin` is the four-corner case
of the same idea and is exact for a flat rectangle; reach for this one when a quad will not sit.
Ships a **custom card** (`Card.swift`): the region between the header and the port rows shows the
live output with sixteen draggable points and the mesh drawn through them.

- **Reuse:** `copy-as-is`. Pure GPU, no device, no permissions.
- **Implementation:** MESH render template, not a sampled one — a quad has a closed-form inverse and
  a mesh does not, so this draws the surface as geometry rather than mapping each output pixel back.
  The vertex stage walks a 32×32 subdivision from `vertex_id` with no vertex buffer (6144 vertices),
  and places each vertex with a **clamped Catmull-Rom bicubic** over the sixteen points: interpolate
  along each row, then between the four results. Clamped means the end tangents come from a phantom
  neighbour reflected through the edge point, so the surface passes through all sixteen points rather
  than only the middle cell. The fragment stage samples the source at the vertex's regular `(u, v)`
  with `clamp_to_edge`. The points cross as 128 bytes via `setVertexBytes`.
- **Knobs:** `p00`…`p33` (float2 each, row-major, `p00` top-left, normalized output space, y-down).
  Defaults are the flat grid at thirds, so an untouched node is a passthrough. Wire any of them to
  drive a point from the graph — the card greys that handle out.
- **The card:** `Card.swift` reads `state.backdrop` (where the host draws the output thumbnail under
  the card, in card-body points) and places each point at `backdrop.origin + point × backdrop.size`.
  A drag streams `state.live(port, [x, y])` per tick and commits ONCE on release (`state.commit`) —
  the value persists as the port's default like any slider. Points clamp to −0.25…1.25 so a surface
  can spill past the frame. The curves are drawn with the same Catmull-Rom the vertex stage uses, so
  the card shows where the image actually goes; a straight control net would disagree with it under
  any real warp. The ↺ button re-commits the flat sixteen. Contract `card` block:
  `{ "cols": 10, "rows": 8, "backdrop": "output", "plumbing": [ …all sixteen… ] }` — the points are
  `plumbing`: the card owns them, so their generated rows (and sockets) step aside while it shows;
  the `input` and `output` rows stay below the card (monitor toggle included).
- **Gotchas:** the input must be connected — nil input skips the frame (the card says so). Dragging a
  point past its neighbours folds the mesh over itself, which is a valid surface and renders as one:
  usually not what you meant, and the drawn curves are how you see it. The subdivision is fixed at
  32×32, so a violently pulled mesh shows faceting before it shows anything else wrong. For a real
  projector: pop the viewport out, green-button it fullscreen on the projector, then pull the points
  until the surface lands — corners first, edges second, middle last.
- **Web:** no `Node.js` yet. The shader is portable; the card is SwiftUI and is not.
