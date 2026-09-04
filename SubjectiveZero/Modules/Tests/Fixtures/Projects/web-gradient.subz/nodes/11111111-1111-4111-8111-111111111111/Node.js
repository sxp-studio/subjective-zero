export default class Node {
  setup(ctx) {}
  update(ctx) {
    const out = ctx.outputTexture("output");
    if (!out) return;
    ctx.inputString("type"); ctx.inputFloats("colorA"); ctx.inputFloats("colorB"); ctx.inputFloat("angle"); ctx.inputFloats("center"); ctx.inputFloat("scale");
  }
}
