// SPDX-License-Identifier: AGPL-3.0-only
// Load/save the SCHEDULED tasks that have not started:
//
//   MyProject.subz/
//   └─ .staging/
//      └─ tasks.json     // { "tasks": { "formatVersion": 1, "tasks": [ … ] } }
//
// Under `.staging/` for the same reason the message queue is, and it is the same hazard: a task
// starts an agent run — token spend — so a queue that traveled with the bundle (git, zip, Save As)
// would build someone else's copy the moment they opened it. Same-machine restart survival, the
// actual requirement, comes free.
//
// Only PENDING tasks persist. A running task cannot be restored: its claim, its fleet and its
// traversal all died with the process, and re-admitting it would redo work that may have already
// landed. It comes back as a run that ended, not as an ask waiting to happen.
// Forgiving like its siblings: missing or corrupt → no tasks, never a project-open error.
import Foundation

public enum SZTaskQueueIO {
    static let fileName = "tasks.json"
    static let stagingDirName = ".staging"
    public static let formatVersion = 1

    private struct Document: Codable { var tasks: Queue }

    private struct Queue: Codable {
        var formatVersion: Int
        var tasks: [SZTask]

        init(formatVersion: Int, tasks: [SZTask]) {
            self.formatVersion = formatVersion
            self.tasks = tasks
        }

        /// Tolerant: a version-less document still decodes; an undecodable task drops alone
        /// instead of sinking the file.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
            var tolerant: [SZTask] = []
            if var list = try? c.nestedUnkeyedContainer(forKey: .tasks) {
                while !list.isAtEnd {
                    if let task = try? list.decode(SZTask.self) {
                        tolerant.append(task)
                    } else {
                        _ = try? list.decode(AnyDecodable.self)   // skip the broken entry
                    }
                }
            }
            tasks = tolerant
        }
    }

    private struct AnyDecodable: Decodable {}

    /// `<project>.subz/.staging/tasks.json`
    static func fileURL(projectURL: URL) -> URL {
        projectURL.appending(path: stagingDirName).appending(path: fileName)
    }

    /// The subset worth persisting — the restore contract in one place.
    public static func persistable(_ tasks: [SZTask]) -> [SZTask] {
        tasks.filter { $0.state == .pending }
    }

    /// Write the scheduled tasks. Saving an empty set REMOVES the file (no husk).
    public static func save(_ tasks: [SZTask], projectURL: URL) throws {
        let keep = persistable(tasks)
        let url = fileURL(projectURL: projectURL)
        guard !keep.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SZJSON.encoder().encode(Document(tasks: Queue(formatVersion: formatVersion, tasks: keep)))
            .write(to: url, options: .atomic)
    }

    /// Empty on a missing or undecodable file — never throws into project open. Applies the same
    /// filter as save, so a hand-edited file cannot restore something already running.
    public static func load(projectURL: URL) -> [SZTask] {
        guard let data = try? Data(contentsOf: fileURL(projectURL: projectURL)),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        return persistable(document.tasks.tasks)
    }

    /// Delete the sidecar (project reset / user-intent purge). Best effort.
    public static func remove(projectURL: URL) {
        try? FileManager.default.removeItem(at: fileURL(projectURL: projectURL))
    }
}
