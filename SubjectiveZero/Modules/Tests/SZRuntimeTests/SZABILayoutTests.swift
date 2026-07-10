// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
@testable import SZRuntime

/// Golden-layout guard for the node ABI (`SZRuntimeContextRaw`). The host fills this struct and passes a
/// **raw pointer**; each node reinterprets the bytes through its **byte-identical mirror copy** inside
/// `SZRuntimeSupport.source`. Field meaning is encoded purely by declaration order — there is no
/// serialization — so the two copies MUST stay in lockstep, and fields must only ever be **appended**.
///
/// The loader's version-symbol check catches a stale dylib but NOT a layout change: reordering two
/// same-width fields (e.g. `inputValueFn` ⇄ `inputStringFn`) keeps size/stride/version identical yet makes
/// the node call the wrong resolver and silently misread bytes. These tests turn that discipline into a CI
/// tripwire by anchoring BOTH copies to one canonical field list: the host via reflection + pinned offsets,
/// the mirror via textual extraction. A reorder/insert/drift in either copy fails here, loudly, at build
/// time — instead of as garbage floats or a Metal-pointer-called-as-a-function crash at runtime.
///
/// When you legitimately extend the ABI: APPEND the field to both copies, then add it to `canonicalFields`
/// and bump the pinned `stride`/offsets below to the new (larger) values. Never insert or reorder.

/// The single source of truth: every field of `SZRuntimeContextRaw`, in declaration order, as
/// `(name, type)`. Both struct copies must match this exactly.
private let canonicalFields: [(name: String, type: String)] = [
    ("apiVersion", "Int32"),
    ("frameIndex", "UInt64"),
    ("viewportWidth", "UInt32"),
    ("viewportHeight", "UInt32"),
    ("timeSeconds", "Double"),
    ("device", "UnsafeMutableRawPointer?"),
    ("commandBuffer", "UnsafeMutableRawPointer?"),
    ("resolverContext", "UnsafeMutableRawPointer?"),
    ("inputTextureFn", "SZTextureResolver?"),
    ("outputTextureFn", "SZTextureResolver?"),
    ("inputValueFn", "SZValueResolver?"),
    ("inputStringFn", "SZStringResolver?"),
    ("outputValueFn", "SZOutputValueResolver?"),   // v5
    ("frameHoldFn", "SZFrameHoldFn?"),             // v6 — last field
]

@Test func abiHostStructMatchesCanonicalLayout() {
    // Size/stride pinned: appending the v6 fn pointer grew the struct to 104 bytes (8-aligned).
    // Any insert/reorder of the pointer block, or a field type change, moves this.
    #expect(MemoryLayout<SZRuntimeContextRaw>.stride == 104)
    #expect(MemoryLayout<SZRuntimeContextRaw>.alignment == 8)

    // Pin the offsets of the same-width fn-pointer fields — the exact case stride alone can't catch.
    #expect(MemoryLayout<SZRuntimeContextRaw>.offset(of: \.inputTextureFn) == 56)
    #expect(MemoryLayout<SZRuntimeContextRaw>.offset(of: \.outputTextureFn) == 64)
    #expect(MemoryLayout<SZRuntimeContextRaw>.offset(of: \.inputValueFn) == 72)
    #expect(MemoryLayout<SZRuntimeContextRaw>.offset(of: \.inputStringFn) == 80)
    #expect(MemoryLayout<SZRuntimeContextRaw>.offset(of: \.outputValueFn) == 88)
    #expect(MemoryLayout<SZRuntimeContextRaw>.offset(of: \.frameHoldFn) == 96)

    // Reflect the host struct's field NAMES + order and assert they match the canonical list.
    let hostNames = Mirror(reflecting: SZRuntimeContextRaw()).children.map { $0.label ?? "?" }
    #expect(hostNames == canonicalFields.map(\.name))
}

@Test func abiMirrorCopyMatchesHostStruct() {
    // Extract the mirror `struct SZRuntimeContextRaw { … }` from the host-injected support source and assert
    // its (name, type) field list is byte-for-byte the canonical one — i.e. it can't drift from the host.
    let fields = extractMirrorStructFields(from: SZRuntimeSupport.source)
    #expect(fields.count == canonicalFields.count)
    for (got, want) in zip(fields, canonicalFields) {
        #expect(got.name == want.name, "mirror field name drift: \(got) vs \(want)")
        #expect(got.type == want.type, "mirror field type drift on \(got.name): \(got.type) vs \(want.type)")
    }
}

/// Parse the `var name: Type` lines of the mirror `SZRuntimeContextRaw` declaration out of the support
/// source string. Returns them in declaration order. Deliberately simple (the mirror copy carries no inline
/// comments or defaults) — a parse miss surfaces as a count mismatch in the test above.
private func extractMirrorStructFields(from source: String) -> [(name: String, type: String)] {
    let lines = source.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0.contains("struct SZRuntimeContextRaw {") }) else { return [] }
    var fields: [(String, String)] = []
    for line in lines[(start + 1)...] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "}" { break }
        guard trimmed.hasPrefix("var "), let colon = trimmed.firstIndex(of: ":") else { continue }
        let name = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<colon]
            .trimmingCharacters(in: .whitespaces)
        let type = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        fields.append((name, type))
    }
    return fields
}
