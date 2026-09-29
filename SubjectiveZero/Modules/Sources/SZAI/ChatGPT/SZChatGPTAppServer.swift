// SPDX-License-Identifier: AGPL-3.0-only
// one bidirectional app-server connection per turn; local threads survive process renewal.
import Foundation
import SZCore

@MainActor
final class SZChatGPTAppServer {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var continuation: AsyncStream<Data>.Continuation?
    private var timedOut: SZProcessTimeout?
    private var lastActivity = Date()

    func run(_ request: SZAgentRunRequest, executable: URL, accessToken: String,
             accountID: String, directory: URL) async throws -> SZAgentRunResult {
        var threadID: String?
        if let resumed = request.resumeSessionID {
            let parts = resumed.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == accountID else {
                throw SZChatGPTError("This conversation belongs to another ChatGPT connection. Switch accounts or start a new conversation.")
            }
            threadID = parts[1]
        }
        let home = directory.appending(path: accountID)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        process.executableURL = executable
        process.currentDirectoryURL = request.workingDirectory
        var config = [
            "model_provider=\"openai_chatgpt_plan\"",
            "model_providers.openai_chatgpt_plan.name=\"ChatGPT plan\"",
            "model_providers.openai_chatgpt_plan.base_url=\"https://api.openai.com/v1\"",
            "model_providers.openai_chatgpt_plan.env_key=\"SZ_CHATGPT_ACCESS_TOKEN\"",
            "model_providers.openai_chatgpt_plan.wire_api=\"responses\"",
            "model_providers.openai_chatgpt_plan.requires_openai_auth=false",
            "model_providers.openai_chatgpt_plan.supports_websockets=false",
            "shell_environment_policy.filters.SZ_CHATGPT_ACCESS_TOKEN=\"exclude\"",
        ]
        if let port = request.mcpServerPort {
            config += ["mcp_servers.subz.command=\"/usr/bin/nc\"",
                       "mcp_servers.subz.args=[\"127.0.0.1\",\"\(port)\"]",
                       "mcp_servers.subz.required=true",
                       "mcp_servers.subz.default_tools_approval_mode=\"approve\""]
            if !request.allowedMCPTools.isEmpty {
                let names = String(decoding: try JSONEncoder().encode(request.allowedMCPTools), as: UTF8.self)
                config.append("mcp_servers.subz.enabled_tools=" + names)
            }
        }
        process.arguments = ["--listen", "stdio://"] + config.flatMap { ["-c", $0] }
        var environment = ProcessInfo.processInfo.environment.merging(SZAgentEnvironment.base()) { _, value in value }
        environment["CODEX_HOME"] = home.path
        environment["SZ_CHATGPT_ACCESS_TOKEN"] = accessToken
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_API_KEY")
        environment["SWIFT_MODULE_CACHE_PATH"] = request.cacheDirectory.appending(path: "swift-module-cache").path
        environment["CLANG_MODULE_CACHE_PATH"] = request.cacheDirectory.appending(path: "clang-module-cache").path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let (stream, sink) = AsyncStream.makeStream(of: Data.self)
        continuation = sink
        output.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty { sink.finish() } else { sink.yield(bytes) }
        }
        try process.run()
        let timer = Task { @MainActor in
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                if Date().timeIntervalSince(started) >= (request.timeout ?? 1800) { self.timedOut = .wallClock }
                if let silence = request.inactivityTimeout, Date().timeIntervalSince(self.lastActivity) >= silence { self.timedOut = .silence }
                if self.timedOut != nil { self.stop(); return }
            }
        }
        defer { timer.cancel(); stop(); output.fileHandleForReading.readabilityHandler = nil }
        return try await withTaskCancellationHandler {
            try send(["id": 1, "method": "initialize", "params": ["clientInfo": [
                "name": SZChatGPTOAuth.appName, "title": "SubjectiveZero",
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"]]])
            var pending = Data()
            var transcript = Data()
            var failed = true
            var message = "The ChatGPT engine stopped before completing the turn."
            var terminal = false
            for await chunk in stream {
                try Task.checkCancellation()
                lastActivity = Date()
                pending.append(chunk)
                guard pending.count < 32 * 1024 * 1024 else { throw SZChatGPTError("The ChatGPT engine returned an oversized message.") }
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    // raw OAuth credentials must never enter transcripts or diagnostics.
                    let safe = Data((String(decoding: line, as: UTF8.self).replacingOccurrences(of: accessToken, with: "[redacted]") + "\n").utf8)
                    transcript.append(safe)
                    request.onOutput?(safe)
                    if let id = event["id"], event["method"] != nil {
                        try send(["id": id, "error": ["code": -32601, "message": "Interactive requests are unavailable in this agent run."]])
                        continue
                    }
                    if let error = event["error"] as? [String: Any] {
                        message = error["message"] as? String ?? "The ChatGPT engine rejected the request."
                        terminal = true
                        break
                    }
                    let result = event["result"] as? [String: Any] ?? [:]
                    switch event["id"] as? Int {
                    case 1:
                        try send(["method": "initialized"])
                        var params: [String: Any] = ["cwd": request.workingDirectory.path,
                            "modelProvider": "openai_chatgpt_plan", "approvalPolicy": "never", "sandbox": "workspace-write"]
                        if let model = request.model { params["model"] = model }
                        if let threadID { params["threadId"] = threadID }
                        try send(["id": 2, "method": threadID == nil ? "thread/start" : "thread/resume", "params": params])
                    case 2:
                        guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
                            throw SZChatGPTError("The ChatGPT engine did not return a conversation.")
                        }
                        threadID = id
                        var params: [String: Any] = ["threadId": id,
                            "input": [["type": "text", "text": request.prompt]], "approvalPolicy": "never",
                            "sandboxPolicy": ["type": "workspaceWrite", "networkAccess": true,
                                "writableRoots": [request.workingDirectory.path, request.packageDirectory.path, request.cacheDirectory.path]]]
                        if let effort = request.reasoningEffort { params["effort"] = effort }
                        try send(["id": 3, "method": "turn/start", "params": params])
                    default: break
                    }
                    if event["method"] as? String == "turn/completed",
                       let params = event["params"] as? [String: Any], let turn = params["turn"] as? [String: Any] {
                        failed = turn["status"] as? String != "completed"
                        message = (turn["error"] as? [String: Any])?["message"] as? String ?? "ChatGPT did not complete the turn."
                        terminal = true
                        break
                    }
                }
                if terminal { break }
            }
            try Task.checkCancellation()
            if timedOut != nil { failed = true; message = "The ChatGPT turn timed out." }
            let safeMessage = message.replacingOccurrences(of: accessToken, with: "[redacted]")
            return SZAgentRunResult(process: SZProcessResult(exitCode: failed ? 1 : 0,
                output: String(decoding: transcript, as: UTF8.self), timeout: timedOut),
                outcome: SZAgentOutcome(sessionID: threadID.map { accountID + "/" + $0 }, failed: failed,
                                        message: failed ? safeMessage : nil))
        } onCancel: { Task { @MainActor in self.stop() } }
    }

    private func send(_ value: [String: Any]) throws {
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: value) + Data([10]))
    }

    private func stop() {
        if process.isRunning { SZSystemProcessRunner.signalProcessTree(process.processIdentifier, SIGKILL) }
        try? input.fileHandleForWriting.close()
        continuation?.finish()
    }
}

final class SZChatGPTStreamConsumer: SZAgentStreamConsumer {
    private var pendingReply: String?
    func consume(_ line: String) -> [SZAgentStreamEvent] {
        guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let params = event["params"] as? [String: Any] else { return [] }
        let method = event["method"] as? String
        if method == "item/started", let item = params["item"] as? [String: Any] {
            switch item["type"] as? String {
            case "mcpToolCall": return [.toolCall(name: item["tool"] as? String ?? "SubZ tool")]
            case "commandExecution": return [.toolCall(name: "ran command")]
            case "fileChange": return [.toolCall(name: "edited files")]
            default: break
            }
        }
        if method == "item/completed", let item = params["item"] as? [String: Any],
           item["type"] as? String == "agentMessage", let text = item["text"] as? String {
            let prior = pendingReply
            pendingReply = text
            return prior.map { [.thinking($0)] } ?? []
        }
        if method == "item/reasoning/summaryTextDelta", let text = params["delta"] as? String { return [.thinking(text)] }
        if method == "thread/tokenUsage/updated", let usage = params["tokenUsage"] as? [String: Any],
           let last = usage["last"] as? [String: Any], let output = last["outputTokens"] as? Int {
            return [.usage(SZTokenUsage(inputTokens: last["inputTokens"] as? Int ?? 0, outputTokens: output,
                cachedInputTokens: last["cachedInputTokens"] as? Int, reasoningOutputTokens: last["reasoningOutputTokens"] as? Int))]
        }
        return []
    }
    func finish() -> [SZAgentStreamEvent] {
        defer { pendingReply = nil }
        return pendingReply.map { [.reply($0)] } ?? []
    }
}
