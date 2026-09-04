// SPDX-License-Identifier: AGPL-3.0-only
// The web project's app-side pieces that need no page: the JavaScriptCore parse gate, the three.js
// pin table, and the standalone export.
import Foundation
import SZCore
import Testing
@testable import SubjectiveZero

@Suite("Web project")
struct SZWebProjectTests {
    static let fixture = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Modules/Tests/Fixtures/Projects/web-gradient.subz")

    @Test func parseGateReportsASyntaxErrorWithItsLine() {
        let source = "export default class Node {\n  update(ctx) {\n    const out = ctx.outputTexture(\"output\")\n  }\n}\nthis is not javascript {"
        guard case .failed(let message) = SZWebNodeCheck.parse(source: source) else {
            Issue.record("a broken file passed the parse")
            return
        }
        #expect(message.contains("SyntaxError"))
        #expect(message.contains("line 6"))
    }

    @Test func parseGateRefusesImports() {
        let source = "import * as THREE from 'three';\nexport default class Node { update(ctx) {} }"
        guard case .failed(let message) = SZWebNodeCheck.parse(source: source) else {
            Issue.record("an import passed the parse")
            return
        }
        #expect(message.contains("line 1"))
        #expect(message.contains("ctx.three"))
    }

    @Test func parseGateAcceptsAGoodNode() {
        let source = "export default class Node {\n  setup(ctx) {}\n  update(ctx) { const out = ctx.outputTexture(\"output\"); if (!out) return; }\n}"
        #expect(SZWebNodeCheck.parse(source: source) == .ok)
    }

    @Test func theDefaultThreeVersionIsPinned() {
        #expect(SZWebLibraryStore.known[SZProjectWeb.currentThreeVersion] != nil)
        #expect(SZWebLibraryStore.sha256(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func exportIsOneSelfContainedPage() throws {
        let project = try SZProjectIO.load(from: Self.fixture)
        #expect(project.target == .web)
        let library = FileManager.default.temporaryDirectory.appending(path: "sz-three-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: library) }
        try "import{v}from\"./three.core.min.js\";export const Texture=class{};export{v};"
            .write(to: library.appending(path: SZWebLibraryStore.moduleFile), atomically: true, encoding: .utf8)
        try "export const v=1;".write(to: library.appending(path: SZWebLibraryStore.coreFile), atomically: true, encoding: .utf8)
        let page = try SZWebAppExport.page(project: project, projectURL: Self.fixture,
                                           runtimeDirectory: SZWebRuntime.runtimeDirectory,
                                           libraryDirectory: library)
        #expect(!page.contains("subz://"))
        #expect(page.contains("\"three\": \"data:text/javascript;base64,"))
        #expect(page.contains("\"three-core\": \"data:text/javascript;base64,"))
        #expect(page.contains("window.sz = Object.freeze({ onMessage: () => {}, post: () => {}, boot: {"))
        #expect(page.contains("\"sourceURL\":\"data:text\\/javascript;base64,")
                || page.contains("\"sourceURL\":\"data:text/javascript;base64,"))
        #expect(page.contains("id=\"sz-canvas\""))
        #expect(page.contains("<title>Web Gradient</title>"))
        // the rewritten module no longer imports by relative path
        let importmapLine = page.split(separator: "\n").first { $0.contains("type=\"importmap\"") } ?? ""
        let moduleBase64 = importmapLine.split(separator: "\"").first { $0.hasPrefix("data:text/javascript;base64,") }
            .map { String($0.dropFirst("data:text/javascript;base64,".count)) } ?? ""
        let module = String(decoding: Data(base64Encoded: moduleBase64) ?? Data(), as: UTF8.self)
        #expect(module.contains("from\"three-core\""))
    }
}
