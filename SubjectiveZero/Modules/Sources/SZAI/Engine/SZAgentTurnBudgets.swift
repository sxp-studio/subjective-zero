// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Per-agent-turn budgets, in seconds — ONE pair for every lane (implement, node chat/edit,
/// Director run turns): same agents, same work. The working bound is SILENCE, not wall clock: a
/// turn dies after `codingInactivityTimeout` with no output (every streamed byte resets
/// the clock), so an agent that is still visibly working is never cut off —
/// `codingTimeout` remains the hard cap for a CLI that wedges while still emitting.
/// Overridable via `SZ_AGENT_TIMEOUT` / `SZ_AGENT_INACTIVITY_TIMEOUT`.
///
/// This holds only while the adapter streams DURING generation, not just at the end of it: a CLI
/// that goes quiet while writing a node trips the budget on file size alone. Every adapter owes
/// that audit — see `--include-partial-messages` in SZClaudeProvider.
public enum SZAgentTurnBudgets {
    public static var codingTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["SZ_AGENT_TIMEOUT"].flatMap(TimeInterval.init) ?? 900
    }

    public static var codingInactivityTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["SZ_AGENT_INACTIVITY_TIMEOUT"].flatMap(TimeInterval.init) ?? 120
    }
}
