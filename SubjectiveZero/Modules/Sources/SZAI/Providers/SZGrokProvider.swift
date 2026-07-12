// SPDX-License-Identifier: AGPL-3.0-only
// Grok CLI provider. Subprocess wrapper around `grok -p …` (no API key). Distinct from claude and
// codex in: MCP attaches through a config FILE staged into the working directory by `prepare()`
// (the CLI has no per-invocation MCP flag — `--mcp-config` is rejected, verified grok 0.2.93), and
// the `--output-format streaming-json` stream carries token-level `thought`/`text` chunks with NO
// tool-call events, so tool activity is invisible in the trace (the CLI's richer ACP mode,
// `grok agent stdio`, is a persistent process and doesn't fit the one-shot spawn seam — future work).
// Sessions are claude-style: the host mints `--session-id`, a chat turn continues with `--resume`
// (continuity live-verified on 0.2.93: a resumed turn recalled the prior turn's content).
import Foundation

public struct SZGrokProvider: SZProvider {
    public init() {}

    /// The provider's registry id — the one place the string is written (see SZClaudeProvider).
    public static let providerID = "grok"

    public let id = Self.providerID
    public let displayName = "Grok"
    /// Recorded from `grok models` (grok 0.2.93, grok.com login, 2026-07-12) — the first of our CLIs
    /// that can enumerate its models, so re-verification on a CLI update is one command. Both ids are
    /// the CLI's own tokens; note `grok-build` carries no version, so unlike our pinned claude/codex
    /// ids it CAN re-point underneath us on a backend update — there is no versioned alternative to
    /// pin, `grok models` vends exactly these two. Composer is the CLI's own default and the
    /// speed-focused draw; both ids live-verified via `grok -p -m <id>`.
    /// Labels keep the "Grok" brand, unlike claude/codex's ("Opus 4.8", "GPT-5.5"): those model
    /// families self-identify, "Composer" alone doesn't — the composer pill shows only this label.
    public let models = [
        SZProviderModel(id: "grok-composer-2.5-fast", displayName: "Grok Composer 2.5 Fast"),
        SZProviderModel(id: "grok-build", displayName: "Grok Build"),
    ]
    public let defaultModel = "grok-composer-2.5-fast"
    /// grok 0.2.93 HAS a `--reasoning-effort` flag but does not act on it for either served model,
    /// so no effort menu is declared and `launch()` never emits the flag. Evidence (2026-07-12):
    /// the flag silently accepts ANY value (even an invalid token — exit 0, no warning), so
    /// acceptance proves nothing; and two measured comparisons (`none` vs `high`, then `minimal` vs
    /// `xhigh` on a harder prompt, both models) showed no meaningful change in thought volume
    /// (27→26 / 24→24 chunks; 102→151 / 410→431 chars) with `none` not even suppressing thinking.
    /// Revisit if a future CLI honours it.
    public let defaultReasoningEffort = ""
    public let supportedReasoningEfforts: [String] = []
    public let supportsFastMode = false   // no fast-mode concept in this CLI's argv
    public let healthArgs = ["grok", "--version"]
    /// `grok models` exits 0 whether logged in or not (verified 0.2.93) — only the output differs
    /// ("You are logged in with grok.com." vs "You are not authenticated."), so the auth tier's
    /// marker path, not the exit code, is what classifies a logged-out install.
    public let authStatusArgs = ["grok", "models"]
    /// Recorded from grok 0.2.93. "You are not authenticated" is `grok models`' logged-out output;
    /// the other two are the device-auth banner a logged-out `grok -p` prints — it does NOT fail:
    /// it polls for an interactive browser login until killed, which is why the probe classifies
    /// markers ahead of its timeout.
    public let authFailureMarkers = [
        "You are not authenticated",
        "To sign in, open this URL",
        "Waiting for authorization",
    ]
    public let installCommand = "curl -fsSL https://x.ai/cli/install.sh | bash"
    public let loginCommand = "grok login"
    public let usesPreallocatedSessionID = true   // we mint the UUID and pass --session-id

    /// The CLI discovers `<cwd>/.grok/config.toml` as its highest-priority config scope (pickup
    /// verified via `grok inspect`), and that file is the only way to hand it an MCP server for one
    /// run. Rewritten before every spawn so a stale port from a previous app launch self-heals, and
    /// removed when the turn carries no MCP — a leftover server entry would spend the CLI's 30s MCP
    /// startup timeout on a dead bridge.
    public func prepare(_ request: SZAgentRunRequest) throws {
        let configFile = request.workingDirectory.appending(path: ".grok/config.toml")
        guard let port = request.mcpServerPort else {
            try? FileManager.default.removeItem(at: configFile)
            return
        }
        try FileManager.default.createDirectory(
            at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.mcpConfigTOML(port: port).write(to: configFile, atomically: true, encoding: .utf8)
    }

    public func launch(_ request: SZAgentRunRequest, preallocatedSessionID: String?) -> SZLaunch {
        var args = ["grok", "-p", request.prompt,
                    "-m", request.model ?? defaultModel,
                    "--output-format", "streaming-json",
                    // Full approval bypass for unattended runs, codex parity (a headless turn can't
                    // prompt). TODO(SZ-grok-permissions): tighten to scoped `--allow` rules
                    // (Edit/Write/MCPTool) and live-verify a ui_run coding agent still writes+compiles.
                    "--always-approve"]
        if let resume = request.resumeSessionID {
            args += ["--resume", resume]   // continue the existing conversation (chat turn)
        } else if let sessionID = preallocatedSessionID {
            args += ["--session-id", sessionID]
        }
        // Never emits --reasoning-effort: see supportedReasoningEfforts. Update-check suppression
        // rides an env var rather than the documented --no-auto-update flag — the flag is absent
        // from `grok --help` 0.2.93 and an unknown flag is a hard argv error, while an unknown env
        // var is inert.
        let env = SZAgentEnvironment.base(extra: [
            "SWIFT_MODULE_CACHE_PATH": request.cacheDirectory.appending(path: "swift-module-cache").path,
            "CLANG_MODULE_CACHE_PATH": request.cacheDirectory.appending(path: "clang-module-cache").path,
            "GROK_DISABLE_AUTOUPDATER": "1",
        ])
        return SZLaunch(executable: "/usr/bin/env", arguments: args, environment: env)
    }

    public func parse(output: String, exitCode: Int32, preallocatedSessionID: String?) -> SZAgentOutcome {
        // grok's session id is the one we minted; success rides the exit code.
        SZAgentOutcome(sessionID: preallocatedSessionID, failed: exitCode != 0)
    }

    public func makeStreamConsumer() -> any SZAgentStreamConsumer { SZGrokStreamConsumer() }

    /// The stdio MCP server grok spawns is `nc` bridging to the host's in-process TCP listener.
    /// No `required` key — undocumented for this CLI (unlike codex's config).
    static func mcpConfigTOML(port: UInt16) -> String {
        """
        # Staged by SubjectiveZero before each grok run — rewritten every spawn, do not edit.
        [mcp_servers.subz]
        command = "/usr/bin/nc"
        args = ["127.0.0.1", "\(port)"]
        """
    }
}

/// Parses grok's streaming-json: token-level `{"type":"thought"|"text","data":…}` chunks and a final
/// `end` event (no per-line messages, no tool events — verified 0.2.93). Chunks are accumulated —
/// emitting per token would spam the trace — and flushed at type transitions: a completed thought
/// block becomes one `.activity` when text starts, and text superseded by a NEW thought block was
/// narration, not the answer (matching claude/codex's reply/trace split). The reply flushes in
/// `finish()`, the one point that knows the stream is over.
final class SZGrokStreamConsumer: SZAgentStreamConsumer {
    private var pendingThought = ""
    private var pendingReply = ""

    func consume(_ line: String) -> [SZAgentStreamEvent] {
        guard let data = Self.sanitized(line).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return [] }
        switch type {
        case "thought":
            var events: [SZAgentStreamEvent] = []
            let reply = pendingReply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty {   // a new reasoning block after text → that text was narration
                events.append(.activity(reply))
                pendingReply = ""
            }
            pendingThought += obj["data"] as? String ?? ""
            return events
        case "text":
            let events = flushThought()
            pendingReply += obj["data"] as? String ?? ""
            return events
        case "error":
            let message = (obj["message"] as? String ?? "error")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return flushThought() + [.activity("⚠ " + message)]
        default:   // end / max_turns_reached / auto_compact_* — metadata, nothing to render
            return []
        }
    }

    func finish() -> [SZAgentStreamEvent] {
        var events = flushThought()
        let reply = pendingReply.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingReply = ""
        if !reply.isEmpty { events.append(.reply(reply)) }
        return events
    }

    private func flushThought() -> [SZAgentStreamEvent] {
        let thought = pendingThought.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingThought = ""
        return thought.isEmpty ? [] : [.activity(thought)]
    }

    /// grok emits RAW control characters inside JSON string values (verified 0.2.93 — a strict
    /// parser throws "invalid control character"). Within one JSONL line a raw control char can
    /// only sit inside a string literal (JSON structure uses none), so escaping them linewise is
    /// safe and makes the line parseable.
    static func sanitized(_ line: String) -> String {
        guard line.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return line }
        var out = ""
        out.unicodeScalars.reserveCapacity(line.unicodeScalars.count)
        for scalar in line.unicodeScalars {
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
