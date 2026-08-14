// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Per-coding-turn budgets, in seconds. The working bound is SILENCE, not wall clock: a
/// turn dies after `codingInactivityTimeout` with no output (every streamed chunk resets
/// the clock), so a large node whose agent is still visibly working is never cut off —
/// `codingTimeout` remains the hard cap for a CLI that wedges while still emitting.
/// Overridable via `SZ_AGENT_TIMEOUT` / `SZ_AGENT_INACTIVITY_TIMEOUT`.
public enum SZAgentTurnBudgets {
    public static var codingTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["SZ_AGENT_TIMEOUT"].flatMap(TimeInterval.init) ?? 900
    }

    public static var codingInactivityTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["SZ_AGENT_INACTIVITY_TIMEOUT"].flatMap(TimeInterval.init) ?? 120
    }
}
