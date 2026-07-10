# Runtime

**Package: SZRuntime.** A lightweight rendering engine. It owns Metal and all GPU resources,
compiles and hot-reloads node modules, and schedules + executes the graph each frame. Kept
deliberately lean and **general** - a node graph is a structured sequence of compute, **not a
pure VFX texture-filter pipeline**.

## Host responsibilities

SZRuntime owns the things nodes must not own:

- **Metal device & command queue.** One `MTLDevice` and command queue for the app.
- **Resource allocation.** All `MTLBuffer`/`MTLTexture` allocation goes through the runtime's
  **asset manager**. Output textures live there and are referenced by id, so the UI can display
  them and downstream nodes can read them.
- **Viewport context.** Resolution, pixel format, the current drawable, time/frame.
- **Permissions.** Camera, microphone, etc. - requested and held by the runtime, surfaced to UI.
- **Build & hot reload.** swiftc compilation of node source and safe module swapping.
- **Scheduling & execution.** Topologically order the DAG and run nodes per frame; handle
  per-node failure without taking down the graph.

Nodes never create a device/queue or allocate raw GPU memory themselves - they request resources
from the context.

## Scope: primitives only - capabilities live in nodes

The runtime is deliberately **small** and stays that way. Its context exposes a fixed, minimal set of
primitives - **drawable, pixel format, device + per-frame command buffer (including pinning an object
to the frame's GPU lifetime, `holdUntilFrameCompletes`), viewport size, time/frame, and texture/buffer
allocation** - and nothing more. That is the ceiling.

**No speculative capabilities are baked into the runtime.** There is no generic "video texture", media
pipeline, audio engine, or effect framework inside SZRuntime. Anything domain-specific is a **node** -
ideally one adapted from the [node library](NODE_LIBRARY.md), not a runtime feature:

- The **camera** is a *library node* (`camera.macos`), not a runtime capability. The host grants the
  camera permission and provides the capture lifecycle the node needs; the runtime just hands the node
  a texture to fill. Image/file/video sources are nodes too.
- This is what keeps the runtime general (a node graph is a structured sequence of compute, not a fixed
  VFX filter chain) **and** small enough to stay correct. When in doubt, push capability into a node.

## Node module shape

A node is a `Node.swift` compiled into an isolated module plus its `node-contract.json`
([GRAPH_AND_NODES.md](GRAPH_AND_NODES.md)). The Swift entry points are intentionally tiny so hot
reload is reliable and the contract between host and node is stable:

```swift
// Illustrative - the exact ABI is host-owned and stable across nodes.
protocol SZNode {
    init()
    func setup(_ context: SZSetupContext)      // called on (re)load / when the compiler changes things
    func update(_ context: SZFrameContext)     // called once per frame
    func teardown()                            // called on reload / removal
}
```

- **`setup()` / `teardown()`** bracket a module's life. They run on hot reload and whenever the
  graph compiler changes things (e.g. contract change, rewire).
- **`update(context)`** runs once per frame with the runtime context.
- The **exported ABI is host-owned and stable** - node source is generated/regenerated freely,
  but the shape it must conform to does not drift.

### Threading contract *(behavioral change, 2026-07-03 - pre-dating nodes were authored under a main-thread `update()`)*

The live viewport renders on a **dedicated render thread** (a display-link pump), not the main
thread, so the editor UI can never starve frames:

- **`update()` runs on the render thread**, every frame. Do NOT do blocking work in it (device I/O,
  session reconfiguration, file access) - a blocked `update()` drops viewport frames. Kick slow
  work to the node's own queue and hand results across with a thread-safe latest-value buffer
  (e.g. a lock-free triple buffer for streaming sources like a camera).
- **Pooled GPU resources are pinned via the ABI, not hand-rolled retention:** anything a pool can
  recycle while the GPU still reads it (a camera frame's `CVMetalTexture`/`CVPixelBuffer`) goes
  through `ctx.holdUntilFrameCompletes(…)` (ABI v6) - the runtime releases it after the frame's
  command buffer executes.
- **`setup()` / `teardown()` run on the main thread** (load/reload paths), serialized against
  frames - a frame never interleaves a half-swapped graph.
- **`dynamicOptions(for:)` may run CONCURRENTLY with `update()`** (it's called from the UI when a
  dropdown opens, off the render path, because enumerating devices can be slow). It must be safe
  to call while a frame renders: read shared node state through the same thread-safe handoff as
  above, or touch only framework-level state (e.g. an `AVCaptureDevice` discovery).

> **Why a lifecycle, not a flat entry point.** A single flat `render()` entry is simple, but it
> forces nodes to rebuild Metal pipeline state every frame (no pipeline caching). The **minimal
> lifecycle** avoids that: `setup()` builds pipelines / declares persistent resources **once**,
> `update()` runs per frame; `teardown()` is optional (default no-op). This is the smallest shape
> that buys pipeline caching while staying nearly as simple as a flat function.

### Reload-time state

Generated module state **resets across hot reload** in V1 (a node does not magically preserve
in-memory fields when its source is recompiled). Anything that must persist across reloads (e.g.
a feedback texture) is held by the runtime as a declared resource, not as a Swift field - so it
survives recompilation.

## Runtime context

`update()` receives a context that exposes only what a node legitimately needs:

- **Viewport:** resolution, pixel format, current drawable, frame index, time / delta-time.
- **Resources:** request/allocate `MTLTexture`/`MTLBuffer` from the asset manager by declared
  contract id; get the device and a command buffer/encoder for this frame.
- **Inputs:** typed values for each declared input (connected upstream output, or the user's
  default value when unconnected).
- **Outputs:** slots for each declared output the node must fill.

A node reads only its **declared** inputs and writes only its **declared** outputs - the runtime
enforces this against the contract, which keeps scheduling and inspection sound.

## Values & types (general, not VFX-only)

The runtime carries typed values so the graph can do more than image filtering. Built-in types
(mirrored by the contract + UI, see [GRAPH_AND_NODES.md](GRAPH_AND_NODES.md)):

`float` · `float2/3/4` · `float3x3/float4x4` · `texture` (`MTLTexture`) · `bool` · `enum`
(string-based) · `string` · `event` (a trigger; the receiving node gets a callback only when the
upstream node fires).

Textures are the only resource-heavy type and always live in the asset manager. The rest are
small value types passed by the scheduler.

## Scheduling

- The graph is a **strict DAG**. The scheduler topologically sorts nodes and executes them in
  dependency order each frame.
- **Flow vs data** connections are distinguished (see [GRAPH_AND_NODES.md](GRAPH_AND_NODES.md)):
  flow expresses intent/scheduling order; data carries typed runtime values. They are not always
  the same edge - preserve that distinction.
- **Feedback** (trails, persistence, anything needing last frame's output) is handled by a single
  explicit **feedback node**, not by cycles in the graph. The feedback node holds a
  runtime-owned texture that survives the frame boundary and hot reload. This keeps the scheduler
  a pure DAG and the runtime lean.
- **Render endpoint:** exactly one texture output is marked for display at a time (user-toggleable
  via the display icon). The runtime blits that texture to the viewport drawable.

## Build & hot reload

- Coding agents write `Node.swift` to a **staging** location ([STATE.md](STATE.md)).
- The runtime compiles staged source with **swiftc** into a loadable module, conforming to the
  host ABI.
- On success: `teardown()` the old module (if any), load the new one, `setup()`, resume the
  schedule. On failure: staging is discarded/kept for inspection; the live graph keeps running
  the previous good module; the error is surfaced as status.
- Hot reload is **per node** - recompiling one node does not rebuild the whole graph.

## Failure handling

- A node that throws/crashes during `update()` is isolated: the runtime marks it failed, skips it
  (passing through or zeroing its declared outputs), and keeps the rest of the graph rendering so
  the user/agent can see and fix it.
- Build, agent, and runtime logs are all available from the app - diagnostics are survival tools,
  not polish.

## Test scenarios

- Compile + load a trivial node, render a solid color to the viewport.
- Hot-reload a node's source while running; old module torn down, new one set up, no flicker of
  the rest of the graph.
- Feedback node accumulates across frames and survives a hot reload of an unrelated node.
- A node that fails to compile leaves the previously running graph intact.
- An `event` input fires a downstream callback exactly once per upstream trigger.
