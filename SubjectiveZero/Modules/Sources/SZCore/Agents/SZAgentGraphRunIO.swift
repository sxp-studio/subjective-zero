// SPDX-License-Identifier: AGPL-3.0-only
// Load/save the agent-graph run history sidecar: `<project>.subz/runs.json` — the RUNS list's
// archive, `SZChatTranscriptIO`'s shape applied to run records. Ended records only: the host
// persists at seal (and on the sanctioned post-seal tally amend), so a live record is never
// on disk — a crash mid-traversal loses that record; the transcript survives.
//
// Forgiving the same way: a missing or corrupt file quietly becomes "no history", never a
// project-open error. And deliberately INDEPENDENT of the transcripts: clearing a chat does
// not clear execution history — this file survives transcript clears and is replaced
// wholesale on project switch (the host's restore/clear lifecycle).
import Foundation

public enum SZAgentGraphRunIO {
    public static let formatVersion = 1

    /// Top-level wrapper — matches the transcript sidecar's `{ "transcript": { … } }` convention.
    private struct Document: Codable {
        var runs: History
    }

    private struct History: Codable {
        var formatVersion: Int
        var records: [SZAgentGraphRun]

        init(formatVersion: Int, records: [SZAgentGraphRun]) {
            self.formatVersion = formatVersion
            self.records = records
        }

        // Tolerant like the record shape: a version-less or record-less document still decodes.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
            records = try c.decodeIfPresent([SZAgentGraphRun].self, forKey: .records) ?? []
        }
    }

    /// `<project>.subz/runs.json`
    static func fileURL(projectURL: URL) -> URL {
        projectURL.appending(path: "runs.json")
    }

    /// Write the history — `SZJSON.encoder()`, so the bytes are deterministic and diffable
    /// like every sidecar's. Saving an empty list REMOVES the file instead (a fully-evicted
    /// history leaves no husk).
    public static func save(_ records: [SZAgentGraphRun], projectURL: URL) throws {
        let url = fileURL(projectURL: projectURL)
        guard !records.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let document = Document(runs: History(formatVersion: formatVersion, records: records))
        try SZJSON.encoder().encode(document).write(to: url, options: .atomic)
    }

    /// nil on a missing or undecodable file — never throws into project open.
    public static func load(projectURL: URL) -> [SZAgentGraphRun]? {
        guard let data = try? Data(contentsOf: fileURL(projectURL: projectURL)) else { return nil }
        return (try? JSONDecoder().decode(Document.self, from: data))?.runs.records
    }
}
