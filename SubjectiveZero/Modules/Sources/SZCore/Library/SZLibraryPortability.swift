// SPDX-License-Identifier: AGPL-3.0-only
// Whether a library node runs on a platform, could, or never will — one rule, read by the Library
// panel and by the agents' index so the two can never disagree.
//
// The source file on disk is the only evidence a node runs somewhere, and it wins over anything the
// contract says. All the contract adds is why a file that is missing is never going to be written.
import Foundation

/// What a node can do on one platform.
public enum SZLibraryPortability: Hashable, Sendable {
    /// The node has a source file for this platform. Placing it copies the file and nothing else.
    case runs
    /// No source file yet, and nothing says one cannot exist. Somebody has to write it.
    case portable
    /// It will never run here, and this is why, in words for a person.
    case unsupported(reason: String)

    /// Why a node will never run here, or nil.
    public var wall: String? {
        if case .unsupported(let reason) = self { return reason }
        return nil
    }

    /// `builtTargets` is which platforms the node actually has a file for (its folder plus any port
    /// written into the overlay); `unsupported` is its contract's. A declared wall on a target the
    /// node ships a file for is ignored here, because the file is the evidence — `contradictions`
    /// is what tells the author about it.
    public static func of(target: SZProjectTarget, builtTargets: Set<SZProjectTarget>,
                          unsupported: [String: String]?) -> SZLibraryPortability {
        if builtTargets.contains(target) { return .runs }
        if let reason = unsupported?[target.rawValue], !reason.isEmpty { return .unsupported(reason: reason) }
        return .portable
    }

    /// Targets a contract calls unsupported while shipping their source file. Always empty in a
    /// library anyone should ship; a test is what makes that true.
    public static func contradictions(builtTargets: Set<SZProjectTarget>,
                                      unsupported: [String: String]?) -> [SZProjectTarget] {
        guard let unsupported else { return [] }
        return SZProjectTarget.allCases
            .filter { builtTargets.contains($0) && !(unsupported[$0.rawValue] ?? "").isEmpty }
    }
}
