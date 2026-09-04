// Browser camera: getUserMedia into a <video>, a three.js VideoTexture, one pass into the output.
// `mirror` flips horizontally; `aspectFit` true fills the frame (crop), false letterboxes. While the
// stream warms up the node draws nothing and says nothing; a refused or missing camera is reported.

const SHADER = `
uniform sampler2D uTex;
uniform vec2 uScale;
uniform float uMirror;
void main() {
  vec2 uv = (vUv - 0.5) * uScale + 0.5;
  if (uMirror > 0.5) uv.x = 1.0 - uv.x;
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) { fragColor = vec4(0.0, 0.0, 0.0, 1.0); return; }
  fragColor = vec4(texture(uTex, uv).rgb, 1.0);
}`;

export default class Node {
  setup(ctx) {
    this.video = document.createElement("video");
    this.video.muted = true;
    this.video.playsInline = true;
    this.texture = null;
    this.stream = null;
    this.failure = null;
    navigator.mediaDevices.getUserMedia({ video: { width: { ideal: ctx.width }, height: { ideal: ctx.height } }, audio: false })
      .then((stream) => {
        this.stream = stream;
        this.video.srcObject = stream;
        return this.video.play();
      })
      .then(() => {
        this.texture = new ctx.three.VideoTexture(this.video);
        this.texture.colorSpace = ctx.three.NoColorSpace;
      })
      .catch((e) => { this.failure = "camera: " + (e && e.message ? e.message : String(e)); });
  }

  update(ctx) {
    if (this.failure) { ctx.reportError(this.failure); return; }
    if (!this.texture || this.video.readyState < 2 || !this.video.videoWidth) return;
    const mirror = ctx.inputBool("mirror") ?? true;
    const fill = ctx.inputBool("aspectFit") ?? true;
    const va = this.video.videoWidth / this.video.videoHeight, oa = ctx.width / ctx.height;
    // fill samples a centred crop of the video; fit shows all of it with black bars
    let scale;
    if (fill) scale = va > oa ? [oa / va, 1] : [1, va / oa];
    else scale = va > oa ? [1, va / oa] : [oa / va, 1];
    ctx.shaderPass(SHADER, { uTex: this.texture, uScale: scale, uMirror: mirror ? 1 : 0 }, ctx.outputTexture("texture"));
  }

  teardown() {
    if (this.stream) { for (const track of this.stream.getTracks()) track.stop(); }
    if (this.texture) this.texture.dispose();
    this.video.srcObject = null;
    this.stream = null;
    this.texture = null;
  }
}
