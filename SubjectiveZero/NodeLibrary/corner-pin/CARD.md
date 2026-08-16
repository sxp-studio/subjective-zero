# Corner Pin — `corner-pin`

Projection mapping in one node: warps the input onto a quadrilateral whose four corners you place —
the physical surface (wall, box face, screen) you're projecting onto. Outside the quad is black, so
the rest of the projector's throw stays dark. Ships a **custom card** (`Card.swift`): the region
between the header and the port rows shows the live output with four draggable corner handles.

- **Reuse:** `copy-as-is`. Pure GPU, no device, no permissions. Cross-platform (`any`).
- **Implementation:** SAMPLED render template with an **inverse homography**. `update()` builds the
  square→quad projective map on the CPU (Heckbert's square-to-quad, affine shortcut for
  parallelograms), inverts it, and pushes the 3×3 as `float3x3` via `setFragmentBytes`. The fragment
  shader maps each output pixel back into source space (`s = hinv · (uv, 1)`, `src = s.xy / s.z`),
  returns black outside 0…1 or behind the camera (`s.z ≤ 0`), and samples with `clamp_to_zero`. A
  degenerate quad keeps the last valid matrix instead of rendering NaNs.
- **Knobs:** `tl` `tr` `br` `bl` (float2 each, normalized output space, y-down; defaults are the
  full frame → identity). Wire any of them to drive a corner from the graph — the card greys that
  handle out.
- **The card:** `Card.swift` reads `state.backdrop` (where the host draws the output thumbnail under
  the card, in card-body points) and places each handle at `backdrop.origin + corner × backdrop.size`.
  A drag streams `state.live(port, [x, y])` per tick and commits ONCE on release
  (`state.commit`) — the value persists as the port's default like any slider. Corners clamp to
  −0.25…1.25 so a surface can spill past the frame. The ↺ button re-commits the four home corners.
  Contract `card` block: `{ "cols": 10, "rows": 8, "backdrop": "output", "plumbing": ["tl","tr","br","bl"] }`
  — the four corners are `plumbing`: the card owns them, so their generated rows (and sockets) step
  aside while it shows; the `input` and `output` rows stay below the card (monitor toggle included).
  The card region follows the render aspect automatically.
- **Gotchas:** the input must be connected — nil input skips the frame (the card says so). Corner
  order is clockwise from top-left; crossing two corners (a bow-tie) is a valid projective map and
  renders as one — usually not what you meant. For a real projector: pop the viewport out, green-
  button it fullscreen on the projector, then drag the corners on the card until the surface lands.
