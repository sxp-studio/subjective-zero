# Gaussian Blur — `gaussian-blur`

A **separable** 9-tap Gaussian blur — the go-to softening / bloom-prep node. Two cheap 1D passes
(horizontal then vertical) approximate a full 2D blur at a fraction of the taps.

- **Reuse:** `reference-only`. The separable two-pass + lazy-intermediate pattern is the reusable part;
  clone it for any separable filter (box blur, depth-of-field, unsharp mask).
- **Implementation:** SAMPLED render template. One render pipeline (`v_main`/`f_main`) reused for both
  passes. A lazy intermediate texture sized to the output (`[.renderTarget,.shaderRead]`, `.bgra8Unorm`,
  `.shared`) is recreated only when the output size changes. Pass 1: input → temp, direction (1,0);
  pass 2: temp → out, direction (0,1). Uniforms per pass: `direction`, `texelSize` (1/size), `radius`.
- **Knobs:** `radius` (0–20, default 3) — read live via `ctx.inputFloat("radius") ?? 3`. The 9 weights
  form a symmetric bell and are normalized in-shader, so tuning `radius` only changes spread, not gain.
- **Gotchas:** the input must be connected — nil input skips the frame. Very large radii reveal the
  9-tap ceiling (banding); chain two instances for a heavier blur rather than pushing `radius` past 20.
