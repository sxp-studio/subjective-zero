// SPDX-License-Identifier: AGPL-3.0-only
// The SZFactGen CLI the build-tool plugin invokes: `szfactgen <catalog|facts-section>
// <SZFacts.swift> <output.swift>`. All the logic lives in SZFactGenCore (which the tests
// import); this file only does IO and turns grammar failures into `path:line: error:`
// diagnostics so Xcode and SwiftPM surface them on the offending spec line.
import Foundation
import SZFactGenCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("error: SZFactGen: usage: szfactgen <catalog|facts-section> <input SZFacts.swift> <output.swift>")
}
let mode = arguments[1]
let inputPath = arguments[2]
let outputPath = arguments[3]

let source: String
do {
    source = try String(contentsOfFile: inputPath, encoding: .utf8)
} catch {
    fail("\(inputPath):1: error: SZFactGen: cannot read the spec: \(error)")
}

do {
    let output: String
    switch mode {
    case "catalog": output = try SZFactGen.catalogSource(from: source)
    case "facts-section": output = try SZFactGen.factsSectionSource(from: source)
    default: fail("error: SZFactGen: unknown mode '\(mode)' (expected catalog or facts-section)")
    }
    try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
} catch let failure as SZFactGenFailure {
    fail("\(inputPath):\(failure.line ?? 1): error: \(failure.description)")
} catch {
    fail("\(inputPath):1: error: SZFactGen: \(error)")
}
