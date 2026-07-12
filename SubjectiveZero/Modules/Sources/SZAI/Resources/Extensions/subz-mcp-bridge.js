// SPDX-License-Identifier: AGPL-3.0-only
// SubjectiveZero → pi MCP bridge. Staged by SZPiProvider.prepare() into <workdir>/.subz/ with the
// turn's port templated in, and loaded with an explicit `--extension` path — do not edit; it is
// rewritten before every spawn.
//
// pi deliberately ships no MCP support (extensions are its seam), so this file speaks the host's
// wire protocol directly: newline-delimited MCP JSON-RPC over TCP to 127.0.0.1:<port> — exactly
// what `nc` bridges for the other CLIs, minus the extra process (the extension already runs in
// Node). Zero npm dependencies.
//
// The factory is async and pi awaits it before the session starts, so every host tool is
// registered before the first turn's tool list reaches the model. Any failure here (connect,
// handshake, registration) THROWS, which pi reports as a failed extension load and exits before
// running the turn — a run that silently lost its host tools would look alive while it wasn't.

import net from "node:net";

const PORT = __SUBZ_MCP_PORT__;
const HANDSHAKE_TIMEOUT_MS = 10_000;

export default async function (pi) {
  const rpc = await connect(PORT);

  await rpc.request("initialize", {
    protocolVersion: "2024-11-05",
    clientInfo: { name: "subz-pi-bridge", version: "1" },
    capabilities: {},
  });
  rpc.notify("notifications/initialized", {});
  const { tools } = await rpc.request("tools/list", {});
  if (!Array.isArray(tools)) throw new Error("subz-mcp-bridge: tools/list returned no tools");

  for (const tool of tools) {
    pi.registerTool({
      name: tool.name,
      label: tool.name,
      description: tool.description ?? "",
      // Raw JSON Schema — accepted by pi.registerTool (verified pi 0.80.6).
      parameters: tool.inputSchema ?? { type: "object", properties: {} },
      async execute(_toolCallId, params) {
        try {
          const result = await rpc.request("tools/call", { name: tool.name, arguments: params ?? {} });
          return {
            content: toPiContent(result?.content),
            isError: result?.isError === true,
            details: {},
          };
        } catch (error) {
          return {
            content: [{ type: "text", text: `subz-mcp-bridge: ${error?.message ?? error}` }],
            isError: true,
            details: {},
          };
        }
      },
    });
  }
}

function toPiContent(content) {
  if (!Array.isArray(content) || content.length === 0) {
    return [{ type: "text", text: "" }];
  }
  return content.map((block) => {
    if (block?.type === "text") return { type: "text", text: block.text ?? "" };
    if (block?.type === "image") return { type: "image", data: block.data ?? "", mimeType: block.mimeType ?? "image/png" };
    return { type: "text", text: JSON.stringify(block) };
  });
}

// Minimal newline-delimited JSON-RPC 2.0 client over one TCP connection, kept open for the whole
// session (tool executes flow over it). Handshake calls carry a timeout; tools/call does not — a
// host tool (compile, run) may legitimately take long, and the turn's own timeout bounds it.
function connect(port) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, "127.0.0.1");
    const pending = new Map();
    let nextId = 1;
    let buffer = "";

    const failAll = (error) => {
      for (const [, entry] of pending) {
        clearTimeout(entry.timer);
        entry.reject(error);
      }
      pending.clear();
    };

    socket.setNoDelay(true);
    // Hold Node's event loop only while a request is awaiting its response. Always-referenced,
    // the idle socket keeps the process alive past the finished turn until the host's timeout
    // kills it (observed: exit 124 on an otherwise successful print-mode turn); never-referenced,
    // the loop could drain mid-tools/call and exit under a pending host tool.
    const updateRef = () => { if (pending.size > 0) socket.ref(); else socket.unref(); };
    socket.once("error", (error) => {
      failAll(error);
      reject(new Error(`subz-mcp-bridge: cannot reach the SubjectiveZero MCP listener on 127.0.0.1:${port} (${error.message})`));
    });
    socket.on("close", () => failAll(new Error("subz-mcp-bridge: MCP connection closed")));
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        if (!line.trim()) continue;
        let message;
        try { message = JSON.parse(line); } catch { continue; }
        const entry = pending.get(message.id);
        if (!entry) continue;
        pending.delete(message.id);
        updateRef();
        clearTimeout(entry.timer);
        if (message.error) entry.reject(new Error(message.error.message ?? "MCP error"));
        else entry.resolve(message.result);
      }
    });

    socket.once("connect", () => {
      resolve({
        request(method, params) {
          return new Promise((resolveCall, rejectCall) => {
            const id = nextId++;
            const handshake = method !== "tools/call";
            const timer = handshake
              ? setTimeout(() => {
                  pending.delete(id);
                  updateRef();
                  rejectCall(new Error(`subz-mcp-bridge: ${method} timed out`));
                }, HANDSHAKE_TIMEOUT_MS)
              : undefined;
            pending.set(id, { resolve: resolveCall, reject: rejectCall, timer });
            updateRef();
            socket.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
          });
        },
        notify(method, params) {
          socket.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
        },
      });
    });
  });
}
