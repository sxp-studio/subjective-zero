// SPDX-License-Identifier: AGPL-3.0-only
// Portable by default, and a node declares a limitation rather than a capability. The file on disk
// is the evidence; the contract only explains a file that will never be written. Also the gate that
// stops a shipped library saying both at once.
import Foundation
import Testing
@testable import SZCore

private let libraryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()   // SZCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // Modules
    .deletingLastPathComponent()   // SubjectiveZero
    .appending(path: "NodeLibrary")

private func shippedNodeFolders() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: libraryRoot, includingPropertiesForKeys: nil)
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
}

@Test func aFileForThePlatformMeansItRuns() {
    #expect(SZLibraryPortability.of(target: .web, builtTargets: [.native, .web], unsupported: nil) == .runs)
    #expect(SZLibraryPortability.of(target: .native, builtTargets: [.native], unsupported: nil) == .runs)
}

@Test func noFileAndNoWordMeansSomebodyHasToWriteIt() {
    #expect(SZLibraryPortability.of(target: .web, builtTargets: [.native], unsupported: nil) == .portable)
    // An empty reason is not a reason: it degrades to portable rather than a wall nobody can read.
    #expect(SZLibraryPortability.of(target: .web, builtTargets: [.native], unsupported: ["web": ""]) == .portable)
    // A wall on the OTHER platform says nothing about this one.
    #expect(SZLibraryPortability.of(target: .web, builtTargets: [.native],
                                    unsupported: ["native": "nope"]) == .portable)
}

@Test func aDeclaredWallCarriesItsReason() {
    let portability = SZLibraryPortability.of(
        target: .web, builtTargets: [.native], unsupported: ["web": "A browser has no raw UDP."])
    #expect(portability == .unsupported(reason: "A browser has no raw UDP."))
    #expect(portability.wall == "A browser has no raw UDP.")
    #expect(SZLibraryPortability.runs.wall == nil)
    #expect(SZLibraryPortability.portable.wall == nil)
}

@Test func theFileWinsOverAContractThatContradictsIt() {
    // Both say something about `web`, and the file is the one that is evidence.
    let both = SZLibraryPortability.of(target: .web, builtTargets: [.native, .web],
                                       unsupported: ["web": "it can't"])
    #expect(both == .runs)
    #expect(SZLibraryPortability.contradictions(builtTargets: [.native, .web],
                                                unsupported: ["web": "it can't"]) == [.web])
    #expect(SZLibraryPortability.contradictions(builtTargets: [.native],
                                                unsupported: ["web": "it can't"]).isEmpty)
    #expect(SZLibraryPortability.contradictions(builtTargets: [.native, .web], unsupported: nil).isEmpty)
}

@Test func noShippedNodeDeclaresAWallItAlsoShipsAFileFor() throws {
    let folders = try shippedNodeFolders()
    #expect(folders.count > 20, "the shipped library moved? found \(folders.count)")
    for folder in folders {
        let contract = try JSONDecoder().decode(
            SZNodeContract.self, from: Data(contentsOf: folder.appending(path: "node-contract.json")))
        let built = Set(SZProjectTarget.allCases.filter {
            FileManager.default.fileExists(atPath: folder.appending(path: $0.sourceFileName).path)
        })
        #expect(SZLibraryPortability.contradictions(builtTargets: built,
                                                    unsupported: contract.unsupported).isEmpty,
                "\(folder.lastPathComponent) says a platform is impossible and ships its source anyway")
    }
}

@Test func onlyTheTwoRealWallsAreDeclared() throws {
    var walls: [String: [String]] = [:]
    for folder in try shippedNodeFolders() {
        let contract = try JSONDecoder().decode(
            SZNodeContract.self, from: Data(contentsOf: folder.appending(path: "node-contract.json")))
        if let unsupported = contract.unsupported, !unsupported.isEmpty {
            walls[folder.lastPathComponent] = unsupported.keys.sorted()
        }
    }
    // Everything else with a missing source is a porting backlog, not a wall. Adding a third needs a
    // reason good enough to change this line.
    #expect(walls == ["system-audio.macos": ["web"], "osc-input": ["web"]], "declared walls: \(walls)")
}

/// `placeName` is a mid-sentence PHRASE ("in a browser"), not an adjective. Dropped into a sentence
/// as if it were one it reads "No in a browser version yet" — which shipped once, in four strings,
/// and was written again in a fifth while fixing the first four. So the guard reads the sources.
@Test func noStringTreatsPlaceNameAsAnAdjective() throws {
    #expect(SZProjectTarget.web.placeName == "in a browser")
    #expect(SZProjectTarget.native.placeName == "on this Mac")

    let umbrella = libraryRoot.deletingLastPathComponent()
    let roots = ["SZApp", "Modules/Sources"].map { umbrella.appending(path: $0) }
    // A word that can only precede a noun: "no <x> version", "a <x> version". A phrase needs a verb
    // or a preposition in front of it instead ("run in a browser", "came from on this Mac" is not a
    // sentence anyone writes).
    let articles = ["no", "No", "a", "A", "an", "An", "the", "The", "any", "Any"]
    var offenders: [String] = []
    for root in roots {
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
        for case let url as URL in walk where url.pathExtension == "swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard let range = line.range(of: "\\(") , line[range.upperBound...].hasPrefix2("placeName") else { continue }
                // The token before the interpolation still carries the opening quote ("No), so trim
                // to letters before comparing — that is exactly what let the first version through.
                let raw = line[..<range.lowerBound].split(separator: " ").last.map(String.init) ?? ""
                let before = raw.filter(\.isLetter)
                if articles.contains(before) {
                    offenders.append("\(url.lastPathComponent):\(n + 1) — \"\(before) \\(…placeName)\"")
                }
            }
        }
    }
    #expect(offenders.isEmpty, "placeName used as an adjective: \(offenders)")
}

private extension Substring {
    /// Whether the interpolation that starts here resolves to `placeName`, allowing a receiver.
    func hasPrefix2(_ needle: String) -> Bool {
        guard let close = firstIndex(of: ")") else { return false }
        return self[..<close].hasSuffix(needle)
    }
}
