// SPDX-License-Identifier: AGPL-3.0-only
// The one place the runtime tests decide what "no GPU" means.
//
// These tests need a Metal device. Every one of them used to open with
// `guard let runtime = SZRuntime(...) else { return }  // no GPU → skip`, which conflated two very
// different outcomes into the same silent green:
//
//   1. no Metal device at all — a property of the HOST (a headless CI runner). Not a defect. Skip.
//   2. a device exists but `SZRuntime.init?` still returned nil — `makeCommandQueue()` failed
//      (SZAssetManager.swift:27-28). That IS a defect, and `else { return }` reported it as a pass.
//
// So: gate the test on (1) with `.enabled(if:)`, which Swift Testing reports as *skipped* rather than
// passed, and let (2) fail loudly through `requireRuntime`. An absent GPU is now visible in the run
// summary instead of masquerading as coverage.
import Foundation
import Metal
import Testing
@testable import SZRuntime

enum SZGPU {
    /// Whether this host has a Metal device at all. Evaluated once — `.enabled(if:)` is checked per test.
    static let isAvailable: Bool = MTLCreateSystemDefaultDevice() != nil
}

/// A runtime for a test that has already passed the `.enabled(if: SZGPU.isAvailable)` gate. If the device
/// is there and this still returns nil, the command queue failed — fail, don't skip.
func requireRuntime(renderSize: (width: Int, height: Int),
                    sourceLocation: SourceLocation = #_sourceLocation) throws -> SZRuntime {
    try #require(SZRuntime(renderSize: renderSize),
                 "a Metal device is present but SZRuntime.init returned nil — makeCommandQueue() failed",
                 sourceLocation: sourceLocation)
}
