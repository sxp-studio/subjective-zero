// SPDX-License-Identifier: AGPL-3.0-only
// An enum input's default must be one of its option values: a reversed [label, value] pair leaves the
// node switching on a string the dropdown never sends, and it is the contract that says so.
import Testing
import Foundation
@testable import SZCore

struct SZEnumDefaultTests {
    private func port(default chosen: String, options: [SZEnumOption]) -> SZPort {
        SZPort(name: "mode", type: .enumeration, def: .enumeration(chosen), options: options)
    }

    @Test func aDefaultThatIsAnOptionValueIsFine() {
        let p = port(default: "invert", options: [SZEnumOption(label: "Grayscale", value: "grayscale"),
                                                    SZEnumOption(label: "Invert Colors", value: "invert")])
        #expect(p.enumDefaultProblem == nil)
    }

    @Test func aReversedPairReadsAsADefaultThatIsALabel() {
        let p = port(default: "Grayscale", options: [SZEnumOption(label: "grayscale", value: "Grayscale"),
                                                       SZEnumOption(label: "invert", value: "Invert Colors")])
        #expect(p.enumDefaultProblem == nil, "the default matches a value here, however odd the pair looks")
        let reversed = port(default: "Grayscale", options: [SZEnumOption(label: "Grayscale", value: "grayscale"),
                                                              SZEnumOption(label: "Invert Colors", value: "invert")])
        let problem = try! #require(reversed.enumDefaultProblem)
        #expect(problem.contains("is a label, not a value"))
        #expect(problem.contains("grayscale, invert"))
    }

    @Test func aDefaultOutsideTheOptionsIsNamed() {
        let p = port(default: "sepia", options: [SZEnumOption(value: "grayscale"), SZEnumOption(value: "invert")])
        #expect(p.enumDefaultProblem?.contains("not one of its option values") == true)
        let contract = SZNodeContract(title: "T", sfSymbol: "s", summary: "", inputs: [p])
        #expect(contract.enumDefaultProblems.count == 1)
    }

    @Test func portsWithoutOptionsOrDefaultsAreLeftAlone() {
        #expect(SZPort(name: "mode", type: .enumeration, def: .enumeration("x")).enumDefaultProblem == nil)
        #expect(SZPort(name: "mode", type: .enumeration, options: [SZEnumOption(value: "a")]).enumDefaultProblem == nil)
        #expect(SZPort(name: "amount", type: .float, def: .float(1)).enumDefaultProblem == nil)
    }
}
