// SPDX-License-Identifier: AGPL-3.0-only
// The `agent_*` MCP surface — what a coding agent reads + writes (docs/MCP.md). Read side: inspect the
// graph, a node's contract/prompt, and the library index. Write/compile side (step 5): stage a node's
// source + contract, compile-check it, promote-on-success (host copies staged→live + hot-reloads;
// live state untouched on failure — STATE.md), and report status.
import Foundation
import SZCore
import SZAI
import SZRuntime

extension SZHostBridge {
    nonisolated static var agentToolDefinitions: [[String: Any]] {
        [
            tool("agent_read_graph", "Return the full project graph (nodes with contracts, connections, render endpoint) as JSON."),
            tool("agent_read_node", "Return one node (title, kind, prompt, contract) as JSON.",
                 properties: ["node": ["type": "string", "description": "node id (UUID)"]]),
            tool("agent_library_index", "The built-in node library, grouped by category: one line per node saying what it does. Cheap — read it whole and decide for yourself whether any node does YOUR node's job. Nothing is ranked or filtered; a similar name is not a match."),
            tool("agent_library_card", "Read one library node's card (CARD.md) — reuse guidance, gotchas, and setup notes — to confirm or reject it as a reference without fetching full source.",
                 properties: ["node": ["type": "string", "description": "library node id (e.g. camera.macos)"]]),
            tool("agent_library_source", "Fetch one library node's full Node.swift source, to copy-as-is, adapt, or study before writing your own.",
                 properties: ["node": ["type": "string", "description": "library node id (e.g. camera.macos)"]]),
            tool("agent_write_node_staged", "Write a node's Node.swift (+ optional node-contract.json) to the project's .staging area. Does NOT touch live state.",
                 properties: [
                    "node": ["type": "string", "description": "node id (UUID)"],
                    "source": ["type": "string", "description": "the full Node.swift source"],
                    "contract": ["type": "object", "description": "the node-contract.json object (optional)"],
                 ]),
            tool("agent_compile_node", "Compile-check the staged Node.swift. On success, promote it (copy to live + hot-reload) and return {ok:true}. On failure, return {ok:false, errors} and leave live state untouched.",
                 properties: ["node": ["type": "string", "description": "node id (UUID)"]]),
            tool("agent_report_status", "Report a node's observable status (queued/coding/ok/needsInput/error + message).",
                 properties: [
                    "node": ["type": "string"], "status": ["type": "string"], "message": ["type": "string"],
                 ]),
            tool("agent_docs_index", "List the reference docs you can fetch (id, title, summary) — the canonical contract schema, the runtime ABI, etc. Cheap; read a topic's body only when you need it (e.g. before authoring a node-contract.json)."),
            tool("agent_docs_read", "Fetch one reference doc's full markdown by topic id (from agent_docs_index) — e.g. \"node-contract\" for the contract/ui/default schema, \"node-abi\" for the runtime ABI. Use this instead of guessing the schema.",
                 properties: ["topic": ["type": "string", "description": "a topic id from agent_docs_index, e.g. node-contract"]]),
            tool("agent_view_frame", "Capture what the live viewport is rendering and return it as an inline image so you can SEE your VFX result — composition, color, motion, artifacts. Pixel-perfect (real framebuffer readback), downscaled to fit the token budget (default 768px long edge; pass maxSize to change). Captures the CURRENT display endpoint (what's on screen) — use ui_toggle_display to change which node's output the viewport shows. Pair with debug_set_paused to freeze time and A/B an input.",
                 properties: ["maxSize": ["type": "integer", "description": "max long-edge px of the returned image (default 768, clamped 64–1280). Full render is 1280×800."]]),
        ]
    }

    /// Handle an image-returning `agent_*` call (result is an inline image, not text), or nil if `name`
    /// isn't ours. Kept separate from `handleAgentTool` because the return type differs.
    func handleImageTool(name: String, arguments: [String: Any]) throws -> SZMCPToolResult? {
        switch name {
        case "agent_view_frame": return try agentViewFrame(arguments)
        default: return nil
        }
    }

    /// Read back the current render endpoint (what the viewport displays), downscale to `maxSize`, and
    /// return it as an inline PNG the model can look at.
    private func agentViewFrame(_ arguments: [String: Any]) throws -> SZMCPToolResult {
        guard let frame = host.runtime?.captureFrame() else {
            throw SZMCPError.message("no frame rendered yet")
        }
        let maxDim = min(max(arguments.int("maxSize") ?? 768, 64), 1280)
        guard let png = frame.pngData(maxDimension: maxDim) else {
            throw SZMCPError.message("frame encode failed")
        }
        return .image(base64: png.base64EncodedString())
    }

    func handleAgentTool(name: String, arguments: [String: Any]) throws -> String? {
        switch name {
        case "agent_read_graph":         return try agentReadGraph()
        case "agent_read_node":          return try agentReadNode(arguments)
        case "agent_library_index":      return agentLibraryIndex()
        case "agent_library_card":       return try agentLibraryCard(arguments)
        case "agent_library_source":     return try agentLibrarySource(arguments)
        case "agent_write_node_staged":  return try agentWriteNodeStaged(arguments)
        case "agent_compile_node":       return try agentCompileNode(arguments)
        case "agent_report_status":      return try agentReportStatus(arguments)
        case "agent_docs_index":         return agentDocsIndex()
        case "agent_docs_read":          return try agentDocsRead(arguments)
        default: return nil
        }
    }

    private func agentDocsIndex() -> String {
        SZJSONRPC.encode(SZAgentDocs.topics.map { ["id": $0.id, "title": $0.title, "summary": $0.summary] })
    }

    private func agentDocsRead(_ arguments: [String: Any]) throws -> String {
        guard let topic = arguments.string("topic"), !topic.isEmpty else {
            throw SZMCPError.message("agent_docs_read needs `topic` (an id from agent_docs_index)")
        }
        guard let doc = SZAgentDocs.read(topic) else {
            throw SZMCPError.message("no doc \"\(topic)\" — available: \(SZAgentDocs.topics.map(\.id).joined(separator: ", "))")
        }
        return doc
    }

    private func agentReadGraph() throws -> String {
        guard let project = host.store.project else { throw SZMCPError.message("no project loaded") }
        return encodeJSON(project.graph)
    }

    private func agentReadNode(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments.uuid("node") else { throw SZMCPError.message("agent_read_node needs `node` (UUID)") }
        guard let node = host.store.project?.graph.node(id: id) else { throw SZMCPError.message("no node \(id)") }
        return encodeJSON(node)
    }

    /// Scan the repo's `NodeLibrary/` for node folders (a `node-contract.json` inside) and assemble the
    /// Tier-1 catalog (docs/NODE_LIBRARY.md): each record's identity + typed I/O + permissions come from the
    /// node's contract (the single source of truth — so `io` can't drift), merged with the hand-curated
    /// `useWhen`/`avoidWhen`/`purpose`/`tags` from `NodeLibrary/index.json`.
    /// One scan behind the index, so what an agent browses is exactly what ships.
    private func libraryCatalog() -> [SZLibraryIndexEntry] {
        let fm = FileManager.default
        let root = SZHost.libraryURL
        let curation = (try? Data(contentsOf: root.appending(path: "index.json")))
            .flatMap { try? JSONDecoder().decode(SZLibraryCurationFile.self, from: $0) }?
            .byID ?? [:]
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var entries: [SZLibraryIndexEntry] = []
        for folder in folders {
            let contractURL = folder.appending(path: "node-contract.json")
            guard let data = try? Data(contentsOf: contractURL),
                  let contract = try? JSONDecoder().decode(SZNodeContract.self, from: data) else { continue }
            let id = folder.lastPathComponent
            entries.append(SZLibraryIndexEntry(id: id, contract: contract, curation: curation[id]))
        }
        entries.sort { $0.id < $1.id }
        return entries
    }

    /// A node's category — its first curated tag, which is the family it belongs to (`color`, `generator`,
    /// `source`, `audio`, …). Nodes without curation fall under `other`.
    private static func libraryCategory(_ entry: SZLibraryIndexEntry) -> String {
        entry.tags?.first ?? "other"
    }

    /// Tier 1: the whole catalog, grouped by category — one line per node with what it does, its typed I/O,
    /// and whether its source drops in unchanged. Everything needed to PICK; nothing needed to implement.
    ///
    /// Deliberately NOT ranked. Scoring a node against a request guesses at "does this do this job", which
    /// is a semantic judgement, and the thing reading this IS a language model. A ranker only moved the
    /// guess earlier and hid its working: it withheld what it scored low and lent authority to what it
    /// scored high, on token overlap. Hand over the evidence and let the reader judge. This costs ~1k tokens
    /// where the old typed-JSON dump cost ~4.4k, so reading it whole is cheaper than a shortlist was.
    private func agentLibraryIndex() -> String {
        func ports(_ list: [SZLibraryIndexEntry.Port]) -> String {
            list.isEmpty ? "none" : list.map { "\($0.name):\($0.type.rawValue)" }.joined(separator: ",")
        }
        let byCategory = Dictionary(grouping: libraryCatalog(), by: Self.libraryCategory)
        let categories = byCategory.keys.sorted().map { category -> String in
            let lines = (byCategory[category] ?? []).map { entry in
                let permissions = (entry.permissions?.map(\.rawValue) ?? []).joined(separator: ",")
                let tags = (entry.tags ?? []).joined(separator: " ")
                return "  \(entry.id) — \(entry.purpose ?? entry.summary)"
                    + " [in \(ports(entry.io.inputs)) | out \(ports(entry.io.outputs))"
                    + (permissions.isEmpty ? "" : " | needs \(permissions)")
                    + (entry.reuse.map { " | \($0)" } ?? "")
                    + (tags.isEmpty ? "" : " | \(tags)") + "]"
            }
            return "\(category):\n\(lines.joined(separator: "\n"))"
        }
        return SZAgentLibraryText.index(categories: categories.joined(separator: "\n"))
    }

    /// Tier-2: the node's CARD.md (reuse guidance + gotchas) — cheap confirmation before fetching source.
    /// Returned as raw text (not JSON-wrapped): the card is a single blob the agent just reads.
    private func agentLibraryCard(_ arguments: [String: Any]) throws -> String {
        let id = try libraryNodeID(arguments, tool: "agent_library_card")
        let url = SZHost.libraryURL.appending(path: "\(id)/CARD.md")
        guard let card = try? String(contentsOf: url, encoding: .utf8) else {
            throw SZMCPError.message("no library card for \(id)")
        }
        return card
    }

    /// Tier-3: the node's full Node.swift, for an agent that picked it as a reference. Raw source text
    /// (not JSON-wrapped) so copy-as-is stays byte-faithful and cheap to read.
    private func agentLibrarySource(_ arguments: [String: Any]) throws -> String {
        let id = try libraryNodeID(arguments, tool: "agent_library_source")
        let url = SZHost.libraryURL.appending(path: "\(id)/Node.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw SZMCPError.message("no library source for \(id)")
        }
        return source
    }

    /// Validate a `node` argument as a library id: a single path component naming a real `NodeLibrary/` folder
    /// (rejects empty / traversal ids before they touch the filesystem).
    private func libraryNodeID(_ arguments: [String: Any], tool: String) throws -> String {
        guard let id = arguments.string("node"), !id.isEmpty else {
            throw SZMCPError.message("\(tool) needs `node` (library id, e.g. camera.macos)")
        }
        guard !id.contains("/"), id != "." , id != ".." else { throw SZMCPError.message("invalid library id: \(id)") }
        let folder = SZHost.libraryURL.appending(path: id)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw SZMCPError.message("no library node \(id)")
        }
        return id
    }

    // MARK: write / compile / status (step 5)

    /// Stage a node's source (+ optional contract) under `<project>.subz/.staging/nodes/<id>/`. Live
    /// state is untouched until `agent_compile_node` promotes.
    private func agentWriteNodeStaged(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments.uuid("node") else { throw SZMCPError.message("agent_write_node_staged needs `node` (UUID)") }
        guard let source = arguments.string("source") else { throw SZMCPError.message("agent_write_node_staged needs `source`") }
        guard let projectURL = host.loadedProjectURL else { throw SZMCPError.message("no project loaded") }

        let dir = projectURL.appending(path: ".staging/nodes/\(id.uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try source.write(to: dir.appending(path: "Node.swift"), atomically: true, encoding: .utf8)
        if let contract = arguments.object("contract") {
            let data = try JSONSerialization.data(withJSONObject: contract, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: dir.appending(path: "node-contract.json"))
        }
        return SZJSONRPC.encode(["ok": true, "staged": dir.path])
    }

    /// Compile-check the staged source; promote on success (host copies live + hot-reloads), or return
    /// the swiftc errors and leave live state untouched.
    private func agentCompileNode(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments.uuid("node") else { throw SZMCPError.message("agent_compile_node needs `node` (UUID)") }
        guard let projectURL = host.loadedProjectURL, let runtime = host.runtime else {
            throw SZMCPError.message("no project/runtime")
        }
        let staged = projectURL.appending(path: ".staging/nodes/\(id.uuidString)/Node.swift")
        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw SZMCPError.message("no staged source for \(id) — call agent_write_node_staged first")
        }

        switch runtime.compileNodeSource(at: staged) {
        case .failed(let log):
            host.recordBuildErrors(log)
            return SZJSONRPC.encode(["ok": false, "errors": log])
        case .ok:
            // A staged contract that's PRESENT but doesn't decode must be a hard error the agent fixes —
            // NOT silently dropped (which would promote a source whose ports the contract never declares →
            // dead/missing UI controls; the #knobs bug). Validate before promoting; source+contract stay
            // consistent. (An ABSENT staged contract is fine — the node keeps its live one.)
            let stagedContract = projectURL.appending(path: ".staging/nodes/\(id.uuidString)/node-contract.json")
            var warnings: [String] = []
            if let data = try? Data(contentsOf: stagedContract), !data.isEmpty {
                let contract: SZNodeContract
                do { contract = try JSONDecoder().decode(SZNodeContract.self, from: data) }
                catch {
                    let msg = Self.contractSchemaError(error)
                    host.recordBuildErrors(msg)
                    return SZJSONRPC.encode(["ok": false, "errors": msg])
                }
                // Contract + source must agree on port names: a port the code reads/writes that the contract
                // never declares is a hard error (the source is NOT promoted); a declared-but-unused port is a
                // non-fatal warning (likely a dead control). See SZPortBindingAudit.
                if let source = try? String(contentsOf: staged, encoding: .utf8) {
                    let audit = SZPortBindingAudit.audit(contract: contract, source: source)
                    if !audit.errors.isEmpty {
                        let msg = Self.portBindingError(audit.errors)
                        host.recordBuildErrors(msg)
                        return SZJSONRPC.encode(["ok": false, "errors": msg])
                    }
                    warnings = audit.warnings
                }
            }
            host.recordBuildErrors(nil)
            try host.promoteStagedNode(id: id)
            return warnings.isEmpty
                ? SZJSONRPC.encode(["ok": true])
                : SZJSONRPC.encode(["ok": true, "warnings": warnings])
        }
    }

    /// Turn a contract `DecodingError` into agent-actionable guidance — the contract JSON is easy to guess
    /// wrong (e.g. `"ui": "knob"` instead of the `ui` object). Surfaced through the same `{ok:false, errors}`
    /// channel as a build failure, so the coding agent's fix loop self-corrects. See `agent_docs_read`
    /// (`node-contract`) for the full schema.
    private static func contractSchemaError(_ error: Error) -> String {
        """
        node-contract.json is invalid and was NOT applied (the source was not promoted): \(error)

        An input port must match this shape:
          { "name": "amount", "type": "float",
            "ui": { "kind": "slider", "min": 0, "max": 1 },
            "default": { "type": "float", "value": 0.5 } }
        - `ui` is an OBJECT, not a string; `kind` ∈ slider | field | colorWell | toggle | dropdown | filePicker (there is no "knob").
        - `min` / `max` live INSIDE `ui`. `default` is an OBJECT `{ "type", "value" }`.
        Fix node-contract.json (re-stage with agent_write_node_staged) and call agent_compile_node again.
        Call agent_docs_read { "topic": "node-contract" } for the full schema.
        """
    }

    /// Turn port-name mismatches (from `SZPortBindingAudit`) into agent-actionable guidance, surfaced through
    /// the same `{ok:false, errors}` channel as a build/contract failure so the coding agent's fix loop
    /// self-corrects. Only hard errors (referenced-but-undeclared ports) reach here; warnings ride the
    /// `{ok:true}` payload.
    private static func portBindingError(_ errors: [String]) -> String {
        """
        node-contract.json and Node.swift disagree on port names (the source was NOT promoted):
        \(errors.map { "  • \($0)" }.joined(separator: "\n"))

        Every port the code reads/writes via ctx.input*/ctx.output*/ctx.setOutput* must be declared in
        node-contract.json with a matching `name` (and vice-versa). Fix the mismatch, re-stage with
        agent_write_node_staged, and call agent_compile_node again.
        Call agent_docs_read { "topic": "node-contract" } for the schema.
        """
    }

    private func agentReportStatus(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments.uuid("node") else { throw SZMCPError.message("agent_report_status needs `node` (UUID)") }
        // A node deleted mid-run (or an id that never existed) has no status to hold — the host drops the
        // write. Say so instead of answering `ok`, so the agent learns its node is gone. A structured
        // refusal, not a thrown error: status is fire-and-forget telemetry, and failing the tool call
        // would send a coding agent off recovering from a problem it cannot fix.
        guard host.store.project?.graph.node(id: id) != nil else {
            return SZJSONRPC.encode(["ok": false, "reason": "node \(id.uuidString) is not in the graph"])
        }
        // The wire stays a loose string (agents produce it); parse to the typed phase at this boundary.
        host.recordNodeStatus(
            node: id,
            phase: SZNodeAgentPhase(wire: arguments.string("status") ?? ""),
            message: arguments.string("message") ?? "")
        return SZJSONRPC.encode(["ok": true])
    }
}
