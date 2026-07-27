// SPDX-License-Identifier: AGPL-3.0-only
// `SZHostBridge.portValue(_:from:)` — the coercion table between a JSON argument and a typed
// `SZPortValue`. It is what stands between an agent's `ui_set_port` call and the store, so every port
// type's accepted form (and its refusal) is pinned here.
import Foundation
import SZCore
import Testing
@testable import SubjectiveZero

@MainActor private func coerce(_ type: SZPortType, _ raw: Any?) throws -> SZPortValue {
    try SZHostBridge.portValue(type, from: raw)
}

// MARK: - numbers

@Test @MainActor func coercesFloats() throws {
    #expect(try coerce(.float, 0.25) == .float(0.25))
    #expect(try coerce(.float, 3) == .float(3))       // an integer literal is a valid float
}

@Test @MainActor func coercesBoolsFromBothBooleansAndNumbers() throws {
    // JSON `true` and a numeric 0/1 both reach here; agents send either.
    #expect(try coerce(.bool, true) == .bool(true))
    #expect(try coerce(.bool, false) == .bool(false))
    #expect(try coerce(.bool, 1) == .bool(true))
    #expect(try coerce(.bool, 0) == .bool(false))
    #expect(try coerce(.bool, 0.5) == .bool(true))    // any non-zero is true
}

// MARK: - vectors, colors, matrices

@Test @MainActor func coercesEveryArrayBackedType() throws {
    #expect(try coerce(.float2, [1, 2]) == .float2([1, 2]))
    #expect(try coerce(.float3, [1, 2, 3]) == .float3([1, 2, 3]))
    #expect(try coerce(.float4, [1, 2, 3, 4]) == .float4([1, 2, 3, 4]))
    #expect(try coerce(.colorRGB, [0.1, 0.2, 0.3]) == .colorRGB([0.1, 0.2, 0.3]))
    #expect(try coerce(.colorRGBA, [0, 0, 0, 1]) == .colorRGBA([0, 0, 0, 1]))
    #expect(try coerce(.float3x3, Array(repeating: 1.0, count: 9)) == .float3x3(Array(repeating: 1.0, count: 9)))
    #expect(try coerce(.float4x4, Array(repeating: 2.0, count: 16)) == .float4x4(Array(repeating: 2.0, count: 16)))
}

@Test @MainActor func arrayCoercionDropsNonNumericEntriesRatherThanRejectingThem() throws {
    // Current behavior, pinned so a change to it is deliberate: a mixed array yields only its numbers,
    // and arity is not checked here (the store owns the port's declared component count).
    #expect(try coerce(.float3, [1, "two", 3]) == .float3([1, 3]))
}

// MARK: - strings and events

@Test @MainActor func coercesStringsAndEnumerations() throws {
    #expect(try coerce(.enumeration, "linear") == .enumeration("linear"))
    #expect(try coerce(.string, "hello") == .string("hello"))
}

@Test @MainActor func anEventCarriesNoPayload() throws {
    // The raw value is ignored — an event port's value IS the firing.
    #expect(try coerce(.event, nil) == .event)
    #expect(try coerce(.event, "anything") == .event)
}

// MARK: - refusals

@Test @MainActor func refusesTheWrongShapeForEachFamily() {
    #expect(throws: SZMCPError.self) { try coerce(.float, "1.5") }
    #expect(throws: SZMCPError.self) { try coerce(.float, nil) }
    #expect(throws: SZMCPError.self) { try coerce(.bool, "true") }
    #expect(throws: SZMCPError.self) { try coerce(.float3, 1.0) }
    #expect(throws: SZMCPError.self) { try coerce(.colorRGBA, "#ff0000") }
    #expect(throws: SZMCPError.self) { try coerce(.string, 12) }
    #expect(throws: SZMCPError.self) { try coerce(.enumeration, 0) }
}

@Test @MainActor func connectionOnlyTypesHaveNoByValueDefault() {
    // `texture` and `floatArray` flow over edges; there is nothing to set by value.
    #expect(throws: SZMCPError.self) { try coerce(.texture, "anything") }
    #expect(throws: SZMCPError.self) { try coerce(.floatArray, [1, 2, 3]) }
}

@Test @MainActor func everyPortTypeIsAccountedFor() throws {
    // A new `SZPortType` case must be given a coercion (or an explicit refusal) — not fall off the table.
    for type in SZPortType.allCases {
        let refused = [SZPortType.texture, .floatArray].contains(type)
        let raw: Any = switch type {
        case .float: 1.0
        case .bool: true
        case .enumeration, .string: "x"
        case .event: 0
        default: [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
        }
        if refused {
            #expect(throws: SZMCPError.self) { try coerce(type, raw) }
        } else {
            #expect(throws: Never.self) { try coerce(type, raw) }
        }
    }
}
