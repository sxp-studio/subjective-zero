// SPDX-License-Identifier: AGPL-3.0-only
// The plugs fold's MOTION — the one place the show/hide-plugs action is timed. Geometry lives in
// SZNodeLayout (which stays SwiftUI-free), paint in SZNodeCardStyle; this is the curve every moving
// part obeys: the card's frame and centre, the socket dots gliding to their folded stack, and the
// wires that land on them. One duration for all of them, so nothing arrives ahead of the rows it
// belongs to.
//
// The rows themselves are wiped by the card's own edge — SZNodeView clips its content to the card
// shape, so the shrinking frame uncovers/covers them like a blind. That replaced a collapsing
// transition on the row band: the band kept its full height for the whole animation and spilled the
// labels over the canvas, because a `.modifier` transition attached under the band's padding never
// got driven.
import SwiftUI

enum SZCardFold {
    /// Long enough to read as a drawer closing, short enough that a card you're arranging never
    /// keeps you waiting.
    static let duration: Double = 0.22
    static var animation: Animation { .easeInOut(duration: duration) }
}
