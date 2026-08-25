// SPDX-License-Identifier: AGPL-3.0-only
// Load/save resumable agent sessions per project as `agent-sessions.json` in Application Support
// (sibling of app-state.json, same forgiving model):
//
//   { "formatVersion": 1,
//     "projects": { "<project path>": { "<scope key>": { "providerID": …, "sessionID": … } } } }
//
// Deliberately MACHINE-LOCAL, not a `.subz` sidecar: a provider session id is bound to this
// machine's CLI state (~/.claude / ~/.codex) and its working-directory hash — on another computer
// it is dead weight that would only churn a shared bundle. The portable catch-up path for a project
// opened elsewhere is transcript replay (SZChatTranscriptIO + the host's cold-start recap); sessions
// are just the fast path when the same machine relaunches. Keyed by the project's standardized path
// (paths are machine-local by definition here — that's the point).
// Each save holds an advisory lock on a sibling `.lock` file, so concurrent windows never lose entries.
// A save also prunes projects whose path no longer exists on disk.
import Foundation

public enum SZAgentSessionIO {
    static let fileName = "agent-sessions.json"

    /// `~/Library/Application Support/SubjectiveZero/agent-sessions.json`
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SubjectiveZero").appending(path: fileName)
    }

    private struct Document: Codable {
        var formatVersion: Int
        var projects: [String: [String: SZAgentSession]]

        init(formatVersion: Int = 1, projects: [String: [String: SZAgentSession]] = [:]) {
            self.formatVersion = formatVersion
            self.projects = projects
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
            projects = try c.decodeIfPresent([String: [String: SZAgentSession]].self, forKey: .projects) ?? [:]
        }
    }

    private static func projectKey(_ projectURL: URL) -> String {
        projectURL.standardizedFileURL.path
    }

    /// One project's sessions keyed by scope key. `[:]` on a missing or undecodable file — never
    /// throws into project open.
    public static func load(projectURL: URL, from url: URL = defaultURL) -> [String: SZAgentSession] {
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return [:] }
        return document.projects[projectKey(projectURL)] ?? [:]
    }

    /// Replace one project's sessions (read-modify-write; other projects' entries are preserved).
    /// An empty map prunes the project's entry.
    public static func save(_ sessions: [String: SZAgentSession], projectURL: URL, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try withFileLock(at: url.appendingPathExtension("lock")) {
            var document = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Document.self, from: $0) }
                ?? Document()
            let key = projectKey(projectURL)
            // Prune projects that are gone, not ones on a volume that is merely unmounted.
            let fm = FileManager.default
            for stale in document.projects.keys where stale != key && !fm.fileExists(atPath: stale)
                && fm.fileExists(atPath: (stale as NSString).deletingLastPathComponent) {
                document.projects.removeValue(forKey: stale)
            }
            if sessions.isEmpty {
                document.projects.removeValue(forKey: key)
            } else {
                document.projects[key] = sessions
            }
            try SZJSON.encoder().encode(document).write(to: url, options: .atomic)
        }
    }

    /// Runs `body` under an exclusive advisory `flock` on `lockURL`.
    private static func withFileLock(at lockURL: URL, _ body: () throws -> Void) throws {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(fd, LOCK_UN) }
        try body()
    }
}
