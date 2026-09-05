# Node runtime ABI (web): what `Node.js` may use

Your `Node.js` is an ES module the host page loads and drives. It is drawn with three.js over WebGL2
into a texture the page owns; the page hands you everything through one `ctx` object. Do **NOT**
`import` anything (three.js arrives on `ctx.three`; a file with a top-level `import` is refused by the
gate), and never touch the page's canvas or `document`.

## The shape your file must define

```js
export default class Node {
  setup(ctx) { /* build materials, scenes, cameras ONCE here */ }
  update(ctx) { /* per frame: read every input live, draw into ctx.outputTexture("output") */ }
  // teardown() {}            optional; dispose what you allocated
  // setPaused(paused) {}     optional; stop anything running on its own (a video, a timer)
}
```

## The injected `ctx`

One object per node, refreshed every frame; the same object is passed to `setup` and `update`.

```js
ctx.three          // the THREE namespace (three.js 0.185, pinned per project)
ctx.renderer       // the shared THREE.WebGLRenderer
ctx.gl             // the WebGL2RenderingContext, for raw WebGL2 (call ctx.renderer.resetState() after raw GL calls)
ctx.width, ctx.height        // the viewport's pixel size; every texture is this size, and it can change
ctx.frameIndex, ctx.time     // frame counter; seconds, pausable

ctx.inputTexture(port)       // THREE.Texture | null       declared texture input (null until an upstream frame lands)
ctx.outputTexture(port)      // THREE.WebGLRenderTarget | null   declared texture output you must fill (RGBA8, viewport size)
ctx.inputFloat(port)         // number | null              float input (e.g. a slider)
ctx.inputBool(port)          // boolean | null             bool input (the card's toggle)
ctx.inputFloats(port)        // number[] | null            float2/3/4, colorRGB/RGBA, float3x3/4x4
ctx.inputString(port)        // string | null              enum (chosen value) / string input
ctx.inputFloatArray(port)    // Float32Array | null        connected `floatArray` input, any length (audio samples / spectrum)
ctx.setOutputFloat(port, number)     // emit a single-float NON-texture output
ctx.setOutputFloats(port, number[])  // emit a float/vector NON-texture output
ctx.setOutputString(port, string)    // emit an enum/string output
ctx.reportError(message)             // say why you are producing nothing (see below)
ctx.shaderPass(fragmentSource, uniforms, ctx.outputTexture(port))   // a full-screen fragment pass into an output target (see below)
```

Render into an output target with `ctx.renderer.setRenderTarget(rt); ctx.renderer.render(scene, camera)`.
The runtime resets the target after your `update`; never call `setRenderTarget(null)` yourself.

**Own a video element or a timer? Stop it in `setPaused(paused)`.** Pause stops the frames, not your
resource, and `update()` isn't called while paused, so this is your only signal. Resume from your own
state and don't block. A *rewind* needs nothing here: it always arrives with a frame.

### `ctx.shaderPass(fragmentSource, uniforms, outputTarget)`

The one convenience: a full-screen pass with a GLSL ES 3.00 fragment shader. The runtime supplies the
vertex stage and declares for you: `in vec2 vUv;` (0..1, origin bottom-left as in WebGL),
`uniform vec2 uResolution;`, `uniform float uTime;`, and `out vec4 fragColor;`. You write the rest of the
fragment source WITHOUT a `#version` line or `precision` line (the runtime prepends `#version 300 es` and
`precision highp float;`). `uniforms` is `{ name: value }` where value is a number (float), an array of
2/3/4 numbers (vec2/3/4), an array of 9 or 16 (mat3/mat4), a boolean (bool), or a `THREE.Texture`
(sampler2D); declare each as `uniform <type> name;` in your source. The material is cached per node per
source string, so building it in `setup` is unnecessary; call `shaderPass` from `update` each frame.
The third argument is the target to draw into, normally `ctx.outputTexture("output")` written out in full
so the port audit sees the write. Returns nothing; the result lands in that target.

## Saying why you produced nothing

A node that cannot do its job renders black, and black looks exactly like "no file chosen yet", like
"still loading", and like "working as asked". `ctx.reportError("…")` breaks that tie: the host shows the
message on the node and hands it to whoever reads the graph. Use it for the fault **only your code can
see**: a shader that would not compile, a resource that opened and would not decode. Not for a missing or
unreadable file: the host checks that from outside and would say it twice.

**It describes the frame it is called on, so call it on every frame the fault holds.** The first frame you
stay quiet, the message is gone. That is what clears a fixed node with nothing to remember, and why there
is no `clearError`.

So do not report from inside your reload gate: that gate runs on one frame, and the message would flash
for a sixtieth of a second and vanish. Discover the fault in the gate, then report it outside:

```js
export default class Node {
  loadedPath = null;
  loadError = null;                     // discovered once in the gate, re-reported every frame

  update(ctx) {
    const path = ctx.inputString("path") ?? "";
    if (path !== this.loadedPath) {     // the usual gate: you only attempt the load when the path moves
      this.loadedPath = path;
      this.loadError = null;            // a new path is a clean slate
      try { this.load(path); } catch (e) { this.loadError = `could not decode ${path}: ${e.message}`; }
    }
    if (this.loadError) ctx.reportError(this.loadError);   // outside the gate, so it is said every frame
  }
}
```

One message per node (the last call of a frame wins), so say it in one sentence and name the file.
Reporting every frame costs nothing: the host notices only when the message changes. Truncated past 512
bytes.

## Rules

- **Textures are RGBA8 at the viewport's size**, which follows the tile (or the browser window in an
  exported page) and is the take's frame size while the user records, so read `ctx.width` /
  `ctx.height` every frame rather than caching them. The host
  allocates every node target; you cannot choose the format. Build materials, scenes and cameras ONCE
  in `setup()`; do per-frame work in `update()`.
- **Read every declared scalar/string input LIVE inside `update(ctx)` every frame**: never hardcode it,
  or the user's editor control becomes a dead knob.
- **No `import` statements at all.** three.js arrives on `ctx.three`. Never touch the page's canvas or
  `document`. Never `fetch`, no network, no timers that draw.
- **Single-threaded: never block.** No synchronous XHR, no busy loops.
- **Emit a NON-texture output with `ctx.setOutputFloats("port", values)`** (or `setOutputFloat` for one
  value), every frame, for any `float`/vector/color/matrix/`bool` output you declared. When that output is
  connected by a `.data` edge, the runtime delivers it to the downstream node's input, exactly like on the
  Mac; read it there with `inputFloats` / `inputFloat`. A texture output still uses `outputTexture`; use a
  `texture` output for anything that must be **displayed**.
- **Emit an `enum`/`string` output with `ctx.setOutputString("port", value)`**: it flows across a `.data`
  edge into a downstream input of the same type (read there with `inputString`; the connect guard requires
  equal types: string to string, enum to enum).
- **A `floatArray` output/input carries a variable-length series** (audio PCM samples, an FFT spectrum,
  any numeric series too big for `float4x4`) over that same connected value channel. Emit it with
  `ctx.setOutputFloats("port", array)`; read it downstream with `ctx.inputFloatArray("port")`, which grows
  to any length (`inputFloats` stays capped at 16, for scalars/vectors). Like `texture`, it is
  **connection-only**: no editor default, so always wire it.
- **Dispose what you create** in `teardown()` if it holds GPU memory: materials, geometries, render
  targets you allocated.

## A worked example: the spectrum

One node exercising most of the ABI. Not a template to copy: a map of what is available. Its contract
declares a texture input, four editor-controlled inputs of different types, a displayed texture output
AND a non-texture `float` output.

```json
{
  "title": "Contrast", "sfSymbol": "circle.righthalf.filled",
  "summary": "Scales contrast about a pivot; also reports the frame's average luma.",
  "inputs": [
    { "name": "input",  "type": "texture" },
    { "name": "amount", "type": "float", "default": { "type": "float", "value": 1.0 },
      "ui": { "kind": "slider", "min": 0.0, "max": 4.0, "step": 0.05 } },
    { "name": "bypass", "type": "bool",  "default": { "type": "bool", "value": false },
      "ui": { "kind": "toggle" } },
    { "name": "mode",   "type": "enum",  "default": { "type": "enum", "value": "rgb" },
      "ui": { "kind": "dropdown" }, "options": [["RGB", "rgb"], ["Luma", "luma"]] },
    { "name": "pivot",  "type": "colorRGB", "default": { "type": "colorRGB", "value": [0.5, 0.5, 0.5] },
      "ui": { "kind": "colorWell" } }
  ],
  "outputs": [
    { "name": "output", "type": "texture", "display": true },
    { "name": "luma",   "type": "float" }
  ]
}
```

A **source** node simply declares `"inputs": []`; nothing else changes. `display: true` marks the ONE
texture output that feeds the viewport; a node with a single texture output should set it.

```js
const CONTRAST = `
uniform sampler2D uInput;
uniform float uAmount;
uniform bool uLuma;
uniform vec3 uPivot;
void main() {
  vec4 c = texture(uInput, vUv);
  vec3 p = uLuma ? vec3(dot(uPivot, vec3(0.2126, 0.7152, 0.0722))) : uPivot;
  fragColor = vec4((c.rgb - p) * uAmount + p, c.a);
}`;

export default class Node {
  setup(ctx) {
    // Nothing to build: shaderPass caches its material per source string.
  }

  update(ctx) {
    // Read EVERY declared input live, every frame: a hardcoded value is a dead knob in the editor.
    const amount = ctx.inputFloat("amount") ?? 1.0;            // float
    const bypass = ctx.inputBool("bypass") ?? false;           // bool
    const mode   = ctx.inputString("mode") ?? "rgb";           // enum -> the chosen value
    const pivot  = ctx.inputFloats("pivot") ?? [0.5, 0.5, 0.5]; // colorRGB / vectors / matrices

    const src = ctx.inputTexture("input");   // null until an upstream frame lands: skip, don't crash
    if (!src || bypass) return;

    // A full-screen pass into the `output` target; the runtime resets the render target afterwards.
    ctx.shaderPass(CONTRAST, { uInput: src, uAmount: amount, uLuma: mode === "luma", uPivot: pivot },
                   ctx.outputTexture("output"));

    // A NON-texture output is emitted every frame; a `.data` edge carries it to a downstream input.
    ctx.setOutputFloat("luma", 0.5);
  }
}
```

A scene node draws with three.js instead of a fragment pass. Build the scene ONCE, render it into the
output target every frame:

```js
export default class Node {
  setup(ctx) {
    const T = ctx.three;
    this.scene = new T.Scene();
    this.camera = new T.PerspectiveCamera(50, ctx.width / ctx.height, 0.1, 100);
    this.camera.position.z = 3;
    this.cube = new T.Mesh(new T.BoxGeometry(), new T.MeshStandardMaterial({ color: 0xff8800 }));
    const light = new T.DirectionalLight(0xffffff, 2);
    light.position.set(2, 3, 5);
    this.scene.add(this.cube, light, new T.AmbientLight(0x404040));
  }

  update(ctx) {
    const rt = ctx.outputTexture("output");
    if (!rt) return;
    this.cube.rotation.set(ctx.time * 0.7, ctx.time, 0);
    ctx.renderer.setRenderTarget(rt);
    ctx.renderer.render(this.scene, this.camera);
  }

  teardown() { this.cube.geometry.dispose(); this.cube.material.dispose(); }
}
```

## One thread

`update()` runs once per frame on the page's only thread: never block in it (no synchronous XHR, no busy
loops, no decoding a whole file in one go). Slow work goes to an async task that hands its result over
through your own state; `update` reads the latest value and never waits.

The contract that declares these ports has its own schema: see
`agent_docs_read { "topic": "node-contract" }`.
