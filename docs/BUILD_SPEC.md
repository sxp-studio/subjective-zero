# Build Spec

The **concrete** layer under the narrative docs. Where the others explain *why*, this pins down the
*what to build*: the canonical types, the frozen node ABI, the V1 MCP command list, and a per-package
file manifest. It is the contract a builder fills in - opening this with [ARCHITECTURE.md](ARCHITECTURE.md)
should be enough to know exactly which files to create for each milestone.

Swift below is **normative in shape** (names, fields, signatures), not in every line.

---

## SZCore - model, store, edit ops, seam protocols

Pure Swift. `Codable`, value types, **no macOS/Metal imports.** This is the only package the others
share, so it is also where the seam protocols live **once introduced** - they are added just-in-time
per milestone, not all at M0 ([ARCHITECTURE.md](ARCHITECTURE.md#the-host-seam)).

### Model types (canonical, `Codable`)

```swift
struct App: Codable {                 // app-level prefs
    var panelLayout: PanelLayout
    var windowSize: Size
    var theme: Theme
    var openProject: ProjectRef?
}

struct Project: Codable {
    var name: String
    var author: String
    var viewport: Viewport            // zoom, translation, fps, resolution, pixelFormat
    var graph: Graph
}

struct Graph: Codable {
    var nodes: [Node]                 // referenced by id
    var connections: [Connection]     // edges live on the graph, not the node
}

struct Node: Codable, Identifiable {
    let id: NodeID                     // stable across prompt -> generated transition
    var kind: NodeKind                 // .prompt | .generated
    var title: String
    var sfSymbol: String
    var prompt: String?                // for prompt / pre-gen nodes
    var contract: NodeContract?        // nil until a coding agent drafts it
    var position: Point
}

enum NodeKind: String, Codable { case prompt, generated }

struct Connection: Codable, Identifiable {
    let id: ConnectionID
    var from: PortRef                  // { node: NodeID, port: String }
    var to: PortRef
    var kind: ConnectionKind           // .flow | .data
}

enum ConnectionKind: String, Codable { case flow, data }
```

`NodeID` / `ConnectionID` are `UUID`-backed typed wrappers. `Point`/`Size`/`Viewport` are plain
`Codable` value structs, free of any UI/runtime-coupled fields.

### Node contract (`NodeContract` ⇄ `node-contract.json`)

The single source of truth for a node's UI and the runtime's I/O enforcement.

```swift
struct NodeContract: Codable {
    var title: String
    var sfSymbol: String
    var summary: String
    var inputs: [Port]
    var outputs: [Port]
}

struct Port: Codable {
    var name: String
    var type: PortType
    var ui: PortUI?                    // control hint when unconnected (slider/file-picker/…)
    var def: PortValue?               // default value for an unconnected input ("default")
    var display: Bool?                // texture outputs only: render-endpoint candidate
}

enum PortType: String, Codable {
    case float, float2, float3, float4
    case float3x3, float4x4
    case colorRGB, colorRGBA
    case texture                      // MTLTexture handle (by id at runtime)
    case bool, enumeration = "enum", string, event
}
```

Port-type semantics and conversion rules: [GRAPH_AND_NODES.md](GRAPH_AND_NODES.md). `string` carries
file paths (with a file-picker `ui`); there is no separate `file` type.

### Store, edit ops, checkpoints

```swift
@MainActor @Observable final class SZStore {   // the single source of truth (as built)
    private(set) var project: SZProject?
    // mutate(_:) is the ONLY mutation entry point - one atomic reassignment of the value-type
    // project; every named edit op below funnels through it.
    func mutate(_ transform: (inout SZProject) -> Void)
}

// Named edit ops (SZStore+GraphEdits) - the mutation surface UI, MCP, and host share:
//   addPromptNode · connect · disconnect · updateNode · removeNode · moveNode(s)
//   setInputDefault · setRenderEndpoint · splitNode · mergeNodes

// Undo (M8) is ARTIFACT-LEVEL CHECKPOINTS, not a serializable command log ([STATE.md](STATE.md)):
struct SZCheckpoint {                          // one undo step (shape; lands at M8)
    var project: SZProject                     // everything but sources lives in the value type
    var sources: [SZNodeID: String]            // each node's Node.swift at the checkpoint
}
// Restore = set project + write sources + SZProjectIO.save + runtime.loadProject.
```

Transient churn (status, busy/lock flags, live agent progress - `SZNodeAgentState`) is
**observable state but never checkpointed** - it must not touch the undo stack
([STATE.md](STATE.md)).

### Seam protocols (illustrative shapes - added only when *earned*)

> **Seams are earned, not scheduled.** The clean boundary is the **package graph**, not these
> protocols; and the host imports every sibling concretely, so it mediates most cross-module calls
> without a protocol. A seam is added only when (a) a real *second implementation* needs a swap point,
> or (b) a cross-sibling call genuinely can't be mediated by the host or `SZStore`. **M1 shipped its
> entire runtime/hot-reload/capture path with none** - `SZNodeCompiler`/`SZRenderer` proved unnecessary
> (the host calls the concrete `SZRuntime`; the viewport rides a MetalKit delegate). So the block below
> is *illustrative of likely shapes if/when earned*, not a list to build - several may never exist. See
> [ARCHITECTURE.md](ARCHITECTURE.md#the-host-seam). Names are normative in *shape*; the `SZ` prefix
> applies ([AGENTS.md](../AGENTS.md) guideline 1).

```swift
protocol HostBridge: AnyObject {            // the single sink for UI intents + MCP commands
    func dispatch(_ command: HostCommand) async throws -> HostResult
}

protocol NodeCompiler {                      // implemented by SZRuntime
    func compile(stagedNode: NodeID) async -> CompileOutcome      // swiftc -> loadable module
}

protocol Renderer {                          // implemented by SZRuntime
    func setGraph(_ graph: Graph)
    func setDisplay(node: NodeID, port: String)
    func captureFrame() async -> ImageBytes  // real framebuffer readback (agent_view_frame)
}

protocol Orchestrator {                      // implemented by SZAI (hardcoded Swift in V1)
    func run(director graph: Graph) async    // contract-plan -> parallel coding -> reconcile
    func message(node: NodeID, _ text: String) async
}

protocol ProviderRegistry {                  // implemented by SZAI
    func providers() -> [ProviderHealth]
    func startSession(_ config: SessionConfig) async throws -> SZSession
}
```

`HostCommand`/`HostResult` are the typed in-process form of the MCP surface below; the MCP server (in
the host) decodes JSON-RPC into `HostCommand`s and calls `dispatch`. Texture handles in `Renderer`
are opaque ids - the concrete `MTLTexture` never crosses into SZCore.

---

## SZRuntime - node ABI, values, build/load

Owns Metal and all GPU resources; implements `NodeCompiler` + `Renderer`. Capabilities are
primitives-only ([RUNTIME.md](RUNTIME.md#scope-primitives-only--capabilities-live-in-nodes)).

### Frozen node ABI (host-owned, stable across all nodes)

```swift
public protocol SZNode {
    init()
    func setup(_ ctx: SZSetupContext)    // (re)load: build pipelines, declare persistent resources
    func update(_ ctx: SZFrameContext)   // once per frame
    func teardown()                      // optional; default no-op
}
```

```swift
public struct SZFrameContext {
    // viewport primitives - the ceiling of what the runtime exposes:
    var width: Int; var height: Int; var pixelFormat: PixelFormat
    var frameIndex: Int; var time: Double; var deltaTime: Double
    var device: MTLDevice; var commandBuffer: MTLCommandBuffer
    // declared I/O (runtime enforces against the contract):
    func inputTexture(_ port: String) -> MTLTexture?
    func inputValue(_ port: String) -> PortValue
    func outputTexture(_ port: String) -> MTLTexture     // allocated by the asset manager
    func write(_ value: PortValue, to port: String)
    // resources that survive hot reload (e.g. feedback) are requested by declared id:
    func persistentTexture(id: String, desc: TextureDesc) -> MTLTexture
}
```

`SZSetupContext` exposes the device + the asset manager for one-time pipeline/resource creation.
**Value set** mirrors `PortType`: `float/2/3/4`, `float3x3/4x4`, `colorRGB/RGBA`, `texture` (by id),
`bool`, `enum`, `string`, `event`. Textures live in the asset manager and are referenced by id;
everything else is a small value passed by the scheduler.

This `setup()`+`update()` lifecycle is what buys pipeline caching ([RUNTIME.md](RUNTIME.md)).

### Build & load pipeline

`stage Node.swift → swiftc (with host RuntimeSupport.swift) → sign → copy to a disposable path →
dlopen → conform to SZNode → setup()`. On reload: `teardown()` old, `dlclose`, swap. This toolchain
(~2000 LOC across build + load) is the single biggest subsystem - self-contained; get it right once.

---

## SZApp - the host: HostBridge + MCP server + composition root

Thin. Instantiates `Store`, the SZRuntime `NodeCompiler`/`Renderer`, and the SZAI
`Orchestrator`/`ProviderRegistry`; injects them; owns the window + run loop; implements `HostBridge`;
hosts the **MCP server**. It routes each command to a `Store` edit op or a
service call.

### V1 MCP command list (functional minimum + verify hooks)

The full target surface is in [MCP.md](MCP.md); **V1 ships exactly this set**. Prefixes: `ui_`
(mirrors a user action), `agent_` (orchestration/host ops), `debug_` (verify/operate).

| V1 command | Resolves to |
|---|---|
| `ui_add_prompt_node` / `ui_remove_node` / `ui_move_node` | `addNode`/`removeNode`/`moveNode` txn |
| `ui_connect` / `ui_disconnect` | `addConnection`/`removeConnection` txn |
| `ui_update_node` | `setNodeContract` + `setNodeTitleSymbol` txn (UI reflows) |
| `ui_set_input_default` | `setInputDefault` txn |
| `ui_toggle_display` | `toggleDisplay` txn + `Renderer.setDisplay` |
| `ui_run` / `ui_send_chat` | `Orchestrator.run` / `.message` |
| `agent_read_graph` / `agent_read_node` | read `Store` |
| `agent_apply_plan` | create/assign nodes (one txn) |
| `agent_write_node_staged` | stage contract + `Node.swift` |
| `agent_compile_node` | `NodeCompiler.compile` |
| `agent_report_status` | observable status (not a txn) |
| `agent_library_index` / `_card` / `_source` | read library files |
| `agent_view_frame` | `Renderer.captureFrame` (**real readback**) → inline image |
| `debug_get_build_errors` / `debug_snapshot_state` | diagnostics |

**Deferred past V1:** `ui_split_node`/`ui_merge_nodes` (land with the split/merge milestone),
`debug_record_session`/`debug_replay_session`, and exhaustive `ui_` completeness.

The MCP server itself (~1000 LOC) lives in the host, decoding JSON-RPC into `HostCommand`s and
calling `HostBridge.dispatch`.

---

## SZAI - providers, sessions, orchestration

```swift
protocol SZProvider {                          // one adapter per CLI
    var id: String { get }                      // "claude-code", "codex"
    func healthCheck() async -> ProviderHealth
    func capabilities() async -> ProviderCapabilities   // from a static manifest (AI_PROVIDERS.md)
    func startSession(_ config: SessionConfig) async throws -> SZSession
}

protocol SZSession {                            // a long-lived agent process
    func send(_ message: String) -> AsyncStream<AgentEvent>
    func teardown()
}
```

`Orchestrator` (V1) is **hardcoded Swift** implementing `contract-plan → parallel coding → reconcile`,
behind the seam in SZCore. **No behavior-tree JSON schema is specced or built in V1** - it is
prototyped first ([AGENT_ORCHESTRATION.md](AGENT_ORCHESTRATION.md)).

---

## Per-package file manifest (V1)

What each package ships at V1 - building is filling in this tree.

```
SZCore/
  Models.swift            App/Project/Graph/Node/Connection/Viewport
  Contract.swift          NodeContract, Port, PortType, PortValue, PortUI
  Store.swift             @Observable SZStore + change stream   (SZStore exists at M0)
  SZCheckpoint.swift      artifact-level checkpoint + undo stack (M8)
  (Seams.swift)           seam protocols added only when earned (see note) - none yet; M1 shipped seam-free
  JSON.swift              project.json / node-contract.json codecs

SZRuntime/
  SZNode.swift            ABI protocol + SZSetup/SZFrame context
  AssetManager.swift      MTLDevice/queue, texture pool, by-id handles
  Scheduler.swift         DAG topo-sort + per-frame execute + feedback node
  Toolchain.swift         swiftc build, sign, disposable copy, dlopen/swap
  Loader.swift            module load + SZNode conformance

SZApp/
  SZApp.swift             @main, window/scene, run loop
  Host.swift              composition root + HostBridge dispatch
  MCPServer.swift         JSON-RPC server (decodes -> HostCommand)
  MCP+UI.swift / MCP+Agent.swift / MCP+Debug.swift   command extensions

SZAI/
  Provider.swift          SZProvider/SZSession protocols
  ClaudeProvider.swift    claude code adapter
  Orchestrator.swift      hardcoded contract-plan -> parallel -> reconcile
  Prompts/                mustache templates

SZUI/
  ViewportPanel.swift     MTKView via NSViewRepresentable
  NodeEditor.swift        canvas, nodes (contract-derived), connections
  ChatPanel.swift  HUD.swift  Settings.swift

library/                  static node library (NODE_LIBRARY.md)
  index.json
  camera.macos/  { CARD.md, node-contract.json, Node.swift }

samples/                  debug-only project fixtures (loaded from disk, not in-code)
  grayscale-camera.subz/  project.json + nodes/<id>/{node-contract.json, Node.swift}   (the canonical demo)
```

The `samples/grayscale-camera.subz/` fixture (added at M2) is the canonical instance of the on-disk
project layout - load/save must round-trip it byte-stably (modulo formatting), and it doubles as the
reusable load → compile → render fixture for the closed-loop harness.

Exact Metal/library contents grow per milestone.
