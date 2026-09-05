// sz-record.js: the record tap of a web project, the page half. While a take rolls, every frame
// encode() produced is drawn cropped into ONE output-size target with the same row flip and BGRA
// swizzle the thumbnails use, read back without stalling (a ring of buffers, several readbacks in
// flight), and POSTed to the app as raw bytes stamped with the engine time: subz://app/record. The
// app's recorder decides the file (PTS, decimation, audio, container); the page only pre-applies the
// recorder's own decimation rule so a 30 fps take on a 60 or 120 Hz page posts half the bytes. The
// take also holds the render size, so a small tile records at full resolution. Loaded by index.html
// only: the exported page never carries this file.
import * as THREE from "three";
import { engine } from "./sz-runtime.js";

const RING = 3;                     // readbacks in flight at most; a full ring drops the frame (counted)
const DRAIN_TIMEOUT_MS = 2000;      // a readback that never settles must not wedge the stop

const { renderer, targets, state, passScene, passCamera, passMesh } = engine;
const gl = renderer.getContext();
// uCrop = (x, y, w, h) of the source region in GL texture coordinates; the 1 - vUv.y flips rows so the
// readback arrives top-down, and the swizzle lands BGRA as the app's pixel buffers want.
const cropMaterial = engine.passMaterial(
  "uniform sampler2D uTex;\nuniform vec4 uCrop;\n"
  + "void main() { vec2 uv = uCrop.xy + vec2(vUv.x, 1.0 - vUv.y) * uCrop.zw; vec4 c = texture(uTex, uv); fragColor = vec4(c.b, c.g, c.r, 1.0); }");
cropMaterial.uniforms.uTex = { value: null };
cropMaterial.uniforms.uCrop = { value: [0, 0, 1, 1] };

let take = null;

// MARK: - Start / stop

function start(msg) {
  if (take) { stop(); }
  const width = Math.max(1, msg.width | 0), height = Math.max(1, msg.height | 0);
  const crop = msg.crop || { x: 0, y: 0, w: 1, h: 1 };
  engine.setRenderSize({ width: msg.renderWidth || width, height: msg.renderHeight || height });
  const target = new THREE.WebGLRenderTarget(width, height, {
    format: THREE.RGBAFormat, type: THREE.UnsignedByteType,
    minFilter: THREE.LinearFilter, magFilter: THREE.LinearFilter,
    depthBuffer: false, stencilBuffer: false, generateMipmaps: false,
  });
  const free = [];
  for (let i = 0; i < RING; i++) { free.push(new Uint8Array(width * height * 4)); }
  take = {
    token: msg.take, width, height, target, free,
    frameStep: 1 / Math.max(1, msg.fps || 60),
    // picture-normalized, top-left origin (as the Mac crop); GL v runs bottom-up
    cropGL: [crop.x, 1 - crop.y - crop.h, crop.w, crop.h],
    lastSent: null, seq: 0, sent: 0, dropped: 0, inFlight: 0,
  };
}

function stop() {
  const t = take;
  if (!t) { return; }
  take = null;
  engine.setRenderSize(null);
  const began = performance.now();
  const settle = () => {
    if (t.inFlight > 0 && performance.now() - began < DRAIN_TIMEOUT_MS) { setTimeout(settle, 10); return; }
    t.target.dispose();
    window.sz.post({ channel: "record", event: "stopped", take: t.token, sent: t.sent, dropped: t.dropped });
  };
  settle();
}

// MARK: - The pass

function pass() {
  const t = take;
  if (!t) { return; }
  const time = state.time;
  if (time === t.lastSent) { return; }   // paused, or no encode this frame
  if (t.lastSent !== null) {
    const delta = time - t.lastSent;
    if (delta > 0 && delta < 0.75 * t.frameStep) { return; }   // the recorder's decimation rule
  }
  const ep = state.endpoint && targets.get(state.endpoint.node + ":" + state.endpoint.port);
  if (!ep) { return; }
  const buffer = t.free.pop();
  if (!buffer) { t.dropped += 1; return; }   // ring full: the recorder's pool-starved drop
  t.lastSent = time;

  cropMaterial.uniforms.uTex.value = ep.texture;
  cropMaterial.uniforms.uCrop.value = t.cropGL;
  passMesh.material = cropMaterial;
  renderer.setRenderTarget(t.target);
  renderer.render(passScene, passCamera);
  renderer.setRenderTarget(null);

  const seq = t.seq++;
  t.inFlight += 1;
  renderer.readRenderTargetPixelsAsync(t.target, 0, 0, t.width, t.height, buffer)
    .then(() => {
      // fetch copies a BufferSource body at call time, so the buffer is free again right after
      fetch("subz://app/record?take=" + t.token + "&seq=" + seq + "&t=" + time.toFixed(6) + "&dropped=" + t.dropped,
            { method: "POST", body: buffer })
        .catch((e) => console.error("sz: record post failed", e));
      t.sent += 1;
    })
    .catch((e) => { t.dropped += 1; console.error("sz: record readback failed", e); })
    .finally(() => { t.inFlight -= 1; t.free.push(buffer); });
  // three leaves its pixel-pack buffer bound while it waits on the fence; a node's own readPixels would fail
  gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
}

// The graphics context is gone: the take cannot go on, the page lets go of the render size and says so.
renderer.domElement.addEventListener("webglcontextlost", () => {
  const t = take;
  if (!t) { return; }
  take = null;
  engine.setRenderSize(null);
  t.target.dispose();
  window.sz.post({ channel: "record", event: "failed", take: t.token, message: "the page lost its graphics context" });
});
engine.ops.set("startRecord", start);
engine.ops.set("stopRecord", stop);
engine.afterPresent.push(pass);
