// SPDX-License-Identifier: AGPL-3.0-only
// The run's presence in the transcript, pinned between the messages and the composer while a run is
// in flight. It exists because a run outlives the Director's own turn: the graph's dispatch node
// waits on the fleet, so the Director's turn finishes ("Worked for 24s") and its tab dot goes out
// while the build is still very much running. Until this, the only surviving cue was the Stop.
//
// It shows the SAME sub-agent lanes the Agent Graph draws under a dispatch card
// (`SZAgentSubagentLane`, reused verbatim) — who is working, the node they are on right now, their
// clock, and the pulsing live badge — so the two surfaces are one picture at two zoom levels.
// Every lane is a door into that agent's own run.
//
// Presence, not a lock: the composer stays live throughout and a send simply queues. Deliberately
// OUTSIDE the transcript's ScrollView — a run is a state, not a message, so it must not enter the
// LazyVStack (where it would perturb the bottom-pin anchor) nor scroll away when reading history.
import SwiftUI
import SZCore

struct SZRunStrip: View {
    /// The live thread's dispatched work, oldest first (`SZAgentGraphRun.workChildren`). Empty
    /// before the Director has dispatched anything — the run is real, the fleet is not out yet.
    let lanes: [SZAgentGraphRun]
    /// A lane's work-node title; nil falls the lane back to the node id, as on the canvas.
    let title: (String) -> String?
    /// The run's wall-clock start, for the fallback line's ticker. nil = no anchor, no timer.
    let since: Date?
    /// Open a run in the Agent Graph panel. nil = the surface isn't wired; the strip is a readout.
    let onOpen: ((UUID) -> Void)?
    /// The leader record, for the fallback line's link. nil = nothing to land on yet.
    let threadID: UUID?

    /// Past this many lanes the strip would own more of the panel than the conversation does; the
    /// rest are one honest line rather than a silent truncation.
    private static let laneCap = 4

    private var shown: [SZAgentGraphRun] { Array(lanes.prefix(Self.laneCap)) }
    private var hidden: Int { max(0, lanes.count - Self.laneCap) }

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.08))
            VStack(spacing: SZAgentGraphLayout.laneGap) {
                if lanes.isEmpty {
                    waitingLine
                } else {
                    ForEach(shown) { run in
                        SZAgentSubagentLane(run: run,
                                            title: run.work.flatMap(title),
                                            action: { onOpen?(run.id) })
                            .frame(height: SZAgentGraphLayout.laneHeight)
                    }
                    if hidden > 0 {
                        Text("+\(hidden) more")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    /// Before the fleet goes out — the Director is deciding, and the run is still the thing in
    /// flight. Quiet by design: the Director's own turn is already streaming in the transcript
    /// right above, and this must not shout over it.
    private var waitingLine: some View {
        HStack(spacing: 6) {
            // The same dot as a working tab (SZChatPanel.tabActivityDot), cadence included, so the
            // strip and the tab strip read as one state rather than two opinions.
            SZPulsingOpacity(range: 0.35...0.95, halfPeriod: 0.79) {
                Circle().fill(SZNodeStatus.building.color).frame(width: 4.5, height: 4.5)
            }
            Text("graph running")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            if let since {
                Text("·")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.quaternary)
                SZElapsedLabel(since: since)
            }
            Spacer(minLength: 0)
        }
        .frame(height: SZAgentGraphLayout.laneHeight)
        .contentShape(Rectangle())
        .onTapGesture { if let threadID { onOpen?(threadID) } }
        .help(threadID != nil ? "Open this run in the Agent Graph" : "")
    }
}

/// A run narration's way back into its record. Its OWN view because `SZChatTurnRow` is value-only
/// for the synthesized `==` behind its `.equatable()` render skip — an `@Environment` stored
/// property there would break the conformance. Same split the Profiler's link already uses.
struct SZRunLinkCaption: View {
    let runID: UUID
    @Environment(\.szRevealInAgentGraph) private var revealInAgentGraph

    var body: some View {
        if let revealInAgentGraph {
            SZCaptionActionButton(label: "agent graph",
                                  icon: "point.3.filled.connected.trianglepath.dotted",
                                  help: "Open this run in the Agent Graph") {
                revealInAgentGraph(runID)
            }
        }
    }
}
