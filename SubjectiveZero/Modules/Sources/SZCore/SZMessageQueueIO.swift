// SPDX-License-Identifier: AGPL-3.0-only
// Load/save the message queue's undelivered envelopes:
//
//   MyProject.subz/
//   └─ .staging/
//      └─ message-queue.json     // { "queue": { "formatVersion": 1, "envelopes": [ … ] } }
//
// Deliberately under `.staging/` — NOT the bundle root like transcripts. A queued message delivers
// by RUNNING AN AGENT TURN, so a queue that traveled with the bundle (git, zip, Save As) would
// auto-execute turns — token spend — the moment a copy opened elsewhere. `.staging` is stripped on
// Save As and machine-local by convention; same-machine restart survival, the actual requirement,
// comes free. Save As also keeps `.staging` out of the duplicate, so the copy starts queue-clean.
//
// Only what redelivery needs persists: `.queued` and `.delivering` `.chat` envelopes (a
// `.delivering` reloads as `.queued` — at-least-once; the envelope's decoder enforces it).
// `.steer` envelopes are run-scoped and runs never survive the process — a restored steer would
// sit unconsumed forever or leak a dead run's steering into an unrelated next run, so they are
// excluded on save AND dropped on load. Terminal envelopes and `.debug`-scope messages never
// persist. Forgiving like SZChatTranscriptIO: missing or corrupt → empty queue, never a
// project-open error.
import Foundation

public enum SZMessageQueueIO {
    static let fileName = "message-queue.json"
    /// Same staging directory the project instance lock lives in (SZProjectDirectoryLock).
    static let stagingDirName = ".staging"
    public static let formatVersion = 1

    /// Top-level wrapper — matches project.json's `{ "project": { … } }` convention.
    private struct Document: Codable {
        var queue: Queue
    }

    private struct Queue: Codable {
        var formatVersion: Int
        var envelopes: [SZMessageEnvelope]

        init(formatVersion: Int, envelopes: [SZMessageEnvelope]) {
            self.formatVersion = formatVersion
            self.envelopes = envelopes
        }

        // Tolerant: a version-less document still decodes; an undecodable envelope drops alone
        // instead of sinking the file.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
            var tolerant: [SZMessageEnvelope] = []
            if var list = try? c.nestedUnkeyedContainer(forKey: .envelopes) {
                while !list.isAtEnd {
                    if let envelope = try? list.decode(SZMessageEnvelope.self) {
                        tolerant.append(envelope)
                    } else {
                        _ = try? list.decode(AnyDecodable.self)   // skip the broken entry
                    }
                }
            }
            envelopes = tolerant
        }
    }

    private struct AnyDecodable: Decodable {}

    /// `<project>.subz/.staging/message-queue.json`
    static func fileURL(projectURL: URL) -> URL {
        projectURL.appending(path: stagingDirName).appending(path: fileName)
    }

    /// The subset of a queue worth persisting — the redelivery contract in one place.
    public static func persistable(_ envelopes: [SZMessageEnvelope]) -> [SZMessageEnvelope] {
        envelopes.filter { envelope in
            guard envelope.intent == .chat else { return false }
            guard envelope.state == .queued || envelope.state == .delivering else { return false }
            return envelope.recipient != SZChatScope.debugKey
        }
    }

    /// Write the undelivered envelopes. Saving an empty set REMOVES the file (no husk).
    public static func save(_ envelopes: [SZMessageEnvelope], projectURL: URL) throws {
        let keep = persistable(envelopes)
        let url = fileURL(projectURL: projectURL)
        guard !keep.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let document = Document(queue: Queue(formatVersion: formatVersion, envelopes: keep))
        try SZJSON.encoder().encode(document).write(to: url, options: .atomic)
    }

    /// Empty on a missing or undecodable file — never throws into project open. Applies the same
    /// filter as save (belt-and-braces against a hand-edited or older file): `.chat` only, so a
    /// stray persisted steer can never leak into a fresh run.
    public static func load(projectURL: URL) -> [SZMessageEnvelope] {
        guard let data = try? Data(contentsOf: fileURL(projectURL: projectURL)) else { return [] }
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        return persistable(document.queue.envelopes)
    }

    /// Delete the sidecar (project reset / user-intent purge). Best effort.
    public static func remove(projectURL: URL) {
        try? FileManager.default.removeItem(at: fileURL(projectURL: projectURL))
    }
}
