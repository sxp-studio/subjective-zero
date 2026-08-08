// SPDX-License-Identifier: AGPL-3.0-only
// The two SEATS and who holds them — resolved once, at pack load. Deliberately dumb: the
// pack loader (SZAI) decides how a seat gets filled and reports unfilled/contested seats as
// defects; this type only records the outcome, so SZCore and SZUI can speak "the director"
// without knowing how packs load.
import Foundation

/// A seat an agent pack may declare in its `agent.json`. Dispatch targets name seats, never
/// agent ids — the id an author chose stays content.
public enum SZAgentSeat: String, Codable, Sendable, CaseIterable {
    case director
    case coding
}

/// Which agent id holds each seat. nil = the seat is unfilled (or was contested and refused);
/// the loader that produced this value reports the matching defect.
public struct SZSeatAssignment: Codable, Sendable, Equatable {
    public var director: String?
    public var coding: String?

    public init(director: String? = nil, coding: String? = nil) {
        self.director = director
        self.coding = coding
    }

    public subscript(seat: SZAgentSeat) -> String? {
        get {
            switch seat {
            case .director: director
            case .coding: coding
            }
        }
        set {
            switch seat {
            case .director: director = newValue
            case .coding: coding = newValue
            }
        }
    }
}
