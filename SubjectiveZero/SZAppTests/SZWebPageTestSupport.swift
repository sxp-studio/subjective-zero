// SPDX-License-Identifier: AGPL-3.0-only
// The web page for a test: a WKWebView only renders inside a window, so the runtime comes up in a
// small shown one and the caller waits for the handshake. Shared by the parity and preview checks.
import AppKit
import Foundation
import SZCore
import Testing
@testable import SubjectiveZero

@MainActor
enum SZWebPageTestSupport {
    /// The runtime, ready, with its page in a shown borderless window of `size`. Tear down with
    /// `runtime.unmount()` and `window.orderOut(nil)`.
    static func readyPage(project: URL, size: NSSize = NSSize(width: 640, height: 360)) async throws -> (SZWebRuntime, NSWindow) {
        let runtime = SZWebRuntime(projectURL: project, threeVersion: SZProjectWeb.currentThreeVersion)
        await runtime.start()
        let webView = try #require(runtime.webView, "the web runtime made no page: \(runtime.phase)")
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        for _ in 0..<200 where runtime.phase != .ready {
            if case .failed = runtime.phase { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard runtime.phase == .ready else {
            runtime.unmount(); window.orderOut(nil)
            throw SZWebPageTestError.pageNeverReady("\(runtime.phase)")
        }
        return (runtime, window)
    }
}

enum SZWebPageTestError: Error { case pageNeverReady(String) }
