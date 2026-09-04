export default class Node {
  setup(ctx) {}
  update(ctx) {
    const out = ctx.outputTexture("output");
    if (!out) return;
    ctx.inputTexture("input"); ctx.inputFloat("amount");
  }
}
