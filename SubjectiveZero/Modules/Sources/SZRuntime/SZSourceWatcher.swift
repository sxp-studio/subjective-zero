// SPDX-License-Identifier: AGPL-3.0-only
// Watches a source file for edits and fires `onChange` when its modification date changes.
//
// Lives in SZRuntime because hot reload (watch source → recompile → swap) is the runtime's job
// (RUNTIME.md); the host keeps only the *policy* (what to do on change). The mechanism is generic
// file-mtime polling — kept out of SZApp.
//
// Modification-date polling rather than a DispatchSource/FSEvents watch on purpose: it's a dev
// affordance, and polling is immune to the two things that make fd-based file watches fragile —
// editors that save in place vs. atomically (write-temp + rename, which orphans an inode watch). The
// 300 ms tick is negligible. (Agent-driven recompiles go through MCP `agent_compile_node`, not this.)
import Foundation

@MainActor
public final class SZSourceWatcher {
    private let fileURL: URL
    private var task: Task<Void, Never>?

    public init(watching fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Begin polling; `onChange` runs on the MainActor each time the file's mtime advances.
    public func start(onChange: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        let url = fileURL
        task = Task { @MainActor in
            var last = Self.modificationDate(of: url)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                let current = Self.modificationDate(of: url)
                if let current, current != last {
                    last = current
                    onChange()
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
