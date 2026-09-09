// SPDX-License-Identifier: AGPL-3.0-only
// Downloading a library and unpacking it, which is the whole of how an external library arrives.
//
// A link is somewhere to fetch a copy from, never a repository the app maintains: nothing here runs
// anybody's version control. The order is download to a capped temporary file, read the archive's
// listing, refuse the whole thing on anything unsafe, and only then write files. Everything happens
// inside one staging folder that is deleted on every path, so a kill at any moment leaves nothing.
import Foundation
import SZCore

extension SZHost {
    /// Where a fetch assembles its files. Dot-prefixed so it can never be mistaken for a library key
    /// by the folder scan next door.
    nonisolated static var libraryStagingURL: URL {
        fetchedLibrariesURL.appending(path: ".staging")
    }

    /// Throw away anything a previous run left mid-fetch. Called once at launch, before the first scan.
    nonisolated static func clearLibraryStaging() {
        try? FileManager.default.removeItem(at: libraryStagingURL)
    }

    /// A downloaded, unpacked, checked copy of a library, and the caller's to delete.
    struct SZLibraryCopy {
        /// The unpacked library: `library.json` and the node folders sit directly inside it.
        var folder: URL
        /// The whole staging folder, which is what to delete when finished.
        var staging: URL
        /// What the server said it served, for the next check to quote back.
        var etag: String?
    }

    /// Fetch a library from a link and leave it unpacked in a staging folder. Throws a sentence a
    /// person can act on; nothing is left behind on any failure.
    ///
    /// `knownETag` makes it a conditional request: an unchanged library answers 304 and returns nil,
    /// which costs one round trip instead of a download.
    nonisolated static func fetchLibrary(from link: SZLibraryLink, knownETag: String? = nil) async throws -> SZLibraryCopy? {
        guard let url = link.archiveURL, url.scheme?.lowercased() == "https" else {
            throw SZMCPError.message("That library link isn't one this app can download from.")
        }
        let fm = FileManager.default
        let staging = libraryStagingURL.appending(path: UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            var request = URLRequest(url: url)
            if let knownETag { request.setValue(knownETag, forHTTPHeaderField: "If-None-Match") }
            let limit = SZArchiveDownload()
            let session = URLSession(configuration: .ephemeral, delegate: limit, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }

            let (downloaded, response) = try await session.download(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SZMCPError.message(fetchFailure(nil))
            }
            if http.statusCode == 304 {
                try? fm.removeItem(at: staging)
                return nil
            }
            // A redirect the delegate vetoed arrives here as a success with no body, so the status
            // has to be checked rather than trusted.
            guard http.statusCode == 200 else {
                throw SZMCPError.message(fetchFailure(nil, status: http.statusCode))
            }
            let archive = staging.appending(path: "archive.tar.gz")
            try fm.moveItem(at: downloaded, to: archive)

            // Read what the archive claims to hold, and refuse the whole thing before writing a file.
            let listing = runTool("/usr/bin/tar", ["-t", "-v", "-f", archive.path])
            guard listing.ok else { throw SZMCPError.message("That link didn't give back a library archive.") }
            if let refusal = SZArchiveListing.refusal(lines: listing.output.split(separator: "\n").map(String.init)) {
                throw SZMCPError.message(refusal)
            }

            let unpacked = staging.appending(path: "unpacked")
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            // The argv is a fixed literal: nothing in it comes from a manifest, a link, or a tool
            // argument. --strip-components drops the single wrapping folder every forge adds, which
            // the listing check has already established there is exactly one of.
            let extracted = runTool("/usr/bin/tar", [
                "-x", "-f", archive.path, "-C", unpacked.path, "--strip-components=1",
                "--no-same-owner", "--no-xattrs", "--no-mac-metadata", "--no-fflags", "--no-acls",
            ])
            guard extracted.ok else {
                throw SZMCPError.message("That library couldn't be unpacked safely, so nothing was added.")
            }
            try? fm.removeItem(at: archive)
            return SZLibraryCopy(folder: unpacked, staging: staging,
                                 etag: http.value(forHTTPHeaderField: "ETag"))
        } catch let error as SZMCPError {
            try? fm.removeItem(at: staging)
            throw error
        } catch {
            try? fm.removeItem(at: staging)
            throw SZMCPError.message(fetchFailure(error))
        }
    }

    /// Which node folders differ between two copies of a library, compared by content since a copy
    /// carries no history to diff. A change to a top-level file is not a node changing.
    nonisolated static func libraryDifference(staged: URL, live: URL) -> (added: [String], changed: [String], removed: [String]) {
        let before = nodeFolders(in: live), after = nodeFolders(in: staged)
        let added = after.keys.filter { before[$0] == nil }
        let removed = before.keys.filter { after[$0] == nil }
        let changed = after.keys.filter { name in
            guard let old = before[name], let new = after[name] else { return false }
            return !foldersMatch(old, new)
        }
        return (added.sorted(), changed.sorted(), removed.sorted())
    }

    /// The node folders in a library, by name. Composed the same way on both sides, so a name typed
    /// on one Mac still matches the same name unpacked from an archive made on another.
    private nonisolated static func nodeFolders(in root: URL) -> [String: URL] {
        let fm = FileManager.default
        var out: [String: URL] = [:]
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard fm.fileExists(atPath: folder.appending(path: "node-contract.json").path) else { continue }
            out[folder.lastPathComponent.precomposedStringWithCanonicalMapping] = folder
        }
        return out
    }

    private nonisolated static func foldersMatch(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        func names(_ url: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
        }
        let left = names(a), right = names(b)
        guard left == right else { return false }
        return left.allSatisfy { fm.contentsEqual(atPath: a.appending(path: $0).path,
                                                  andPath: b.appending(path: $0).path) }
    }

    // MARK: running a tool

    /// Run one command line tool and hand back what it said. Blocking, and called off the main actor.
    nonisolated static func runTool(_ executable: String, _ arguments: [String]) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            // Read before waiting: a listing longer than the pipe buffer blocks the tool until
            // someone drains it, and waiting first would wedge on any sizeable archive.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            if process.terminationStatus != 0 {
                print("[SZHost] \(executable) failed (\(process.terminationStatus)): \(text)")
            }
            return (process.terminationStatus == 0, text)
        } catch {
            print("[SZHost] \(executable) could not run: \(error)")
            return (false, "\(error)")
        }
    }

    /// Turn a failed download into a sentence a person can act on.
    nonisolated static func fetchFailure(_ error: (any Error)?, status: Int? = nil) -> String {
        if let status {
            switch status {
            // A missing library and a private one are indistinguishable here, so never claim either.
            case 404, 451: return "There is nothing at that link, or it is private."
            case 401, 403: return "That library is private, so it can't be read from here."
            default: return "That link didn't give back a library archive."
            }
        }
        guard let error = error as? URLError else { return "That link didn't give back a library archive." }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .timedOut:
            return "Couldn't reach the internet. Your libraries still work as they are."
        case .cancelled:
            return "That library is too big to add."
        default:
            return "That link didn't give back a library archive."
        }
    }
}

/// Keeps a download honest: https on every hop, a hop limit, and a hard byte cap so a hostile server
/// cannot fill the disk before anything has been checked.
private final class SZArchiveDownload: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    /// 50 to 250 times any honest library; the one the app ships is 556 KB.
    private static let maxBytes: Int64 = 32 << 20
    private static let maxRedirects = 5
    private var redirects = 0

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        // GitHub redirects to codeload, so a same-host rule would break it. Https on every hop is
        // the rule that actually matters.
        guard redirects <= Self.maxRedirects, request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > Self.maxBytes || totalBytesWritten > Self.maxBytes {
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
