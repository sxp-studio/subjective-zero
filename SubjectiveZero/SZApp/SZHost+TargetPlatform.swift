// SPDX-License-Identifier: AGPL-3.0-only
// The Target Platform pane's values, mapped from the host: one row per platform with its build count
// (each node's cached built set, refreshed from disk when the pane opens), the conversion report derived
// from the conversion state plus each node's flag and status line, and the note under the list.
import Foundation
import SZCore
import SZUI

extension SZHost {
    /// Open Settings on the Target Platform section.
    func presentTargetPlatformSettings() {
        refreshTargetBuilds()   // a source dropped in by hand shows on the rows
        requestedSetupSection = .target
        presentProviderSetup()
    }

    var targetPlatformRows: [SZTargetPlatformRow] {
        let nodes = store.project?.graph.nodes ?? []
        let generated = nodes.filter { $0.kind == .generated }.count
        let converting = conversionRunning
        let threeVersion = webRuntime?.threeVersion ?? store.project?.web?.threeVersion ?? SZProjectWeb.currentThreeVersion
        return SZProjectTarget.allCases.map { target in
            let active = store.project != nil && target == projectTarget
            let built = builtNodeCount(for: target)
            return SZTargetPlatformRow(
                id: target,
                name: target == .native ? "This Mac" : "Browser",
                description: target == .native
                    ? "High performance with Metal. Full access to this Mac's hardware, files and accessories."
                    : "Runs in any web browser (desktop or mobile). Limited to browser capabilities.",
                beta: target == .web,
                active: active,
                builtCount: built,
                nodeCount: nodes.count,
                converting: active && converting && conversion?.target == target,
                ready: generated == 0 ? nil : built == generated,
                help: target == .web ? "three.js \(threeVersion)" : nil)
        }
    }

    /// What switching to `target` would do, for the footer while the card is picked.
    func switchPreview(to target: SZProjectTarget) -> String {
        let plan = conversionPlan(for: target)
        let platform = target == .web ? "the browser" : "this Mac"
        if plan.queued.isEmpty && plan.copied.isEmpty {
            return "Every node is built for \(platform). The switch is instant."
        }
        var parts: [String] = []
        if !plan.queued.isEmpty {
            parts.append("converts \(plan.queued.map(\.title).joined(separator: ", ")) with an agent")
        }
        if !plan.copied.isEmpty {
            parts.append("takes \(plan.copied.map(\.title).joined(separator: ", ")) from the library")
        }
        return "Switching " + parts.joined(separator: " and ") + ". Follow the conversion in the chat."
    }

    /// nil when nothing is converting and nothing was: a switch to a fully built platform has no report.
    var conversionReport: SZConversionReport? {
        guard let conversion, let nodes = store.project?.graph.nodes,
              !(conversion.copied.isEmpty && conversion.queued.isEmpty) else { return nil }
        var rows: [SZConversionRow] = []
        for node in nodes {
            if conversion.copied.contains(node.id) {
                rows.append(SZConversionRow(id: node.id, title: node.title,
                                            reason: agentLine(for: node.id) ?? "from the library", outcome: .ready))
            } else if conversion.queued.contains(node.id) {
                rows.append(conversionRow(for: node))
            }
        }
        let unavailable = rows.filter { $0.outcome == .unavailable }.count
        let failed = rows.filter { $0.outcome == .failed }.count
        var summary = Self.nodeCount(rows.count)
        if unavailable > 0 { summary += ", \(unavailable) not available" }
        if failed > 0 { summary += ", \(failed) failed" }
        let running = conversionRunning
        return SZConversionReport(target: conversion.target,
                                  done: rows.filter { $0.outcome == .ready }.count,
                                  total: rows.count,
                                  running: running,
                                  summary: running ? nil : summary,
                                  rows: rows)
    }

    var targetPlatformNote: String {
        guard let project = store.project else { return "No project is open." }
        if let report = conversionReport, report.running {
            return "Converting \(report.done) of \(report.total)."
        }
        // At rest the rows say it all; the page's own status shows while it loads or downloads.
        if project.target == .web, let status = webRuntime?.phase.status { return status }
        return ""
    }

    private static func nodeCount(_ n: Int) -> String { n == 1 ? "1 node" : "\(n) nodes" }

    /// The agent's own status line for a node, one line, cut at about 90 characters.
    private func agentLine(for id: SZNodeID) -> String? {
        guard let message = nodeAgentState[id]?.message
            .split(whereSeparator: \.isNewline).first.map(String.init),
              !message.isEmpty else { return nil }
        return Self.oneLine(message, cap: 89)
    }

    /// The conversion's run is live or still waiting for its claim.
    private var conversionRunning: Bool {
        guard let taskID = conversion?.taskID else { return false }
        return activeRuns[taskID] != nil || pendingTasks.contains { $0.id == taskID }
    }

    /// A queued node's outcome, from its platform flag and the fleet's status line for it.
    private func conversionRow(for node: SZNode) -> SZConversionRow {
        let state = nodeAgentState[node.id]
        let line = agentLine(for: node.id)
        if node.builtForTarget {
            return SZConversionRow(id: node.id, title: node.title, reason: line, outcome: .ready)
        }
        if runWorkSet.contains(node.id) || state?.phase == .coding || state?.phase == .planning {
            return SZConversionRow(id: node.id, title: node.title, reason: line, outcome: .converting)
        }
        switch state?.phase {
        case .needsInput:
            return SZConversionRow(id: node.id, title: node.title, reason: line, outcome: .unavailable)
        case .error:
            return SZConversionRow(id: node.id, title: node.title, reason: line ?? state?.errorDetail, outcome: .failed)
        default:
            return SZConversionRow(id: node.id, title: node.title, reason: line, outcome: .queued)
        }
    }
}
