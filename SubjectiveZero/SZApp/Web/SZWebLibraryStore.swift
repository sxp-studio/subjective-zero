// SPDX-License-Identifier: AGPL-3.0-only
// three.js for web projects: fetched once per pinned version, hash-checked, cached under Application
// Support. The repo carries no library code. A version without hashes in `known` is refused, so
// bumping `SZProjectWeb.currentThreeVersion` means adding its hashes here.
import CryptoKit
import Foundation

enum SZWebLibraryStore {
    /// SHA-256 (hex) of the two build files a version ships: `three.module.min.js` imports
    /// `./three.core.min.js`, so both are needed side by side.
    struct Pin: Sendable {
        let module: String
        let core: String
    }

    static let known: [String: Pin] = [
        "0.185.1": Pin(module: "86bcee248b64f44bcfc23c331ae74619061957d59cab040171dcb6fb5900beb6",
                       core: "05b2609338c76cd65daf74f3ac515bc9a5045e1b3b33edc07d8c9bd55250fa90"),
    ]

    static let moduleFile = "three.module.min.js"
    static let coreFile = "three.core.min.js"

    enum Failure: Error, LocalizedError {
        case unknownVersion(String)
        case download(String)
        case hashMismatch(String)

        var errorDescription: String? {
            switch self {
            case .unknownVersion(let v): "This app does not know three.js \(v). Update the app, or open the project with the version that made it."
            case .download(let what): "Web projects need a one-time download of three.js. Check the connection and try again. (\(what))"
            case .hashMismatch(let file): "The downloaded \(file) did not match the expected checksum, so it was not kept. Try again."
            }
        }
    }

    /// `~/Library/Application Support/SubjectiveZero/web-libraries/three/`. Deliberately not under
    /// `SZAppSupport.directory`: a checksummed download cache, not a preference, and the backend
    /// parity test reads the copy the app cached rather than downloading its own.
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SubjectiveZero").appending(path: "web-libraries").appending(path: "three")
    }

    static func directory(for version: String) -> URL { root.appending(path: version) }

    static func isReady(_ version: String) -> Bool {
        let dir = directory(for: version)
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appending(path: moduleFile).path)
            && fm.fileExists(atPath: dir.appending(path: coreFile).path)
    }

    /// The directory holding the version's two files, downloading and verifying them first if the
    /// cache lacks either. Nothing is kept on a checksum mismatch.
    static func ensure(_ version: String) async throws -> URL {
        guard let pin = known[version] else { throw Failure.unknownVersion(version) }
        let dir = directory(for: version)
        if isReady(version) { return dir }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (file, sha) in [(moduleFile, pin.module), (coreFile, pin.core)] {
            let data = try await download(version: version, file: file)
            guard Self.sha256(data) == sha else { throw Failure.hashMismatch(file) }
            try data.write(to: dir.appending(path: file), options: .atomic)
        }
        return dir
    }

    private static func download(version: String, file: String) async throws -> Data {
        let url = URL(string: "https://cdn.jsdelivr.net/npm/three@\(version)/build/\(file)")!
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw Failure.download("\(file): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            return data
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.download(error.localizedDescription)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
