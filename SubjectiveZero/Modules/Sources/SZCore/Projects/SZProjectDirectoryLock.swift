// SPDX-License-Identifier: AGPL-3.0-only
// A per-project advisory lock so two running app instances can't edit — and autosave over — the
// same `.subz` at once. It's `flock(LOCK_EX | LOCK_NB)` on `<Project>.subz/.staging/instance.lock`:
// advisory, per-file, non-blocking, and released the moment the file descriptor closes (so a crash
// or SIGKILL frees it too — no stale lock survives the owning process). The lock file lives under
// `.staging` (per-machine scratch, stripped on Save As), so it never travels with the document.
//
// It is NOT a coordination channel: it only ever conflicts when two instances open the exact same
// project. In the normal "each window is a different project" flow every instance owns its own
// project's lock and stays fully editable.
import Foundation

/// A held exclusive lock on one project bundle. Keep it alive for as long as the project is open;
/// `release()` (or dropping the last reference) frees it.
public final class SZProjectDirectoryLock {
    private var fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    /// Try to take the exclusive lock for a project bundle. Returns the held lock on success;
    /// throws `SZProjectLockError.alreadyLocked` if another instance holds it (non-blocking), or
    /// `.cannotOpen` if the lock file itself couldn't be created/opened.
    public static func acquire(forProjectAt projectURL: URL) throws -> SZProjectDirectoryLock {
        let stagingDir = projectURL.appending(path: ".staging")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let lockURL = stagingDir.appending(path: "instance.lock")

        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw SZProjectLockError.cannotOpen(errno) }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            close(fd)
            throw err == EWOULDBLOCK ? SZProjectLockError.alreadyLocked : SZProjectLockError.cannotOpen(err)
        }
        return SZProjectDirectoryLock(fileDescriptor: fd)
    }

    /// Release the lock (idempotent). `flock` also frees on process exit, so this is best-effort
    /// tidiness for the graceful switch/quit paths.
    public func release() {
        guard fileDescriptor >= 0 else { return }
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        fileDescriptor = -1
    }

    deinit { release() }
}

public enum SZProjectLockError: Error {
    /// Another running instance already holds this project's lock.
    case alreadyLocked
    /// The lock file couldn't be opened/created (raw `errno`).
    case cannotOpen(Int32)
}
