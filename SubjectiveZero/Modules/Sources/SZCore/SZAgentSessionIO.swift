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
        var document = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Document.self, from: $0) }
            ?? Document()
        if sessions.isEmpty {
            document.projects.removeValue(forKey: projectKey(projectURL))
        } else {
            document.projects[projectKey(projectURL)] = sessions
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SZJSON.encoder().encode(document).write(to: url, options: .atomic)
    }
}
