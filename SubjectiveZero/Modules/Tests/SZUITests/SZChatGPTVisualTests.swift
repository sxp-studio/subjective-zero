// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import SZUI

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["SZ_CONNECTION_PREVIEWS"] != nil))
func renderChatGPTConnectionPreviews() throws {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SZ_CONNECTION_PREVIEWS"]!)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = NSApplication.shared
    for connected in [false, true] {
        let connection = SZChatGPTConnectionView(
            accounts: connected ? [.init(id: "preview", label: "hello@example.com")] : [],
            activeID: connected ? "preview" : nil, connected: connected, usesPlan: connected,
            busy: false, message: nil, onConnect: {}, onAddAccount: {}, onSelect: { _ in },
            onSignOut: {}, onCancel: {}, onManageUsage: {})
        let card = SZProviderSetupCard(id: "chatgpt", displayName: "ChatGPT", statusLabel: connected ? "Ready" : "Sign in",
            message: "", readiness: connected ? .ready : .needsLogin, models: connected ? [.init(id: "one", label: "Model One"), .init(id: "two", label: "Model Two")] : [], selectedModel: "one",
            isConfirmable: connected, directSignIn: true)
        let view = SZProviderSetupSheet(cards: [card], chatGPT: connection, selectedID: "chatgpt",
            onSelect: { _ in }, onRefresh: {}, onTest: { _ in }, onSetModel: { _, _ in },
            onOpenLogin: { _ in }, onUseFallback: { _ in }, onSetEnabled: { _, _ in },
            onConfirm: {}, onSkip: {}, onOpenSetupGuide: {}, onJoinDiscord: {})
        try render(view.directConnectionCard(card), size: NSSize(width: 594, height: connected ? 250 : 230),
                   to: directory.appending(path: connected ? "connected.png" : "sign-in.png"))
    }
    try render(SZChatGPTWelcomeView(onContinue: {}, onManageUsage: {}),
               size: NSSize(width: 416, height: 310), to: directory.appending(path: "welcome.png"))
}

@MainActor
private func render(_ view: some View, size: NSSize, to url: URL) throws {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
        .background(Color(red: 0.11, green: 0.11, blue: 0.11)).environment(\.colorScheme, .dark))
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: url)
}
