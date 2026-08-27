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
            tool("agent_read_graph", "Return the full project graph (nodes with contracts, connections, render endpoint) as JSON. A built node that needs a rebuild carries `rebuildReason` (contractChanged | intentChanged | sourceMismatch) and, for the first and third, `rebuildDetail` (the audit's offending lines, or the ports off the build stamp). A node whose file input can't be read carries `inputFileErrors` (port → why) — that node is built and broken for a reason no rebuild fixes."),
            tool("agent_read_node", "Return one node (title, kind, prompt, contract, hasCard) as JSON, plus `rebuildReason` when it needs a rebuild, `rebuildDetail` when there is evidence to name (an intentChanged node has none — its prompt is the evidence), and `inputFileErrors` (port → why) when a file input can't be read. Check that BEFORE assuming a black node needs code.",
                 properties: ["node": ["type": "string", "description": "node id (UUID)"]]),
            tool("agent_library_index", "The built-in node library, grouped by category: one line per node saying what it does. Cheap — read it whole and decide for yourself whether any node does YOUR node's job. Nothing is ranked or filtered; a similar name is not a match. Fetch at most once per turn (it does not change), and not at all if your brief already includes it."),
            tool("agent_library_card", "Read one library node's card (CARD.md) — reuse guidance, gotchas, and setup notes — to confirm or reject it as a reference without fetching full source. When the node is already the likely reference, request its card and source together in one round.",
                 properties: ["node": ["type": "string", "description": "library node id (e.g. camera.macos)"]]),
            tool("agent_library_source", "Fetch one library node's full Node.swift source, to copy-as-is, adapt, or study before writing your own. Batchable with agent_library_card in the same round. `file: \"Card.swift\"` fetches the node's custom card instead (nodes marked \"ships a card\" in the index) — the worked example for authoring one.",
                 properties: ["node": ["type": "string", "description": "library node id (e.g. camera.macos)"],
                              "file": ["type": "string", "enum": ["Node.swift", "Card.swift"], "description": "which file (default Node.swift)"]]),
            tool("agent_write_node_staged", "Write a node's Node.swift (+ optional node-contract.json, + optional Card.swift — the node's custom card, see agent_docs_read {topic:\"card-abi\"}) to the project's .staging area. Does NOT touch live state. Omitting `card` also drops any previously staged card.",
                 properties: [
                    "node": ["type": "string", "description": "node id (UUID)"],
                    "source": ["type": "string", "description": "the full Node.swift source"],
                    "contract": ["type": "object", "description": "the node-contract.json object (optional)"],
                    "card": ["type": "string", "description": "the full Card.swift source (optional)"],
                 ]),
            tool("agent_compile_node", "Compile-check the staged Node.swift (and the staged Card.swift, if any). On success, promote (copy to live + hot-reload; a first card turns itself on) and return {ok:true}. On failure, return {ok:false, errors} and leave live state untouched — a red card blocks the promote too.",
                 properties: ["node": ["type": "string", "description": "node id (UUID)"]]),
            tool("agent_report_status", "Report a node's observable status (queued/coding/ok/needsInput/error + message).",
                 properties: [
                    "node": ["type": "string"], "status": ["type": "string"], "message": ["type": "string"],
                 ]),
            tool("agent_check_path", "Ask whether a path on this machine exists and can be read, before you rely on it. Returns {path, exists, readable, kind: file|directory|package|null, extension, bytes, modified} and, when it can't be used, `reason` — the same sentence the user sees on the node. `kind: \"package\"` means a folder macOS treats as a single file (a .mlpackage, an .app): that IS the file, don't look inside for one. Your working directory is a scratch dir, so this is the only way you can check a path elsewhere. Pass `accepting` (extensions, no dot) to also check the file is the right kind.",
                 properties: [
                    "path": ["type": "string"],
                    "accepting": ["type": "array", "items": ["type": "string"],
                                  "description": "optional: filename extensions the caller accepts, no dot"],
                 ]),
            tool("agent_docs_index", "List the reference docs you can fetch (id, title, summary) — the canonical contract schema, the runtime ABI, etc. Cheap; read a topic's body only when you need it (e.g. before authoring a node-contract.json)."),
            tool("agent_docs_read", "Fetch one reference doc's full markdown by topic id (from agent_docs_index) — e.g. \"node-contract\" for the contract/ui/default schema, \"node-abi\" for the runtime ABI, \"card-abi\" for authoring a node's Card.swift. Use this instead of guessing the schema — but skip any doc your brief already embeds, and batch it with your other reads (e.g. the library index) rather than spending a round on it alone.",
                 properties: ["topic": ["type": "string", "description": "a topic id from agent_docs_index, e.g. node-contract"]]),
            tool("agent_view_frame", "Return a node's rendered texture output as an inline image so you can SEE your VFX result — composition, color, motion, artifacts. Pass `node` to look at THAT node's output (default: its first `texture` output; `port` picks another) — read straight off the render pool, the user's viewport is untouched. Never toggle the display just to look — pass `node`. Without `node`: what the viewport currently shows (the display endpoint). Pixel-perfect (real framebuffer readback), downscaled to fit the token budget (default 768px long edge; pass maxSize to change). Pair with debug_set_paused to freeze time and A/B an input.",
                 properties: [
                    "node": ["type": "string", "description": "node id (UUID) whose output to look at; omit for the viewport's current endpoint"],
                    "port": ["type": "string", "description": "which texture output of `node` (default: its first texture output)"],
                    "maxSize": ["type": "integer", "description": "max long-edge px of the returned image (default 768, clamped 64–1280). Full render is 1280×800."],
                 ]),
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

    /// Read back a node's texture output (`node` given — the endpoint stays where the user put it) or the
    /// current render endpoint (what the viewport displays), downscale to `maxSize`, and return it as an
    /// inline PNG the model can look at.
    private func agentViewFrame(_ arguments: [String: Any]) throws -> SZMCPToolResult {
        let frame: SZImageBytes
        if arguments["node"] != nil {
            guard let id = arguments.uuid("node") else { throw SZMCPError.message("agent_view_frame `node` must be a UUID") }
            guard let node = host.store.project?.graph.node(id: id) else { throw SZMCPError.message("no node \(id)") }
            let textureOutputs = node.contract?.outputs.filter { $0.type == .texture }.map(\.name) ?? []
            guard let port = arguments.string("port") ?? textureOutputs.first else {
                throw SZMCPError.message("`\(node.title)` has no texture output to look at")
            }
            guard textureOutputs.contains(port) else {
                throw SZMCPError.message("`\(node.title)` has no texture output `\(port)` — outputs: \(textureOutputs.joined(separator: ", "))")
            }
            guard let captured = host.runtime?.captureTexture(node: id, port: port) else {
                throw SZMCPError.message("`\(node.title)` `\(port)` has not rendered yet — only implemented (compiled) nodes render; build it first, or wait a frame")
            }
            frame = captured
        } else {
            guard let captured = host.runtime?.captureFrame() else {
                throw SZMCPError.message("no frame rendered yet")
            }
            frame = captured
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
        case "agent_library_index":      return Self.libraryIndexText()
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

    /// Answer "does this path exist and can I read it" for an agent, which otherwise cannot: its
    /// working directory is a scratch dir and its tool allowlist has no shell. `nonisolated` and
    /// `static` because it touches no host state at all — that is what lets it run off the main actor.
    ///
    /// The `reason` string comes from the SAME audit behind the node's pill, so an agent and the user
    /// never describe one fault in two vocabularies.
    nonisolated static func agentCheckPath(_ arguments: [String: Any]) throws -> String {
        guard let raw = arguments.string("path"), !raw.isEmpty else {
            throw SZMCPError.message("agent_check_path needs `path`")
        }
        let path = (raw as NSString).expandingTildeInPath
        // There is no working directory to be relative TO: nodes run inside the render loop, and this
        // tool deliberately reads no project state. Say that rather than answering about some path the
        // caller did not mean.
        guard path.hasPrefix("/") else {
            return SZJSONRPC.encode([
                "path": path, "exists": false, "readable": false, "kind": NSNull(),
                "reason": "not an absolute path: \"\(raw)\" — pass a full path",
            ])
        }
        let url = URL(fileURLWithPath: path)
        let accepting = arguments.stringList("accepting").map { $0.lowercased() }
        var out: [String: Any] = ["path": path, "extension": url.pathExtension.lowercased()]

        let keys: Set<URLResourceKey> = [.isReadableKey, .isDirectoryKey, .isPackageKey, .fileSizeKey,
                                         .contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            out["exists"] = false
            out["readable"] = false
            out["kind"] = NSNull()
            out["reason"] = "no file at \(path)"
            return SZJSONRPC.encode(out)
        }
        out["exists"] = true
        out["readable"] = values.isReadable == true
        // A package is a folder macOS presents as one file. Agents need that distinction: told
        // "directory", an agent goes hunting inside for the real file, and there isn't one.
        out["kind"] = values.isPackage == true ? "package" : (values.isDirectory == true ? "directory" : "file")
        if let bytes = values.fileSize ?? values.totalFileAllocatedSize { out["bytes"] = bytes }
        if let modified = values.contentModificationDate {
            out["modified"] = ISO8601DateFormatter().string(from: modified)
        }
        // The project URL is main-actor state this tool deliberately does not read, so an already
        // absolute path is all it can judge — which is exactly what an agent asks about.
        if let reason = SZFileInputAudit.fault(path: path, accepting: accepting,
                                               in: URL(fileURLWithPath: "/")) {
            out["reason"] = reason
        }
        return SZJSONRPC.encode(out)
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
        let encoded = encodeJSON(project.graph)
        guard var json = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any],
              let nodes = json["nodes"] as? [[String: Any]] else { return encoded }
        json["nodes"] = nodes.map { node in
            guard let id = (node["id"] as? String).flatMap(SZNodeID.init(uuidString:)) else { return node }
            return annotatingRebuild(node, id: id)
        }
        return encodeJSON(json, fallback: encoded)
    }

    private func agentReadNode(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments.uuid("node") else { throw SZMCPError.message("agent_read_node needs `node` (UUID)") }
        guard let node = host.store.project?.graph.node(id: id) else { throw SZMCPError.message("no node \(id)") }
        // Whether the node folder holds a Card.swift rides along — a Director/agent can't see files.
        let encoded = encodeJSON(node)
        guard var json = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any] else {
            return encoded
        }
        json["hasCard"] = host.nodeHasCardSource(id)
        return encodeJSON(annotatingRebuild(json, id: id), fallback: encoded)
    }

    /// `rebuildReason` is derived, not encoded with the node, and its evidence is host state — both ride on the
    /// agent surface as `rebuildReason` / `rebuildDetail` (the audit's lines, or the ports off the build stamp),
    /// so an agent sees WHY a node is flagged instead of guessing at the files. Absent when clean.
    ///
    /// `buildStamp` goes the other way: it is host bookkeeping a promote rewrites, and an agent that sees it
    /// reads it as something to reconcile. The derived reason says everything about it an agent may act on.
    private func annotatingRebuild(_ json: [String: Any], id: SZNodeID) -> [String: Any] {
        var json = json
        json.removeValue(forKey: "buildStamp")
        guard let node = host.store.project?.graph.node(id: id) else { return json }
        // A node can be perfectly built and still render black because a file input points at nothing.
        // Say so here: it is the first thing anyone asks when a node looks dead, and it is not a rebuild.
        if !node.unreadableInputs.isEmpty { json["inputFileErrors"] = node.unreadableInputs }
        // And a node can open its file and still not use it: a missing codec, a pipeline that would not
        // build. Only the node sees that, so this is its own words (`ctx.reportError`).
        if let reported = host.nodeRuntimeErrors[id] { json["nodeError"] = reported }
        guard let reason = node.rebuildReason else { return json }
        json["rebuildReason"] = reason.rawValue
        if let detail = host.rebuildDetail(node: id) { json["rebuildDetail"] = detail }
        return json
    }

    /// Scan the repo's `NodeLibrary/` for node folders (a `node-contract.json` inside) and assemble the
    /// Tier-1 catalog (docs/NODE_LIBRARY.md): each record's identity + typed I/O + permissions come from the
    /// node's contract (the single source of truth — so `io` can't drift), merged with the hand-curated
    /// `useWhen`/`avoidWhen`/`purpose`/`tags` from `NodeLibrary/index.json`.
    /// One scan behind the index, so what an agent browses is exactly what ships.
    nonisolated private static func libraryCatalog() -> [SZLibraryIndexEntry] {
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
            let hasCard = fm.fileExists(atPath: folder.appending(path: "Card.swift").path)
            entries.append(SZLibraryIndexEntry(id: id, contract: contract, curation: curation[id], hasCard: hasCard))
        }
        entries.sort { $0.id < $1.id }
        return entries
    }

    /// A node's category — its first curated tag, which is the family it belongs to (`color`, `generator`,
    /// `source`, `audio`, …). Nodes without curation fall under `other`.
    nonisolated private static func libraryCategory(_ entry: SZLibraryIndexEntry) -> String {
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
    /// The tool's payload: the categories block wrapped in the tool-response framing (how to spend
    /// the deeper tiers). The framing stays OUT of the brief embed below — a brief carries its own
    /// framing (`reference-inline`), and the two must not ship together (they disagree on how to
    /// spend the deeper tiers).
    nonisolated static func libraryIndexText() -> String {
        let categories = libraryCategoriesBlock() ?? "(the library is empty)"
        // The framing template lives in the coding pack (the ONE home for agent prose;
        // the equivalence gate pins the bytes). No packs, or a render refusal → the bare
        // categories block, which is the payload's substance — degrade, never invent.
        guard let root = SZHost.graphAgentPacksRoot() else { return categories }
        let coding = SZAgentPackLoader.load(root: root).seats.coding ?? "coding"
        return (try? SZBriefRenderer(packRoot: root).libraryIndex(agent: coding, categories: categories))
            ?? categories
    }

    /// The categories block for inlining into cold-start coding briefs
    /// (`SZHost+Run.makeOrchestrationContext`) — the shared assembly under both surfaces, so the
    /// brief and the tool cannot drift on content. nil when the catalog is empty (a packaging
    /// regression): the brief then falls back to the call-the-tool framing rather than asserting
    /// "the full catalog is right here" around nothing while forbidding the tool that would show
    /// the live state.
    nonisolated static func libraryCategoriesBlock() -> String? {
        func ports(_ list: [SZLibraryIndexEntry.Port]) -> String {
            list.isEmpty ? "none" : list.map { "\($0.name):\($0.type.rawValue)" }.joined(separator: ",")
        }
        let byCategory = Dictionary(grouping: libraryCatalog(), by: Self.libraryCategory)
        guard !byCategory.isEmpty else { return nil }
        let categories = byCategory.keys.sorted().map { category -> String in
            let lines = (byCategory[category] ?? []).map { entry in
                let permissions = (entry.permissions?.map(\.rawValue) ?? []).joined(separator: ",")
                let tags = (entry.tags ?? []).joined(separator: " ")
                return "  \(entry.id) — \(entry.purpose ?? entry.summary)"
                    + " [in \(ports(entry.io.inputs)) | out \(ports(entry.io.outputs))"
                    + (permissions.isEmpty ? "" : " | needs \(permissions)")
                    + (entry.card == true ? " | ships a card" : "")
                    + (entry.reuse.map { " | \($0)" } ?? "")
                    + (tags.isEmpty ? "" : " | \(tags)") + "]"
            }
            return "\(category):\n\(lines.joined(separator: "\n"))"
        }
        return categories.joined(separator: "\n")
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
        // `file: "Card.swift"` reads the node's custom card instead of its Node.swift — the worked
        // example an agent studies before authoring one (only nodes flagged "ships a card" have one).
        let file = arguments.string("file") ?? "Node.swift"
        guard file == "Node.swift" || file == "Card.swift" else {
            throw SZMCPError.message("agent_library_source `file` must be Node.swift or Card.swift")
        }
        let url = SZHost.libraryURL.appending(path: "\(id)/\(file)")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw SZMCPError.message("no library \(file) for \(id)")
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
        // The contract, when given, is decoded and re-encoded through the SAME serializer the live
        // `node-contract.json` uses, so staged vs live diff on content only (never on float formatting).
        // A contract staged in an earlier write of the SAME attempt stays (a source-only fix after a red
        // compile keeps its knobs); a successful promote clears the whole staged folder.
        if let contract = arguments.object("contract") {
            let authored: SZNodeContract
            do {
                let raw = try JSONSerialization.data(withJSONObject: contract)
                authored = try JSONDecoder().decode(SZNodeContract.self, from: raw)
            } catch {
                // Same self-correction channel as a build failure. Node.swift IS staged at this point.
                let msg = Self.contractSchemaError(error, then: "Fix node-contract.json and re-stage (Node.swift was staged; the previous staged contract, if any, is untouched).")
                host.recordBuildErrors(msg)
                return SZJSONRPC.encode(["ok": false, "errors": msg])
            }
            try SZProjectIO.contractData(authored).write(to: dir.appending(path: "node-contract.json"), options: .atomic)
        }
        // Staging mirrors the LAST write: a card staged earlier and omitted now is removed, so a
        // stale card can never re-promote over a live one the user has since hand-edited.
        let stagedCard = dir.appending(path: "Card.swift")
        if let card = arguments.string("card") {
            try card.write(to: stagedCard, atomically: true, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: stagedCard.path) {
            try FileManager.default.removeItem(at: stagedCard)
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
            // consistent.
            let stagedContract = projectURL.appending(path: ".staging/nodes/\(id.uuidString)/node-contract.json")
            var warnings: [String] = []
            var authored: SZNodeContract?
            if let data = try? Data(contentsOf: stagedContract), !data.isEmpty {
                do { authored = try JSONDecoder().decode(SZNodeContract.self, from: data) }
                catch {
                    let msg = Self.contractSchemaError(error, then: "Fix node-contract.json (re-stage with agent_write_node_staged) and call agent_compile_node again.")
                    host.recordBuildErrors(msg)
                    return SZJSONRPC.encode(["ok": false, "errors": msg])
                }
            }
            // Audit against what the promote will actually PUT LIVE (`SZPortBindingAudit.auditForPromote`):
            // the authored contract merged into the node, or — with no staged contract — the LIVE
            // contract itself, so a source-only re-stage never bypasses the gate. A port the code
            // reads/writes that the contract never declares is a hard error (nothing is promoted); a
            // declared-but-unused port and any boundary-merge conflict ride back as warnings.
            // The merge happens ONCE, here: its result is what the promote writes, so the gate audits
            // exactly what lands.
            var merged: SZNodeContract?
            if let node = host.store.project?.graph.node(id: id),
               let source = try? String(contentsOf: staged, encoding: .utf8) {
                let audit = SZPortBindingAudit.auditForPromote(source: source, authored: authored, node: node)
                if !audit.result.errors.isEmpty {
                    let msg = Self.portBindingError(audit.result.errors)
                    host.recordBuildErrors(msg)
                    return SZJSONRPC.encode(["ok": false, "errors": msg])
                }
                merged = audit.contract
                warnings = audit.mergeConflicts + audit.result.warnings
            }
            // The card half: a staged Card.swift must compile too, or nothing promotes — a green
            // node with a red card would mount the failed chip in the agent's name. Same
            // `{ok:false, errors}` channel, prefixed so the agent knows which file to fix.
            let stagedCard = projectURL.appending(path: ".staging/nodes/\(id.uuidString)/Card.swift")
            if FileManager.default.fileExists(atPath: stagedCard.path) {
                if case .failed(let log) = host.cardHost.compileCheck(source: stagedCard) {
                    let msg = Self.cardCompileError(log)
                    host.recordBuildErrors(msg)
                    return SZJSONRPC.encode(["ok": false, "errors": msg])
                }
            }
            host.recordBuildErrors(nil)
            try host.promoteStagedNode(id: id, contract: merged)
            return warnings.isEmpty
                ? SZJSONRPC.encode(["ok": true])
                : SZJSONRPC.encode(["ok": true, "warnings": warnings])
        }
    }

    /// Turn a contract `DecodingError` into agent-actionable guidance — the contract JSON is easy to guess
    /// wrong (e.g. `"ui": "knob"` instead of the `ui` object). Surfaced through the same `{ok:false, errors}`
    /// channel as a build failure, so the coding agent's fix loop self-corrects. See `agent_docs_read`
    /// (`node-contract`) for the full schema.
    private static func contractSchemaError(_ error: Error, then next: String) -> String {
        """
        node-contract.json is invalid and was NOT applied (the source was not promoted): \(error)

        An input port must match this shape:
          { "name": "amount", "type": "float",
            "ui": { "kind": "slider", "min": 0, "max": 1 },
            "default": { "type": "float", "value": 0.5 } }
        - `ui` is an OBJECT, not a string; `kind` ∈ slider | field | colorWell | toggle | dropdown | filePicker (there is no "knob").
        - `min` / `max` live INSIDE `ui`. `default` is an OBJECT `{ "type", "value" }`.
        \(next)
        Call agent_docs_read { "topic": "node-contract" } for the full schema.
        """
    }

    /// A red Card.swift compile, surfaced through the same channel as a node build failure so the
    /// coding agent's fix loop self-corrects — and knows it's the CARD, not the node, that failed.
    private static func cardCompileError(_ log: String) -> String {
        """
        Card.swift failed to compile (nothing was promoted — Node.swift included):
        \(log)

        Fix Card.swift, re-stage with agent_write_node_staged (source + card), and call agent_compile_node again.
        Call agent_docs_read { "topic": "card-abi" } for the card contract (SZCardState, SZCardMain, live/commit).
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
