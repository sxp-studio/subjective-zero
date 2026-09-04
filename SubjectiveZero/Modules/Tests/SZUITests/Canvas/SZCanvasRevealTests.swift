// SPDX-License-Identifier: AGPL-3.0-only
// The reveal rule — the canvas belongs to whoever touched it last — pinned headlessly.
import Foundation
import Testing
@testable import SZUI

private let asked = Date(timeIntervalSinceReferenceDate: 1000)

@Test func agentMayMoveWhenTheUserHasNotTouchedTheCanvasSinceAsking() {
    #expect(SZCanvasReveal.mayMove(userTouchedAt: nil, askedAt: asked, interacting: false))
    #expect(SZCanvasReveal.mayMove(userTouchedAt: asked.addingTimeInterval(-5), askedAt: asked,
                                   interacting: false))
}

@Test func aTouchAfterTheAskHoldsTheCamera() {
    #expect(!SZCanvasReveal.mayMove(userTouchedAt: asked.addingTimeInterval(1), askedAt: asked,
                                    interacting: false))
}

@Test func noAskMeansNoMove() {
    #expect(!SZCanvasReveal.mayMove(userTouchedAt: nil, askedAt: nil, interacting: false))
}

@Test func anInteractionInFlightAlwaysHolds() {
    #expect(!SZCanvasReveal.mayMove(userTouchedAt: nil, askedAt: asked, interacting: true))
}
