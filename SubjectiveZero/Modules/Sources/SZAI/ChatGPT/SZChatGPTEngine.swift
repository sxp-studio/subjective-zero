// SPDX-License-Identifier: AGPL-3.0-only
// download a pinned OpenAI app-server package into SubZ's private support directory.
import Foundation
import CryptoKit
import SZCore

public actor SZChatGPTEngine {
    public static let shared = SZChatGPTEngine(directory: SZAppSupport.directory.appending(path: "ChatGPT/engine"))
    public static let version = "0.159.0"
    private let directory: URL
    private var installing = false
    public init(directory: URL) { self.directory = directory }

    public var executable: URL { directory.appending(path: Self.version + "/bin/codex-app-server") }
    public var installed: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    public func install(progress: @escaping @Sendable (String) async -> Void) async throws {
        if installed { return }
        guard !installing else { throw SZChatGPTError("ChatGPT setup is already downloading the engine.") }
        installing = true
        defer { installing = false }
        #if arch(arm64)
        let target = "aarch64-apple-darwin"
        let digest = "33e64f6d350d38d78536721e5c60660273c88f1ea2a3a4d00ebb0f5c5fbc4399"
        #else
        let target = "x86_64-apple-darwin"
        let digest = "9e327278a1b8974a6e41123a0e862842546cbc3fb2345ea2093aec9e641926ef"
        #endif
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = directory.appending(path: ".install-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let url = URL(string: "https://github.com/openai/codex/releases/download/rust-v\(Self.version)/codex-app-server-package-\(target).tar.gz")!
        await progress("Downloading the ChatGPT engine from OpenAI (about 100 MB)…")
        let (download, response) = try await URLSession.shared.download(from: url)
        defer { try? fm.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SZChatGPTError("The engine download failed. Please try again.") }
        try Task.checkCancellation()
        await progress("Verifying the download…")
        try Self.verifyArchive(at: download, digest: digest)
        let extracted = staging.appending(path: "package")
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        let result = try await SZSystemProcessRunner().run("/usr/bin/tar", ["-xzf", download.path, "-C", extracted.path],
            environment: [:], currentDirectoryURL: nil, timeout: 60, onOutput: nil)
        guard result.exitCode == 0, !result.timedOut,
              fm.isExecutableFile(atPath: extracted.appending(path: "bin/codex-app-server").path),
              fm.isExecutableFile(atPath: extracted.appending(path: "bin/codex-code-mode-host").path) else {
            throw SZChatGPTError("Could not prepare the ChatGPT engine. Please retry setup.")
        }
        try Task.checkCancellation()
        // the published archive hash authenticates the complete package before extraction.
        let destination = directory.appending(path: Self.version)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: extracted, to: destination)
        await progress("Engine ready. Opening ChatGPT sign-in…")
    }

    static func verifyArchive(at url: URL, digest: String) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else {
            throw SZChatGPTError("The downloaded engine failed its integrity check. Please retry setup.")
        }
    }
}
