// SPDX-License-Identifier: AGPL-3.0-only
// The host's glue for SZTrace (SZCore) — the fence architecture does the collecting; this file
// only owns what is genuinely host policy:
//   - WHO a tool call belongs to (`traceContext(for:)` — the MCP bridge binds it around dispatch,
//     so every fence inside any handler attributes with zero parameters);
//   - landing a finished turn's events on its message (`finalizeTurn`, from `deliver`'s defer);
//   - the run rollup on the Director's run-complete narration (`attachRunRollup`).
// Measurement itself lives in the measured things (compileNodeSource self-fences, promote fences
// in promoteStagedNode, first-output/tool sightings at the stream seam) and lands via ambient
// task-local context — see SZTrace.swift's header for the rules.
import AppKit
import Foundation
import SZCore

extension SZHost {
    /// Attribution for one MCP tool call. A `node` argument names the SUBJECT, not necessarily
    /// the caller: a coding agent's own calls carry its node (whose turn is streaming — attribute
    /// there), but a Director editing a node's ports carries that node too while the only live
    /// turn is the Director's. So the node route applies only when that node's turn is actually
    /// in flight; otherwise a sole streaming turn (Director, lone coding agent, chat) is
    /// unambiguously the caller. Several turns in flight and no in-flight subject (parallel
    /// coding agents calling library/doc tools) → nil, and the bridge's nil binding DROPS the
    /// span — those calls read as their turns' "model" share, never misfiled.
    func traceContext(for arguments: [String: Any]) -> SZTraceContext? {
        let runID = activeRuns.count == 1 ? activeRuns.values.first?.traceID : nil
        if let raw = arguments["node"] as? String, let id = SZNodeID(uuidString: raw),
           let assistantID = inFlightAssistantIDs[SZChatScope.node(id).key] {
            return SZTraceContext(turnID: assistantID, scopeKey: id.uuidString, runID: runID)
        }
        if inFlightAssistantIDs.count == 1, let sole = inFlightAssistantIDs.first {
            return SZTraceContext(turnID: sole.value, scopeKey: sole.key, runID: runID)
        }
        return nil
    }

    /// The transcript's jump: open the Profiler and land on the given record (a runID for
    /// run-owned breakdowns, a message id for chat turns).
    func revealInProfiler(_ target: UUID) {
        profilerFocusRequest = target
        if !panelLayout.contains(.profiler) { showPanel(.profiler) }
    }

    /// "What was the agent ACTUALLY sent?" — write the held prompt to a temp file and hand it to
    /// the default text editor. Loudly explains itself when the prompt has aged out of the ring.
    func viewTurnPrompt(_ turnID: UUID) {
        guard let prompt = heldPrompt(for: turnID) else {
            status = "This prompt is no longer kept. Only the last \(SZHost.debugTurnCaptureCap) turns are."
            NSSound.beep()
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "subz-prompt-\(turnID.uuidString.prefix(8)).txt")
        do {
            try prompt.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        } catch {
            status = "could not write the prompt file: \(error)"
        }
    }

    /// What was ACTUALLY sent to the CLI: the rendered prompt, held in an in-memory ring and
    /// persisted under `debug-turns/<turnID>/prompt.txt` so inspection survives relaunches.
    /// Not gated on tracing — the run card's prompt pill ships everywhere — so the caps contain
    /// it instead (`turnPromptCap` in memory, `debugTurnCaptureCap` folders on disk). The
    /// `prompt.size` row below still self-gates in `SZTrace.record`; a release build pays nothing.
    func recordTurnPrompt(_ prompt: String, for assistantID: UUID) {
        SZTrace.record(SZTurnEvent(stage: SZTurnStage.promptSize,
                                   detail: "\(SZTurnBreakdown.formatTokens(prompt.count)) chars",
                                   addedTokens: prompt.count / 4),
                       turnID: assistantID)
        turnPrompts[assistantID] = prompt
        turnPromptOrder.append(assistantID)
        while turnPromptOrder.count > SZHost.turnPromptCap {
            turnPrompts.removeValue(forKey: turnPromptOrder.removeFirst())
        }
        let dir = SZHost.debugTurnDirectory(for: assistantID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? prompt.write(to: dir.appending(path: "prompt.txt"), atomically: true, encoding: .utf8)
        heldPromptIDs.insert(assistantID)
        pruneDebugTurnCaptures()
    }

    /// One tool result's payload, filed under its turn's capture folder as `<seq>-<tool>.txt` —
    /// these payloads ARE the turn's app-visible input tokens; keeping the text (debug builds
    /// only, capped) is what lets "how many tokens did this action add" be answered with the
    /// actual content, not just a number.
    func recordToolPayload(turnID: UUID, tool: String, result: String) {
        guard SZTrace.isEnabled else { return }
        let dir = SZHost.debugTurnDirectory(for: turnID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let seq = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []).count
        let name = String(format: "%02d-%@.txt", seq, tool)
        try? result.write(to: dir.appending(path: name), atomically: true, encoding: .utf8)
    }

    /// The turn's held prompt: the in-memory ring first (this session), else the on-disk capture
    /// (any session still inside the cap).
    func heldPrompt(for turnID: UUID) -> String? {
        turnPrompts[turnID]
            ?? (try? String(contentsOf: SZHost.debugTurnDirectory(for: turnID)
                    .appending(path: "prompt.txt"), encoding: .utf8))
    }

    /// `~/Library/Application Support/SubjectiveZero/debug-turns/<turnID>/` — the turn's debug
    /// capture: `prompt.txt` + one `<seq>-<tool>.txt` per tool result.
    nonisolated static func debugTurnDirectory(for turnID: UUID) -> URL {
        debugTurnsRoot.appending(path: turnID.uuidString)
    }

    nonisolated static var debugTurnsRoot: URL { SZAppSupport.directory.appending(path: "debug-turns") }

    /// Seed `heldPromptIDs` from the on-disk captures (called once at start) — the view-prompt
    /// buttons and Tokens windows of PAST sessions' turns light up again.
    func loadHeldPromptIDs() {
        let names = (try? FileManager.default
            .contentsOfDirectory(atPath: SZHost.debugTurnsRoot.path(percentEncoded: false))) ?? []
        heldPromptIDs = Set(names.compactMap(UUID.init(uuidString:)))
    }

    /// Keep the newest `debugTurnCaptureCap` turn folders; a debug capture, not an archive.
    private func pruneDebugTurnCaptures() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: SZHost.debugTurnsRoot,
                                                     includingPropertiesForKeys: [.contentModificationDateKey]),
              dirs.count > SZHost.debugTurnCaptureCap else { return }
        let dated = dirs.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(dated.count - SZHost.debugTurnCaptureCap) {
            try? fm.removeItem(at: url)
            if let id = UUID(uuidString: url.lastPathComponent) { heldPromptIDs.remove(id) }
        }
    }

    /// Turn end (`deliver`'s defer — runs OUTSIDE the context binding, hence the explicit
    /// turnID): collect the turn's events, run the pure finalize (dedupe/sort/model-residual/
    /// report-pinning), land the breakdown on the message before the transcript flush, and log
    /// run-owned turns for the run-complete rollup. `runID` is the run identity the turn was
    /// DISPATCHED under — re-checked against the live run here, so a zombie turn settling after
    /// cancel-and-restart never logs itself (or stamps its rows) into the new run.
    func finalizeTurn(assistantID: UUID, scope: SZChatScope, started: Date, ended: Date,
                      runID capturedRunID: UUID?, generation: String? = nil) {
        guard SZTrace.isEnabled else { return }
        var events = SZTurnBreakdown.finalize(events: SZTrace.take(turnID: assistantID),
                                              started: started, ended: ended)
        guard !events.isEmpty else { return }
        // The thinking rows name WHO was thinking: the turn's model + params ("gpt-5.6-terra ·
        // fast"), super compact — supplied by deliver, which built the request.
        if let generation, !generation.isEmpty {
            for i in events.indices where events[i].stage == SZTurnStage.modelTime {
                events[i].detail = generation
            }
        }
        // The run the turn was DISPATCHED under, if it is still live — a zombie turn settling
        // after cancel-and-restart finds nothing and logs itself nowhere.
        let run = capturedRunID.flatMap { id in activeRuns.values.first { $0.traceID == id } }
        // Normalize the run stamp across the whole turn (explicit-turnID records like queue.wait
        // predate the context binding and derived rows have none) — the panel/MCP find a run's
        // turns by this.
        if let run {
            for i in events.indices { events[i].runID = run.traceID }
        }
        store.setChatBreakdown(events, assistantID, in: scope)
        guard let run else { return }
        let label: String
        if case .node(let id) = scope {
            label = store.project?.graph.node(id: id)?.title ?? String(id.uuidString.prefix(8))
        } else {
            label = "Director"
        }
        run.turnLog.append(SZTurnBreakdown.RunTurn(
            scopeKey: scope.key, label: label, isDirector: scope.key == SZChatScope.directorKey,
            start: started, duration: ended.timeIntervalSince(started),
            usage: store.messages(for: scope).first { $0.id == assistantID }?.usage,
            events: events, turnID: assistantID))
    }

    /// The turn's ACTUAL tokens, as text for the app's "Tokens" window: the per-action "in"
    /// decomposition (what each action ADDED to the agent's context — prompt + every tool
    /// result, with the CLI's system/history remainder named), the prompt text itself, the
    /// capture folder holding every tool result's payload, and the streamed output. This is
    /// everything crossing the app↔CLI boundary; the CLI's own share is labeled, never guessed.
    func turnTokenReport(for turnID: UUID) -> String {
        for (scopeKey, messages) in store.chat {
            guard let message = messages.first(where: { $0.id == turnID }) else { continue }
            let label = scopeKey == SZChatScope.directorKey
                ? "Director" : (nodeTitlesByScopeKey[scopeKey] ?? String(scopeKey.prefix(8)))
            var lines = ["tokens — \(label)"
                         + (message.usage.map { " · \(SZTurnBreakdown.tokenLine($0))" } ?? "")]
            lines.append("")
            lines.append("━━ IN — what each action added to the context (approx) ━━")
            let contextRows = (message.breakdown ?? []).filter { $0.addedTokens != nil }
            var appVisible = 0
            for event in contextRows {
                let added = event.addedTokens ?? 0
                appVisible += added
                let name = event.stage == SZTurnStage.promptSize
                    ? "prompt" : "→ \(event.detail ?? "tool")"
                lines.append("  \("+\(SZTurnBreakdown.formatTokens(added)) tok".leftPadded(to: 12))  \(name)")
            }
            if contextRows.isEmpty {
                lines.append("  (no per-action data recorded for this turn)")
            } else if let usage = message.usage {
                lines.append("  \("~\(SZTurnBreakdown.formatTokens(appVisible)) tok".leftPadded(to: 12))  app-visible total, of "
                             + "\(SZTurnBreakdown.formatTokens(usage.inputTokens)) reported")
                // The remainder EXPLAINED, not hand-waved: a turn with tool calls is several
                // model calls, and the CLI re-sends its whole context (system prompt + session
                // history) on each — that replay × call count is where the big number comes from.
                // Structural field first; transcripts written before it exist carry the count only
                // in the report row's detail prose ("6 turns · …"), so fall back to parsing that
                // rather than losing the explanation on historical turns.
                let calls = SZTurnBreakdown.reportedCalls(in: message.breakdown ?? [])
                    ?? (message.breakdown ?? [])
                        .first { $0.stage == SZTurnStage.providerReport }?.detail
                        .flatMap { Int($0.components(separatedBy: " turn").first ?? "") }
                if let calls, calls > 0 {
                    lines.append("  the remainder is the CLI's context (its system prompt + the session's"
                                 + " full history), re-sent on each of the turn's \(calls) model call\(calls == 1 ? "" : "s")"
                                 + " (~\(SZTurnBreakdown.formatTokens(usage.inputTokens / calls)) context per call)")
                } else {
                    lines.append("  the remainder is the CLI's context (system prompt + session history),"
                                 + " re-sent on every model call inside the turn")
                }
            }
            lines.append("")
            lines.append("━━ PROMPT — the rendered prompt this turn sent ━━")
            lines.append(heldPrompt(for: turnID)
                ?? "(This prompt is no longer kept. Only the last \(SZHost.debugTurnCaptureCap) turns are.)")
            let captureDir = SZHost.debugTurnDirectory(for: turnID)
            if FileManager.default.fileExists(atPath: captureDir.path(percentEncoded: false)) {
                lines.append("")
                lines.append("tool-result payloads (full text): \(captureDir.path(percentEncoded: false))")
            }
            lines.append("")
            lines.append("━━ OUT — the turn's streamed output ━━")
            if !message.thinking.isEmpty {
                lines.append("[thinking]")
                lines.append(message.thinking)
                lines.append("")
                lines.append("[reply]")
            }
            lines.append(message.text.isEmpty ? "(no text)" : message.text)
            return lines.joined(separator: "\n")
        }
        return "(turn \(turnID.uuidString.prefix(8)) not found in any transcript)"
    }

    /// Node labels for run-record assembly (`SZTurnBreakdown.runRecords`) — scope key → title,
    /// for the panel's and `debug_run_summary`'s human-readable lane names.
    var nodeTitlesByScopeKey: [String: String] {
        Dictionary(uniqueKeysWithValues: (store.project?.graph.nodes ?? [])
            .map { ($0.id.uuidString, $0.title) })
    }

    /// Fold the run's logged turns into the rollup and land it on the run-complete narration —
    /// the "report after a run", living in the Director transcript like everything else.
    func attachRunRollup(to messageID: UUID, run: SZRunState) {
        guard SZTrace.isEnabled, !run.turnLog.isEmpty else { return }
        // Monotonic end anchor, matching the turns' walls — an NTP step mid-run must not skew
        // the rollup against the rows it aggregates.
        let runEnd = run.startedAt.addingTimeInterval((ContinuousClock.now - run.startedMono).szSeconds)
        var rows = SZTurnBreakdown.aggregate(turns: run.turnLog, runStart: run.startedAt, runEnd: runEnd)
        // The narration's rows carry the run's identity — how a run is looked up.
        for i in rows.indices { rows[i].runID = run.traceID }
        unreadRunIDs.insert(run.traceID)   // fresh record → the Profiler's unread dot
        store.setChatBreakdown(rows, messageID, in: .director)
    }
}

extension String {
    /// Right-aligns the token column in `turnTokenReport` — monospaced output, no format table.
    fileprivate func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
