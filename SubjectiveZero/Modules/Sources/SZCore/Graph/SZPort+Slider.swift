// SPDX-License-Identifier: AGPL-3.0-only
// The slider predicate + its clamp — the ONE rule for what a slider-kind port accepts, shared by the
// editor control (SZUI), the node width model (SZUI), and the `ui_set_input_default` MCP path (SZApp).
// It lives in SZCore, next to SZPort/SZPortUI, because it is a property of the *model*, not of any one
// view: a value a human slider can't produce must not be reachable through the agent surface either.
import Foundation

extension SZPort {
    /// This port's slider range IF it renders as a slider: `ui.kind == .slider` AND a valid `min < max`.
    /// A slider-kind port without a valid range renders (and is measured) as numeric fields, which are
    /// free-form — so `nil` here means "no bounds to enforce", not "bounds of zero width".
    public var sliderRange: ClosedRange<Double>? {
        guard let ui, ui.kind == .slider, let lo = ui.min, let hi = ui.max, lo < hi else { return nil }
        return lo...hi
    }

    /// Snap a slider value to the port's step — 0.01 when undeclared, matching the old `Slider(step:)`
    /// default so step-less sliders keep persisting grid values. Steps anchor at the range's LOWER
    /// BOUND and the result clamps into the range: a zero anchor can emit values the range never
    /// contains (min 0.05, step 0.1 → 0.0; max 1, step 0.15 → 1.05).
    ///
    /// Clamp BEFORE snapping, so the function is a fixed point on its own output. Snapping first would
    /// map an out-of-range value onto a bound, and a bound that isn't itself on the step grid snaps back
    /// INTO the range on a second application (0…1 step 0.3: 100 → 1.0 → 0.9). Two callers clamp in
    /// sequence — the host, to push the same value to the runtime it persists — so a non-idempotent snap
    /// would render one value and store another.
    public static func stepped(_ v: Double, in range: ClosedRange<Double>, step: Double?) -> Double {
        // NaN survives min/max and would poison the runtime push and the contract's JSON encode. No live
        // caller can produce it today (JSONSerialization rejects NaN; the slider is finite), so this is a
        // guard against a future one, not a fix for a reachable bug.
        guard v.isFinite else { return range.lowerBound }
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        let s = step ?? 0.01
        guard s > 0 else { return clamped }
        let snapped = range.lowerBound + ((clamped - range.lowerBound) / s).rounded() * s
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    /// A default value constrained to what this port's control can actually produce. Only a scalar on a
    /// slider-kind port has bounds; everything else (numeric fields, toggles, dropdowns, colors) is
    /// free-form in the editor and passes through untouched. Idempotent, so applying it twice is safe.
    public func clampedDefault(_ value: SZPortValue) -> SZPortValue {
        guard let range = sliderRange, case .float(let v) = value else { return value }
        return .float(Self.stepped(v, in: range, step: ui?.step))
    }
}
