// SPDX-License-Identifier: AGPL-3.0-only
// The slider predicate + clamp (SZPort+Slider.swift) — the ONE rule shared by the editor slider, the
// node width model, and the `ui_set_input_default` MCP path. Moved here from SZUITests when the
// predicate moved down to the model layer: it constrains what the *model* may hold, not how a view draws.
import Testing
@testable import SZCore

// MARK: - stepped (range-anchored, clamped)

@Test func steppedAnchorsAtLowerBoundAndClampsIntoRange() {
    // max 1 with step 0.15: naive zero-anchored rounding gives 1.05 — must clamp to 1.0.
    #expect(SZPort.stepped(1.0, in: 0...1, step: 0.15) == 1.0)
    // min 0.05 with step 0.1: a zero anchor would emit 0.0, below the declared minimum.
    #expect(SZPort.stepped(0.0, in: 0.05...1, step: 0.1) == 0.05)
    // Steps count from the lower bound, not zero.
    #expect(abs(SZPort.stepped(0.31, in: 0.05...1, step: 0.1) - 0.35) < 1e-9)
}

@Test func steppedDefaultsToHundredthsWhenStepUndeclared() {
    #expect(abs(SZPort.stepped(0.34748291969299316, in: 0...1, step: nil) - 0.35) < 1e-9)
}

@Test func steppedWithNonPositiveStepClampsWithoutSnapping() {
    #expect(SZPort.stepped(7.5, in: 0...5, step: 0) == 5.0)
    #expect(abs(SZPort.stepped(1.234, in: 0...5, step: -1) - 1.234) < 1e-9)
}

// MARK: - sliderRange

@Test func sliderRangeRequiresSliderKindAndValidBounds() {
    let ui = SZPortUI(kind: .slider, min: 0, max: 5, step: 0.1)
    #expect(SZPort(name: "speed", type: .float, ui: ui).sliderRange == 0...5)
    // A field-kind port is free-form even when it declares bounds.
    #expect(SZPort(name: "n", type: .float, ui: SZPortUI(kind: .field, min: 0, max: 5)).sliderRange == nil)
    // No ui at all.
    #expect(SZPort(name: "n", type: .float).sliderRange == nil)
    // Degenerate / half-declared bounds fall back to numeric fields.
    #expect(SZPort(name: "n", type: .float, ui: SZPortUI(kind: .slider, min: 5, max: 5)).sliderRange == nil)
    #expect(SZPort(name: "n", type: .float, ui: SZPortUI(kind: .slider, min: 5, max: 0)).sliderRange == nil)
    #expect(SZPort(name: "n", type: .float, ui: SZPortUI(kind: .slider, min: 0)).sliderRange == nil)
    #expect(SZPort(name: "n", type: .float, ui: SZPortUI(kind: .slider, max: 5)).sliderRange == nil)
}

// MARK: - clampedDefault (what `ui_set_input_default` must not be able to bypass)

/// The real animated-gradient `speed` port: the value an MCP caller could previously store verbatim.
private let speed = SZPort(name: "speed", type: .float,
                           ui: SZPortUI(kind: .slider, min: 0, max: 5, step: 0.1), def: .float(1.0))

@Test func clampedDefaultBoundsAScalarToTheSliderRange() {
    #expect(speed.clampedDefault(.float(100)) == .float(5.0))
    #expect(speed.clampedDefault(.float(-10)) == .float(0.0))
}

@Test func clampedDefaultSnapsToTheDeclaredStep() {
    guard case .float(let v) = speed.clampedDefault(.float(1.234)) else { Issue.record("not a float"); return }
    #expect(abs(v - 1.2) < 1e-9)
}

@Test func clampedDefaultIsIdempotent() {
    let once = speed.clampedDefault(.float(100))
    #expect(speed.clampedDefault(once) == once)
}

/// The host clamps, pushes that value to the runtime, and echoes it; the store then clamps AGAIN before
/// persisting. If the two disagree the render and the contract drift. They disagree whenever a bound is
/// off the step grid — snapping first maps 100 onto the bound 1.0, and re-snapping the bound lands back
/// inside the range at 0.9. Clamping before snapping makes the function a fixed point on its own output.
@Test func steppedIsAFixedPointEvenWhenABoundIsOffTheStepGrid() {
    for (range, step) in [(0.0...1.0, 0.3), (0.0...10.0, 3.0), (0.05...1.0, 0.1), (0.0...1.0, 0.15)] {
        let once = SZPort.stepped(100, in: range, step: step)
        #expect(SZPort.stepped(once, in: range, step: step) == once,
                "stepped is not idempotent for \(range) step \(step): \(once)")
        #expect(range.contains(once))
        let low = SZPort.stepped(-100, in: range, step: step)
        #expect(SZPort.stepped(low, in: range, step: step) == low)
        #expect(range.contains(low))
    }
}

@Test func clampedDefaultIsIdempotentOnAnOffGridPort() {
    let port = SZPort(name: "mix", type: .float, ui: SZPortUI(kind: .slider, min: 0, max: 1, step: 0.3))
    let once = port.clampedDefault(.float(100))
    #expect(port.clampedDefault(once) == once)
    guard case .float(let v) = once else { Issue.record("not a float"); return }
    #expect(v <= 1.0)
}

@Test func clampedDefaultLeavesUnboundedAndNonScalarValuesAlone() {
    // Free-form numeric field: no bounds to enforce even though min/max are declared.
    let field = SZPort(name: "n", type: .float, ui: SZPortUI(kind: .field, min: 0, max: 5))
    #expect(field.clampedDefault(.float(100)) == .float(100))
    // Slider kind with a degenerate range renders as numeric fields → untouched.
    let degenerate = SZPort(name: "n", type: .float, ui: SZPortUI(kind: .slider, min: 5, max: 5))
    #expect(degenerate.clampedDefault(.float(100)) == .float(100))
    // A non-scalar value on a slider-kind port is passed through rather than mangled.
    #expect(speed.clampedDefault(.float3([9, 9, 9])) == .float3([9, 9, 9]))
    #expect(speed.clampedDefault(.bool(true)) == .bool(true))
}
