// SPDX-License-Identifier: AGPL-3.0-only
// Load/save per-scope chat transcript sidecars inside a `.subz` bundle:
//
//   MyProject.subz/
//   └─ transcripts/
//      ├─ director.json         // { "transcript": { "formatVersion": 1, "messages": [ … ] } }
//      └─ <node-uuid>.json      // one file per node Coding Agent conversation
//
// The filename IS the scope key (SZChatScope.key) — one file per conversation, so a node delete is
// one file removal and a flush rewrites only that scope. Portable by design: transcripts travel with
// the bundle (git, zip, another machine) and are the catch-up substrate for a fresh agent session;
// provider session ids are machine-bound and live in SZAgentSessionIO instead. `.debug` is never
// persisted (a scratch agent, ephemeral by contract) — excluded on save AND load.
//
// Forgiving like SZAppStateIO, strict like nothing: a transcript is a convenience, so a missing or
// corrupt file quietly becomes "no history" rather than a project-open error. Host-internal format
// (agents don't read or author these files); the message shape is append-tolerant, see SZChat.swift.
//
// Lifecycle policy (enforced by the host): node delete AND split/merge commit/rollback drop the
// removed nodes' sidecars — ids are never reused, so an orphaned transcript would be unreachable in
// the UI, and the Director transcript already narrates the op.
import Foundation

public enum SZChatTranscriptIO {
    static let dirName = "transcripts"
    public static let formatVersion = 1

    /// Top-level wrapper — matches project.json's `{ "project": { … } }` convention.
    private struct Document: Codable {
        var transcript: Transcript
    }

    private struct Transcript: Codable {
        var formatVersion: Int
        var messages: [SZChatMessage]

        init(formatVersion: Int, messages: [SZChatMessage]) {
            self.formatVersion = formatVersion
            self.messages = messages
        }

        // Tolerant like the message shape: a version-less or message-less document still decodes.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
            messages = try c.decodeIfPresent([SZChatMessage].self, forKey: .messages) ?? []
        }
    }

    /// `<project>.subz/transcripts/<scopeKey>.json`
    static func fileURL(projectURL: URL, scopeKey: String) -> URL {
        projectURL.appending(path: dirName).appending(path: "\(scopeKey).json")
    }

    /// Write one scope's transcript. Saving an empty array REMOVES the file instead (a fully-pruned
    /// scope leaves no husk). The debug scope is silently skipped.
    public static func save(_ messages: [SZChatMessage], scopeKey: String, projectURL: URL) throws {
        guard scopeKey != SZChatScope.debugKey else { return }
        let url = fileURL(projectURL: projectURL, scopeKey: scopeKey)
        guard !messages.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let document = Document(transcript: Transcript(formatVersion: formatVersion, messages: messages))
        try SZJSON.encoder().encode(document).write(to: url, options: .atomic)
    }

    /// nil on a missing or undecodable file — never throws into project open.
    public static func load(scopeKey: String, projectURL: URL) -> [SZChatMessage]? {
        guard scopeKey != SZChatScope.debugKey else { return nil }
        let url = fileURL(projectURL: projectURL, scopeKey: scopeKey)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(Document.self, from: data))?.transcript.messages
    }

    /// Every transcript in the bundle, keyed by scope key. Skips filenames that aren't a valid scope
    /// key (junk, .DS_Store), the debug scope, and files that fail to decode. The CALLER filters node
    /// keys down to ids still present in the graph — this reads what's on disk, policy stays host-side.
    public static func loadAll(projectURL: URL) -> [String: [SZChatMessage]] {
        let dir = projectURL.appending(path: dirName)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [:] }
        var transcripts: [String: [SZChatMessage]] = [:]
        for file in files where file.pathExtension == "json" {
            let key = file.deletingPathExtension().lastPathComponent
            guard SZChatScope(key: key) != nil else { continue }
            guard let messages = load(scopeKey: key, projectURL: projectURL), !messages.isEmpty else { continue }
            transcripts[key] = messages
        }
        return transcripts
    }

    /// Delete one scope's sidecar (node delete, split/merge drop, clear). Best effort.
    public static func remove(scopeKey: String, projectURL: URL) {
        try? FileManager.default.removeItem(at: fileURL(projectURL: projectURL, scopeKey: scopeKey))
    }
}
