// SPDX-License-Identifier: AGPL-3.0-only
// The card-substrate probe: SZToolchain compiles a SwiftUI-importing Card.swift, the host obtains
// a WORKING view across the dylib boundary, hot reload survives, and the outbound verbs cross with
// payloads intact. Nodes cross a C ABI; cards cross SwiftUI object graphs — the unknowns are
// type-metadata co-residency between card dylibs and retiring a module while SwiftUI may still
// hold references into it. Run in isolation first (`swift test --filter SZCardProbeTests`); a
// crash log names the failing phase via the `[card-probe]` markers.
import Testing
import Foundation
import AppKit
@testable import SZRuntime

/// Card source whose fill color tracks `state.title` — render assertions read the color to prove
/// SwiftUI actually ran inside the dylib AND that ObservableObject invalidation crosses the push.
/// `idle`/`go` are Swift color expressions, e.g. `"Color(red: 1, green: 0, blue: 0)"`.
private func probeCardSource(idle: String, go: String) -> String {
    """
    import SwiftUI
    struct Card: View {
        @ObservedObject var state: SZCardState
        var body: some View {
            (state.title == "go" ? \(go) : \(idle))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    enum SZCardMain { static func make(_ state: SZCardState) -> AnyView { AnyView(Card(state: state)) } }
    """
}

private let red = "Color(red: 1, green: 0, blue: 0)"
private let green = "Color(red: 0, green: 1, blue: 0)"
private let blue = "Color(red: 0, green: 0, blue: 1)"

/// Write `source` as `<work>/<tag>/Card.swift`, build + map it as artifact `tag`.
@MainActor
private func buildProbeCard(source: String, work: URL, tag: String) async throws -> SZCardModule {
    let src = work.appending(path: "\(tag)/Card.swift")
    try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
    try source.write(to: src, atomically: true, encoding: .utf8)
    return try await SZCardModule.build(source: src, artifact: tag, workspace: work)
}

@MainActor
private func mounted(_ module: SZCardModule, verbs: SZCardVerbs = SZCardVerbs()) throws -> (SZCardInstance, NSView) {
    let instance = try #require(module.createInstance(verbs: verbs), "module refused to instantiate")
    let pointer = try #require(instance.viewPointer(), "card returned no view pointer")
    let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    return (instance, try #require(object as? NSView, "opaque view pointer is not an NSView"))
}

/// Center pixel of the view rendered to a bitmap, in sRGB. Off-window `cacheDisplay` first; if
/// that yields blank pixels (no window server backing), fall back to a borderless offscreen
/// NSWindow before concluding failure.
@MainActor
private func renderCenterColor(_ view: NSView) throws -> NSColor {
    view.setFrameSize(NSSize(width: 200, height: 100))
    view.layoutSubtreeIfNeeded()
    spinMain(0.1)
    if let color = offWindowCenter(view) { return color }
    print("[card-probe] off-window render blank; retrying inside offscreen NSWindow")
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 200, height: 100),
                          styleMask: .borderless, backing: .buffered, defer: false)
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    window.contentView = view
    window.orderBack(nil)
    view.layoutSubtreeIfNeeded()
    spinMain(0.1)
    return try #require(offWindowCenter(view), "view rendered blank both off-window and in an offscreen window")
}

@MainActor
private func offWindowCenter(_ view: NSView) -> NSColor? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let color = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB),
          color.alphaComponent > 0.5 else { return nil }
    return color
}

/// Let SwiftUI's render loop breathe (state pushes invalidate asynchronously).
@MainActor
private func spinMain(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

private func expectHue(_ color: NSColor, red: Bool = false, green: Bool = false, blue: Bool = false,
                       _ comment: Comment) {
    #expect((color.redComponent > 0.6) == red, comment)
    #expect((color.greenComponent > 0.6) == green, comment)
    #expect((color.blueComponent > 0.6) == blue, comment)
}

private func probeWorkDir(_ name: String) throws -> URL {
    let work = FileManager.default.temporaryDirectory.appending(path: "szcard-probe-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    return work
}

/// Probe 1+2: two card dylibs compile (SwiftUI autolinks from the bare -sdk invocation), map with
/// the version check, hand real NSViews across, render real pixels, take independent state pushes
/// (ObservableObject invalidation crosses), and co-reside without metadata collisions.
@Test @MainActor func twoCardDylibsCompileRenderAndCoReside() async throws {
    let work = try probeWorkDir("coresident")
    defer { try? FileManager.default.removeItem(at: work) }

    print("[card-probe] phase=compile-both")
    let source = probeCardSource(idle: red, go: green)
    let a = try await buildProbeCard(source: source, work: work, tag: "A")
    let b = try await buildProbeCard(source: source, work: work, tag: "B")
    defer {
        a.unload()
        b.unload()
    }

    print("[card-probe] phase=instances")
    let (refA, viewA) = try mounted(a)
    let (refB, viewB) = try mounted(b)

    print("[card-probe] phase=render-both")
    expectHue(try renderCenterColor(viewA), red: true, "A renders")
    expectHue(try renderCenterColor(viewB), red: true, "B renders")

    print("[card-probe] phase=push-both")
    refA.push(channel: "state", json: Data(#"{"title":"go"}"#.utf8))
    spinMain(0.25)
    expectHue(try renderCenterColor(viewA), green: true, "A took its push")
    expectHue(try renderCenterColor(viewB), red: true, "B unaffected by A's push")
    refB.push(channel: "state", json: Data(#"{"title":"go"}"#.utf8))
    spinMain(0.25)
    expectHue(try renderCenterColor(viewB), green: true, "B took its push")
}

/// Probe 3: hot-reload swap while mounted — v2 mounts beside v1, v1's instance is destroyed and
/// its module retired (mapping kept resident, copy unlinked), then more runloop ticks: dangling
/// AttributeGraph/objc_release crashes surface on the next tick, not at retirement.
@Test @MainActor func hotReloadSwapWhileMounted() async throws {
    let work = try probeWorkDir("hotreload")
    defer { try? FileManager.default.removeItem(at: work) }

    print("[card-probe] phase=mount-v1")
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    let v1 = try await buildProbeCard(source: probeCardSource(idle: red, go: green), work: work, tag: "v1")
    let (refV1, viewV1) = try mounted(v1)
    container.addSubview(viewV1)
    expectHue(try renderCenterColor(viewV1), red: true, "v1 renders mounted")

    print("[card-probe] phase=swap")
    let v2 = try await buildProbeCard(source: probeCardSource(idle: blue, go: green), work: work, tag: "v2")
    defer { v2.unload() }
    let (refV2, viewV2) = try mounted(v2)
    container.addSubview(viewV2)
    refV1.destroy()
    viewV1.removeFromSuperview()

    print("[card-probe] phase=retire-v1")
    v1.unload()
    spinMain(0.3)

    print("[card-probe] phase=post-retire-render")
    expectHue(try renderCenterColor(viewV2), blue: true, "v2 renders after v1 retired")
    refV2.push(channel: "state", json: Data(#"{"title":"go"}"#.utf8))
    spinMain(0.3)
    expectHue(try renderCenterColor(viewV2), green: true, "v2 state push works after v1 retired")
    spinMain(0.3)
}

/// Probe 4: the outbound verb surface — live/commit/size cross the boundary into the host's Swift
/// closures with payloads intact, and the typed snapshot accessors decode what the host pushes.
/// The card emits once, during the render pass that sees title == "emit" (deterministic under
/// off-window rendering, unlike onAppear).
@Test @MainActor func verbsRoundTripThroughHostClosures() async throws {
    let work = try probeWorkDir("verbs")
    defer { try? FileManager.default.removeItem(at: work) }

    let source = """
    import SwiftUI
    enum Emitted { static var done = false }
    struct Card: View {
        @ObservedObject var state: SZCardState
        var body: some View {
            if state.title == "emit" && !Emitted.done {
                Emitted.done = true
                let tl = state.input("tl")?.defaultDoubles ?? []
                let gain = state.input("gain")?.defaultDouble ?? -1
                let backdrop = state.backdrop.map { "\\(Int($0.width))x\\(Int($0.height))" } ?? "none"
                let connected = state.connectedInputs.sorted().joined(separator: ",")
                state.live("value", [0.25])
                state.commit("value", [0.5])
                state.live("echo", tl.map(Float.init) + [Float(gain)])
                state.commit("meta", [Float(backdrop == "100x50" ? 1 : 0), Float(connected == "gain" ? 1 : 0)])
                state.call("learn_arm", argsJSON: #"{"port":"x"}"#)
            }
            // Learn telemetry (v2) colours the card: armed+seen ⇒ green, else blue.
            let armed = state.learn?.armed == true && state.learn?.seen == true && state.learn?.key == "ch1/cc7"
            return (armed ? Color(red: 0, green: 1, blue: 0) : Color(red: 0, green: 0, blue: 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    enum SZCardMain { static func make(_ state: SZCardState) -> AnyView { AnyView(Card(state: state)) } }
    """

    print("[card-probe] phase=verbs-compile")
    let module = try await buildProbeCard(source: source, work: work, tag: "verbs")
    defer { module.unload() }

    print("[card-probe] phase=verbs-wire")
    final class Events { var list: [String] = [] }
    let events = Events()
    let (ref, view) = try mounted(module, verbs: SZCardVerbs(
        live: { port, values in events.list.append("live \(port) \(values)") },
        commit: { port, values in events.list.append("commit \(port) \(values)") },
        size: { height in events.list.append("size \(height)") },
        call: { tool, args in events.list.append("call \(tool) \(args)") }))
    _ = try renderCenterColor(view)   // settle the initial render
    // The root wrapper self-reports size on first layout — the card's own verbs must NOT have
    // fired yet.
    #expect(events.list.contains { $0.hasPrefix("size") })
    #expect(!events.list.contains { $0.hasPrefix("live") || $0.hasPrefix("commit") })

    print("[card-probe] phase=verbs-emit")
    ref.push(channel: "state", json: Data("""
    {"title":"emit",
     "inputs":[{"name":"tl","type":"float2","default":[0.25,0.75]},
               {"name":"gain","type":"float","default":0.5}],
     "connectedInputs":["gain"],
     "backdrop":{"x":6,"y":6,"width":100,"height":50}}
    """.utf8))
    spinMain(0.25)
    _ = try renderCenterColor(view)   // the render pass that emits
    spinMain(0.1)

    #expect(events.list.contains("live value [0.25]"))
    #expect(events.list.contains("commit value [0.5]"))
    #expect(events.list.contains("live echo [0.25, 0.75, 0.5]"))
    #expect(events.list.contains("commit meta [1.0, 1.0]"))
    #expect(events.list.contains(#"call learn_arm {"port":"x"}"#))

    print("[card-probe] phase=verbs-learn")
    expectHue(try renderCenterColor(view), blue: true, "blue before learn telemetry")
    ref.push(channel: "telemetry", json: Data(#"{"learn":{"armed":true,"seen":true,"key":"ch1/cc7","value01":0.5}}"#.utf8))
    spinMain(0.25)
    expectHue(try renderCenterColor(view), green: true, "green once armed+seen with the key")
}

// MARK: - The shipped library cards

private var nodeLibraryRoot: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()   // SZRuntimeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // SubjectiveZero (umbrella root)
        .appending(path: "NodeLibrary")
}

/// Every shipped `NodeLibrary/<id>/Card.swift` compiles, maps, instantiates, and renders — the CI
/// stand-in for "instantiating this library node actually mounts its card" (card sources never
/// pass through swift build). Fed a synthetic snapshot covering the shipped cards' ports.
@Test @MainActor func shippedLibraryCardsCompileAndMount() async throws {
    let folders = (try? FileManager.default.contentsOfDirectory(
        at: nodeLibraryRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    let sources = folders.map { $0.appending(path: "Card.swift") }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    try #require(!sources.isEmpty, "no Card.swift under NodeLibrary — the built-in cards moved?")

    let work = try probeWorkDir("library")
    defer { try? FileManager.default.removeItem(at: work) }

    for source in sources {
        let name = source.deletingLastPathComponent().lastPathComponent
        print("[card-probe] phase=library-card \(name)")
        let module = try await SZCardModule.build(source: source, artifact: name, workspace: work)
        defer { module.unload() }
        let (ref, view) = try mounted(module)
        // Feed a snapshot so each card renders its populated path, then draw it.
        ref.push(channel: "state", json: Data("""
        {"id":"t","title":"t",
         "inputs":[{"name":"input","type":"texture"},
                   {"name":"tl","type":"float2","default":[0,0]},{"name":"tr","type":"float2","default":[1,0]},
                   {"name":"br","type":"float2","default":[1,1]},{"name":"bl","type":"float2","default":[0,1]},
                   {"name":"center","type":"float2","default":[0.5,0.5],"ui":{"kind":"slider","min":0,"max":1}},
                   {"name":"radius","type":"float","default":0.6,"ui":{"kind":"slider","min":0,"max":1.5}},
                   {"name":"softness","type":"float","default":0.4,"ui":{"kind":"slider","min":0,"max":1}},
                   {"name":"mappings","type":"string","default":"[{\\"key\\":\\"ch1/cc7\\",\\"port\\":\\"knob\\",\\"min\\":0,\\"max\\":1,\\"label\\":\\"Knob\\"}]"},
                   {"name":"port","type":"float","default":8000}],
         "outputs":[{"name":"output","type":"texture","display":true},{"name":"magnitudes","type":"floatArray"},
                    {"name":"lastEvent","type":"float2"},{"name":"lastKey","type":"string"},{"name":"knob","type":"float"}],
         "connectedInputs":["input"],
         "render":{"width":1280,"height":800},
         "body":{"width":240,"height":120},
         "backdrop":{"x":8,"y":8,"width":224,"height":68}}
        """.utf8))
        ref.push(channel: "telemetry", json: Data(#"{"outputs":{"knob":[0.5]},"learn":{"armed":true,"seen":true,"key":"ch1/cc7","value01":0.5}}"#.utf8))
        spinMain(0.15)
        // Cards are mostly transparent chrome — assert the render pass completes, not a pixel.
        view.setFrameSize(NSSize(width: 240, height: 120))
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        spinMain(0.1)
        ref.destroy()
    }
}
