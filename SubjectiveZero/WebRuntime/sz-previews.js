// sz-previews.js: node thumbnails for the editor's cards. The app names the watched "<node>:<port>"
// keys; at most ~15 times a second, after the picture is presented, every watched target is drawn
// small into ONE fixed-size atlas, the atlas is read back without stalling (readRenderTargetPixelsAsync,
// one in flight), and the bytes go to the app as one POST body per tick. Constant bytes per tick
// whatever the count: more thumbs mean smaller tiles, never more traffic. The tile shader flips rows
// and swizzles to BGRA, so the readback is already in the order the app's surfaces want. Loaded by
// index.html only: the exported page has no editor and never carries this file.
import * as THREE from "three";
import { engine } from "./sz-runtime.js";

const ATLAS = { width: 1024, height: 576 };
const MIN_INTERVAL_MS = 1000 / 15;
const READBACK_TIMEOUT_MS = 2000;   // a readback that never settles (context lost mid-fence) must not wedge the stream

const { renderer, targets, state, passScene, passCamera, passMesh } = engine;
const gl = renderer.getContext();
const atlas = new THREE.WebGLRenderTarget(ATLAS.width, ATLAS.height, {
  format: THREE.RGBAFormat, type: THREE.UnsignedByteType,
  minFilter: THREE.NearestFilter, magFilter: THREE.NearestFilter,
  depthBuffer: false, stencilBuffer: false, generateMipmaps: false,
});
atlas.scissorTest = true;
const tileMaterial = engine.passMaterial(
  "uniform sampler2D uTex;\nvoid main() { vec4 c = texture(uTex, vec2(vUv.x, 1.0 - vUv.y)); fragColor = vec4(c.b, c.g, c.r, 1.0); }");
tileMaterial.uniforms.uTex = { value: null };

// Built now, not on the first watch: a program's and a framebuffer's first use costs a whole frame.
(function warm() {
  const blank = new THREE.DataTexture(new Uint8Array(4), 1, 1);
  blank.needsUpdate = true;
  atlas.viewport.set(0, 0, 1, 1);
  atlas.scissor.set(0, 0, 1, 1);
  tileMaterial.uniforms.uTex.value = blank;
  passMesh.material = tileMaterial;
  renderer.setRenderTarget(atlas);
  renderer.render(passScene, passCamera);
  renderer.setRenderTarget(null);
  blank.dispose();
})();

const watch = {
  keys: [], cells: [], maxDimension: 0, layout: 0, seq: 0,
  renderWidth: 0, renderHeight: 0,   // the size the cells were laid out for
  dirty: false,                      // a new layout still owes one pass even while paused
  inFlight: false, issuedAt: 0, lastPass: 0,
  buffer: new Uint8Array(ATLAS.width * ATLAS.height * 4),
};

// MARK: - Layout

// Cells in the readback's own coordinates: WebGL reads rows bottom-up, so a cell's `y` is its first row
// in the bytes the app receives, and drawing at that GL y with the sampler flipped makes each tile
// arrive top-down. A square-ish grid, each tile aspect-fit to the render size and capped at
// `maxDimension` on the long edge.
function layoutCells(count, maxDimension) {
  const cols = Math.max(1, Math.ceil(Math.sqrt(count))), rows = Math.max(1, Math.ceil(count / cols));
  const cellW = Math.floor(ATLAS.width / cols), cellH = Math.floor(ATLAS.height / rows);
  const aspect = state.width / Math.max(1, state.height);
  let w = Math.min(cellW, Math.floor(cellH * aspect)), h = Math.floor(w / aspect);
  const scale = Math.min(1, maxDimension / Math.max(w, h));
  w = Math.max(1, Math.floor(w * scale)); h = Math.max(1, Math.floor(h * scale));
  const cells = [];
  for (let i = 0; i < count; i++) {
    const col = i % cols, row = Math.floor(i / cols);
    cells.push({ x: col * cellW, y: row * cellH, w, h });
  }
  return cells;
}

function setWatched(keys, maxDimension) {
  watch.keys = keys.slice();
  watch.maxDimension = maxDimension;
  watch.renderWidth = state.width; watch.renderHeight = state.height;
  watch.cells = layoutCells(keys.length, maxDimension);
  watch.layout += 1;
  watch.dirty = true;
  // stale tiles from the previous layout must not leak into a new cell's margins
  atlas.viewport.set(0, 0, ATLAS.width, ATLAS.height);
  atlas.scissor.set(0, 0, ATLAS.width, ATLAS.height);
  renderer.setRenderTarget(atlas);
  renderer.clear(true, false, false);
  renderer.setRenderTarget(null);
  window.sz.post({ channel: "previewLayout", layout: watch.layout, width: ATLAS.width, height: ATLAS.height,
                   keys: watch.keys, cells: watch.cells });
}

// MARK: - The pass

function pass(now) {
  if (!watch.keys.length) { return; }
  if (watch.inFlight && now - watch.issuedAt > READBACK_TIMEOUT_MS) { watch.inFlight = false; }
  if (watch.inFlight || now - watch.lastPass < MIN_INTERVAL_MS) { return; }
  if (state.paused && !watch.dirty) { return; }   // nothing changes while paused
  if (state.width !== watch.renderWidth || state.height !== watch.renderHeight) { setWatched(watch.keys, watch.maxDimension); }
  watch.lastPass = now;
  watch.dirty = false;
  let drawn = 0;
  for (let i = 0; i < watch.keys.length; i++) {
    const rt = targets.get(watch.keys[i]);
    if (!rt) { continue; }
    const c = watch.cells[i];
    atlas.viewport.set(c.x, c.y, c.w, c.h);
    atlas.scissor.set(c.x, c.y, c.w, c.h);
    tileMaterial.uniforms.uTex.value = rt.texture;
    passMesh.material = tileMaterial;
    renderer.setRenderTarget(atlas);
    renderer.render(passScene, passCamera);
    drawn += 1;
  }
  renderer.setRenderTarget(null);
  if (!drawn) { return; }
  watch.inFlight = true;
  watch.issuedAt = now;
  const layout = watch.layout, seq = ++watch.seq;
  renderer.readRenderTargetPixelsAsync(atlas, 0, 0, ATLAS.width, ATLAS.height, watch.buffer)
    .then(() => deliver(layout, seq))
    .catch((e) => console.error("sz: preview readback failed", e))
    .finally(() => { watch.inFlight = false; });
  // three leaves its pixel-pack buffer bound while it waits on the fence; a node's own readPixels would fail
  gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
}

function deliver(layout, seq) {
  if (layout !== watch.layout) { return; }   // the set changed under the readback
  // fetch copies a BufferSource body at call time, so the buffer is free for the next pass
  fetch("subz://app/previews?layout=" + layout + "&seq=" + seq, { method: "POST", body: watch.buffer })
    .catch((e) => console.error("sz: preview post failed", e));
}

renderer.domElement.addEventListener("webglcontextlost", () => { watch.inFlight = false; });
engine.ops.set("setWatchedPreviews", (msg) => setWatched(msg.keys || [], msg.maxDimension));
engine.afterPresent.push(pass);
