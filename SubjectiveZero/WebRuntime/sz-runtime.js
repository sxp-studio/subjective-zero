// sz-runtime.js: the page-side engine of a web project. It mirrors the Mac scheduler frame for frame:
// nodes run in the topological order the app sends, every texture port is a pooled render target keyed
// "<node>:<port>" at the canvas's own pixel size (the graph fills the viewport, as on the Mac), data
// edges route by the source port's declared type, and the endpoint target is drawn onto the canvas.
// Nodes are ES modules loaded with import(url); the app bumps the
// url's ?v= to hot-reload one. Transport is window.sz (transport-wk.js here, a boot payload in an
// exported page). Every ctx accessor keeps the Swift kit's name, so the same audit reads both.
import * as THREE from "three";

THREE.ColorManagement.enabled = false;

const canvas = document.getElementById("sz-canvas");
const renderer = new THREE.WebGLRenderer({ canvas, antialias: false, alpha: false, powerPreference: "high-performance" });
renderer.outputColorSpace = THREE.LinearSRGBColorSpace;
renderer.autoClear = false;
renderer.setClearColor(0x000000, 1);
const gl = renderer.getContext();

const state = {
  width: 1280, height: 720,
  order: [], nodes: new Map(), connections: [], endpoint: null,
  values: new Map(), strings: new Map(),
  paused: false, frameIndex: 0, time: 0, lastNow: null,
  errorsDirty: false,
};
const sizeVec = new THREE.Vector2();
const targets = new Map();          // "<node>:<port>" -> WebGLRenderTarget, the texture pool
let currentNode = null;             // the node whose update is running (shader errors land on it)
let chain = Promise.resolve();      // ops apply one at a time, in arrival order

// MARK: - The texture pool

function makeTarget() {
  return new THREE.WebGLRenderTarget(state.width, state.height, {
    format: THREE.RGBAFormat, type: THREE.UnsignedByteType,
    minFilter: THREE.LinearFilter, magFilter: THREE.LinearFilter,
    depthBuffer: false, stencilBuffer: false, generateMipmaps: false,
  });
}

function target(key) {
  let rt = targets.get(key);
  if (!rt) { rt = makeTarget(); targets.set(key, rt); }
  return rt;
}

// The render size follows the canvas: every pooled target is rebuilt and every node reseeded.
function resize(width, height) {
  width = Math.max(1, Math.round(width));
  height = Math.max(1, Math.round(height));
  if (width === state.width && height === state.height) { return; }
  state.width = width; state.height = height;
  for (const rt of targets.values()) { rt.dispose(); }
  targets.clear();
  for (const node of state.nodes.values()) { seedOutputs(node); }
}

function fitCanvas() {
  const dpr = window.devicePixelRatio || 1;
  const w = Math.max(1, Math.floor(window.innerWidth)), h = Math.max(1, Math.floor(window.innerHeight));
  renderer.setPixelRatio(dpr);
  renderer.setSize(w, h, false);
  resize(w * dpr, h * dpr);
}
window.addEventListener("resize", fitCanvas);
fitCanvas();

// MARK: - The full-screen pass (ctx.shaderPass and the present blit)

const passScene = new THREE.Scene();
const passCamera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
const passMesh = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), null);
passMesh.frustumCulled = false;
passScene.add(passMesh);
const PASS_VERTEX = "in vec3 position;\nin vec2 uv;\nout vec2 vUv;\nvoid main() { vUv = uv; gl_Position = vec4(position.xy, 0.0, 1.0); }";
const PASS_PRELUDE = "precision highp float;\nprecision highp int;\nin vec2 vUv;\nuniform vec2 uResolution;\nuniform float uTime;\nout vec4 fragColor;\n";

function uniformValue(value) {
  if (value instanceof THREE.Texture) { return value; }
  if (typeof value === "boolean") { return value ? 1 : 0; }
  if (typeof value === "number") { return value; }
  if (Array.isArray(value) || ArrayBuffer.isView(value)) { return Array.from(value, Number); }
  return value;
}

function passMaterial(source) {
  return new THREE.RawShaderMaterial({
    glslVersion: THREE.GLSL3,
    vertexShader: PASS_VERTEX,
    fragmentShader: PASS_PRELUDE + source,
    uniforms: { uResolution: { value: [state.width, state.height] }, uTime: { value: 0 } },
    depthTest: false, depthWrite: false,
  });
}

// Compile the fragment stage once with the raw context: three.js checks its programs lazily and on a
// later frame, which is too late for the gate. Returns the info log, or null when it compiles.
function fragmentError(fragmentSource) {
  const shader = gl.createShader(gl.FRAGMENT_SHADER);
  gl.shaderSource(shader, "#version 300 es\n" + fragmentSource);
  gl.compileShader(shader);
  const ok = gl.getShaderParameter(shader, gl.COMPILE_STATUS);
  const log = ok ? null : (gl.getShaderInfoLog(shader) || "unknown shader error").trim();
  gl.deleteShader(shader);
  return log;
}

// `into` is the render target to draw into (ctx.outputTexture(port)); a port name is accepted too.
function shaderPass(node, source, uniforms, into) {
  const rt = typeof into === "string" ? node.outputs[into] : into;
  if (!rt) { return; }
  let material = node.passes.get(source);
  if (material === null) { return; }   // known broken: reported already, nothing to draw
  if (!material) {
    const log = fragmentError(PASS_PRELUDE + source);
    if (log) {
      node.shaderError = "shader failed to compile: " + log;
      node.passes.set(source, null);
      return;
    }
    material = passMaterial(source);
    for (const k of Object.keys(uniforms || {})) { material.uniforms[k] = { value: uniformValue(uniforms[k]) }; }
    node.passes.set(source, material);
  }
  const u = material.uniforms;
  u.uResolution.value = [state.width, state.height];
  u.uTime.value = state.time;
  for (const k of Object.keys(uniforms || {})) {
    if (u[k]) { u[k].value = uniformValue(uniforms[k]); } else { u[k] = { value: uniformValue(uniforms[k]) }; }
  }
  passMesh.material = material;
  renderer.setRenderTarget(rt);
  renderer.render(passScene, passCamera);
}

// alpha forced to 1 like the Mac present: a node writing alpha 0 must not black out the picture
const blitMaterial = passMaterial("uniform sampler2D uTex;\nvoid main() { fragColor = vec4(texture(uTex, vUv).rgb, 1.0); }");
blitMaterial.uniforms.uTex = { value: null };

renderer.debug.onShaderError = (glc, program, vertexShader, fragmentShader) => {
  const log = (glc.getShaderInfoLog(fragmentShader) || glc.getShaderInfoLog(vertexShader) || "shader failed to compile").trim();
  if (currentNode) { currentNode.shaderError = "shader failed to compile: " + log; }
  console.error("sz: shader error", log);
};

// MARK: - Nodes

function describe(e) {
  if (!e) { return "unknown error"; }
  const name = e.name || "Error", message = e.message || String(e);
  const line = typeof e.line === "number" ? " (line " + e.line + ")" : "";
  return name + ": " + message + line;
}

function newNode(id, contract) {
  const node = {
    id, contract: contract || { inputs: [], outputs: [] }, sourceURL: null, instance: null, ctx: null,
    loadError: null, shaderError: null, reportedError: null, published: null,
    passes: new Map(), inputs: {}, outputs: {}, values: {}, strings: {}, outputValues: {}, outputStrings: {},
    inbound: [], copiesValues: false, emitsValues: false,   // resolved once per load, see wire()
  };
  node.ctx = makeCtx(node);
  return node;
}

function makeCtx(node) {
  return {
    three: THREE, renderer, gl,
    width: state.width, height: state.height, frameIndex: 0, time: 0,
    inputTexture: (port) => node.inputs[port] ?? null,
    outputTexture: (port) => node.outputs[port] ?? null,
    inputFloat: (port) => { const v = node.values[port]; return v && v.length ? v[0] : null; },
    inputFloats: (port) => node.values[port] ? Array.from(node.values[port]) : null,
    inputBool: (port) => { const v = node.values[port]; return v && v.length ? v[0] !== 0 : null; },
    inputString: (port) => node.strings[port] ?? null,
    inputFloatArray: (port) => node.values[port] ? Float32Array.from(node.values[port]) : null,
    setOutputFloat: (port, x) => { node.outputValues[port] = [Number(x)]; },
    setOutputFloats: (port, arr) => { node.outputValues[port] = Array.from(arr, Number); },
    setOutputString: (port, s) => { node.outputStrings[port] = String(s); },
    reportError: (m) => { node.reportedError = String(m).slice(0, 512); },
    shaderPass: (source, uniforms, into) => shaderPass(node, source, uniforms, into),
  };
}

function syncCtx(node) {
  node.ctx.width = state.width; node.ctx.height = state.height;
  node.ctx.frameIndex = state.frameIndex; node.ctx.time = state.time;
}

function teardown(node) {
  if (node.instance && typeof node.instance.teardown === "function") {
    try { node.instance.teardown(); } catch (e) { console.error("sz: teardown failed", e); }
  }
  node.instance = null;
  for (const m of node.passes.values()) { if (m) { m.dispose(); } }
  node.passes.clear();
}

async function loadInstance(node, sourceURL) {
  teardown(node);
  node.loadError = null; node.shaderError = null; node.reportedError = null;
  node.sourceURL = sourceURL;
  try {
    const mod = await import(sourceURL);
    const Cls = mod.default;
    if (typeof Cls !== "function") { throw new Error("Node.js must `export default class Node`"); }
    const instance = new Cls();
    syncCtx(node);
    seedOutputs(node);
    currentNode = node;
    try { if (typeof instance.setup === "function") { instance.setup(node.ctx); } }
    finally { currentNode = null; renderer.setRenderTarget(null); }
    if (node.shaderError) { throw new Error(node.shaderError); }
    node.instance = instance;
    if (state.paused && typeof instance.setPaused === "function") { instance.setPaused(true); }
  } catch (e) {
    node.instance = null;
    node.loadError = describe(e);
    window.sz.post({ channel: "loadError", id: node.id, message: node.loadError });
  }
}

// MARK: - The frame

function seedOutputs(node) {
  node.outputs = {};
  for (const port of node.contract.outputs || []) {
    if (port.type === "texture") { node.outputs[port.name] = target(node.id + ":" + port.name); }
  }
}

function sourcePortType(ref) {
  const node = state.nodes.get(ref.node);
  const port = node && (node.contract.outputs || []).find((p) => p.name === ref.port);
  return port ? port.type : null;
}

// Resolve what a frame needs once per load: each node's inbound edges with the channel their source
// port routes on, whether it reads any by-value edge (then its value maps are copied per frame, else
// read in place), and whether it emits values at all.
function wire() {
  for (const node of state.nodes.values()) {
    node.inbound = [];
    for (const c of state.connections) {
      if (c.to.node !== node.id) { continue; }
      const type = sourcePortType(c.from);
      const channel = type === "texture" ? "texture" : (type === "string" || type === "enum") ? "string" : "float";
      node.inbound.push({ port: c.to.port, key: c.from.node + ":" + c.from.port, channel });
    }
    node.copiesValues = node.inbound.some((e) => e.channel !== "texture");
    node.emitsValues = (node.contract.outputs || []).some((p) => p.type !== "texture");
    seedOutputs(node);
  }
}

const EMPTY = Object.freeze({});

function encode() {
  const valueOutputs = new Map(), stringOutputs = new Map();
  for (const id of state.order) {
    const node = state.nodes.get(id);
    if (!node || !node.instance) { continue; }
    const values = state.values.get(id) || EMPTY, strings = state.strings.get(id) || EMPTY;
    node.values = node.copiesValues ? Object.assign({}, values) : values;
    node.strings = node.copiesValues ? Object.assign({}, strings) : strings;
    if (node.emitsValues) { node.outputValues = {}; node.outputStrings = {}; }
    node.reportedError = null;
    if (node.inbound.length) {
      node.inputs = {};
      for (const e of node.inbound) {
        if (e.channel === "texture") {
          const rt = targets.get(e.key);
          if (rt) { node.inputs[e.port] = rt.texture; }
        } else if (e.channel === "string") {
          if (stringOutputs.has(e.key)) { node.strings[e.port] = stringOutputs.get(e.key); }
        } else if (valueOutputs.has(e.key)) {
          node.values[e.port] = valueOutputs.get(e.key);
        }
      }
    }
    syncCtx(node);
    currentNode = node;
    try { node.instance.update(node.ctx); }
    catch (e) { node.reportedError = describe(e); }
    finally { currentNode = null; renderer.setRenderTarget(null); }
    if (node.emitsValues) {
      for (const port in node.outputValues) { valueOutputs.set(id + ":" + port, node.outputValues[port]); }
      for (const port in node.outputStrings) { stringOutputs.set(id + ":" + port, node.outputStrings[port]); }
    }
  }
}

function aspectFit(sw, sh, dw, dh) {
  const scale = Math.min(dw / sw, dh / sh);
  const w = Math.max(1, Math.round(sw * scale)), h = Math.max(1, Math.round(sh * scale));
  return { x: Math.floor((dw - w) / 2), y: Math.floor((dh - h) / 2), w, h };
}

function present() {
  // CSS pixels: three.js scales viewports by the pixel ratio itself
  const size = renderer.getSize(sizeVec);
  renderer.setRenderTarget(null);
  renderer.setViewport(0, 0, size.x, size.y);
  renderer.clear(true, false, false);
  const ep = state.endpoint && targets.get(state.endpoint.node + ":" + state.endpoint.port);
  if (!ep) { return; }
  const fit = aspectFit(state.width, state.height, size.x, size.y);
  renderer.setViewport(fit.x, fit.y, fit.w, fit.h);
  blitMaterial.uniforms.uTex.value = ep.texture;
  passMesh.material = blitMaterial;
  renderer.render(passScene, passCamera);
  renderer.setViewport(0, 0, size.x, size.y);
}

// The whole set goes over only when some node's message changed (or a node left).
function publishErrors() {
  let changed = state.errorsDirty;
  for (const node of state.nodes.values()) {
    const message = node.loadError || node.shaderError || node.reportedError || null;
    if (message !== node.published) { node.published = message; changed = true; }
  }
  if (!changed) { return; }
  state.errorsDirty = false;
  const errors = {};
  for (const [id, node] of state.nodes) { if (node.published) { errors[id] = node.published; } }
  window.sz.post({ channel: "errors", nodeErrors: errors });
}

function frame(now) {
  requestAnimationFrame(frame);
  if (state.lastNow === null) { state.lastNow = now; }
  const dt = Math.min(0.25, (now - state.lastNow) / 1000);
  state.lastNow = now;
  if (!state.paused) {
    state.time += dt;
    encode();
    state.frameIndex += 1;
  }
  present();
  publishErrors();
}

// MARK: - Ops from the app

async function applyLoad(msg) {
  const keep = new Set((msg.nodes || []).map((n) => n.id));
  for (const [id, node] of state.nodes) {
    if (!keep.has(id)) {
      teardown(node);
      state.nodes.delete(id);
      state.errorsDirty = true;
      for (const key of Array.from(targets.keys())) {
        if (key.startsWith(id + ":")) { targets.get(key).dispose(); targets.delete(key); }
      }
    }
  }
  state.order = msg.order || [];
  state.connections = msg.connections || [];
  state.endpoint = msg.endpoint || null;
  state.values = new Map(Object.entries(msg.values || {}));
  state.strings = new Map(Object.entries(msg.strings || {}));
  for (const n of msg.nodes || []) {
    let node = state.nodes.get(n.id);
    if (!node) { node = newNode(n.id, n.contract); state.nodes.set(n.id, node); }
    node.contract = n.contract || node.contract;
    if (n.sourceURL && n.sourceURL !== node.sourceURL) { await loadInstance(node, n.sourceURL); }
  }
  wire();
}

async function applyReload(msg) {
  const node = state.nodes.get(msg.id);
  if (!node) { return; }
  await loadInstance(node, msg.sourceURL);
}

function setPaused(paused) {
  if (state.paused === paused) { return; }
  state.paused = paused;
  for (const node of state.nodes.values()) {
    if (node.instance && typeof node.instance.setPaused === "function") {
      try { node.instance.setPaused(paused); } catch (e) { console.error("sz: setPaused failed", e); }
    }
  }
}

// The compile check: import the staged module, construct it, run setup and a few updates against
// scratch targets seeded from the contract defaults. A throw, a shader that will not compile, or a
// missing default export is a failure with the message the agent needs; a reportError is not (a node
// with no upstream texture says why it drew nothing on every frame).
async function check(msg) {
  const node = newNode("check", msg.contract);
  let ok = true, errors = "";
  try {
    const mod = await import(msg.sourceURL);
    const Cls = mod.default;
    if (typeof Cls !== "function") { throw new Error("Node.js must `export default class Node`"); }
    const instance = new Cls();
    if (typeof instance.update !== "function") { throw new Error("Node must define update(ctx)"); }
    syncCtx(node);
    seedOutputs(node);
    // blank textures on every declared texture input, so an effect that skips the frame without an
    // upstream picture still reaches its shader and the shader gets compiled here
    for (const port of node.contract.inputs || []) {
      if (port.type === "texture") { node.inputs[port.name] = target("check-in:" + port.name).texture; }
    }
    node.values = Object.assign({}, msg.values || {});
    node.strings = Object.assign({}, msg.strings || {});
    currentNode = node;
    try { if (typeof instance.setup === "function") { instance.setup(node.ctx); } }
    finally { currentNode = null; renderer.setRenderTarget(null); }
    // three.js reports a shader that will not compile on a later render, so one update is not enough
    for (let i = 0; i < 12 && !node.shaderError; i += 1) {
      currentNode = node;
      try { instance.update(node.ctx); }
      finally { currentNode = null; renderer.setRenderTarget(null); }
      await new Promise((resolve) => requestAnimationFrame(resolve));
    }
    if (node.shaderError) { throw new Error(node.shaderError); }
    node.instance = instance;
  } catch (e) {
    ok = false;
    errors = describe(e);
  }
  teardown(node);
  for (const key of Array.from(targets.keys())) {
    if (key.startsWith("check:") || key.startsWith("check-in:")) { targets.get(key).dispose(); targets.delete(key); }
  }
  window.sz.post({ channel: "check", token: msg.token, ok, errors });
}

function enqueue(fn) {
  chain = chain.then(fn).catch((e) => console.error("sz: op failed", e));
}

window.sz.onMessage((msg) => {
  switch (msg.op) {
    case "load": enqueue(() => applyLoad(msg)); break;
    case "reload": enqueue(() => applyReload(msg)); break;
    case "check": enqueue(() => check(msg)); break;
    case "setInputs": {
      for (const [id, ports] of Object.entries(msg.floats || {})) {
        state.values.set(id, Object.assign(state.values.get(id) || {}, ports));
      }
      for (const [id, ports] of Object.entries(msg.strings || {})) {
        state.strings.set(id, Object.assign(state.strings.get(id) || {}, ports));
      }
      break;
    }
    case "clearInput": {
      const v = state.values.get(msg.id); if (v) { delete v[msg.port]; }
      const s = state.strings.get(msg.id); if (s) { delete s[msg.port]; }
      break;
    }
    case "setEndpoint": state.endpoint = msg.endpoint || null; break;
    case "setPaused": setPaused(!!msg.paused); break;
    case "resetTimeline": state.time = 0; state.frameIndex = 0; break;
    default: console.warn("sz: unknown op", msg.op);
  }
});

if (window.sz.boot) { enqueue(() => applyLoad(window.sz.boot)); }
requestAnimationFrame(frame);
window.sz.post({ channel: "ready" });
