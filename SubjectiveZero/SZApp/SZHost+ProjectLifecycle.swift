// SPDX-License-Identifier: AGPL-3.0-only
// Project lifecycle — the document-UI intents behind File ▸ New / Open… / Open Recent / Save As…
// and the launch chain (roadmap Task 1), following the SZHost+Chat.swift sibling pattern. The
// actual switch mechanics live in SZHost.switchProject (it touches private host state); this file
// owns WHEN it runs (panels, menu items, launch) and the error surface (NSAlert — testers must see
// why an open failed, not read a status line). Persistence stays automatic (persistProject on
// every edit), so there is no Save — only Save As… (duplicate-and-switch).
import AppKit
import Foundation
import SZCore
import UniformTypeIdentifiers

extension SZHost {
    /// Project ops refuse while an agent owns anything — a run, any streaming turn, a staged graph
    /// op: every such activity holds a ledger claim (`deliver` claims per turn, `startRun` per run).
    /// The `chatInFlight` term is NOT redundant with the claims: `cancelRun` releases eagerly while
    /// a killed CLI can stream for seconds more — during that window the ledger reads free but the
    /// physical stream (its in-flight marker) is still writing, and tearing the project down under
    /// it would land its output in the NEXT project's store. Queued-but-undelivered messages
    /// deliberately do NOT block (they persist and redeliver on reopen).
    /// Menu items disable on this; the methods guard on it too (the MCP surface can race a click).
    var isBusyForProjectOps: Bool { ledger.anyHeld || !chatInFlight.isEmpty }

    /// The `.subz` package content type for the save/open panels. Prefers the app's exported UTI
    /// (`studio.sxp.subz`, declared in Info.plist as a `com.apple.package`); falls back to a plain
    /// extension type if Launch Services hasn't registered the UTI yet (e.g. a fresh dev build).
    static var subzContentType: UTType? {
        UTType("studio.sxp.subz") ?? UTType(filenameExtension: "subz")
    }

    // MARK: - Launch chain

    /// The launch project: `SZ_PROJECT` env (dev override — never recorded in history) → the last
    /// user-opened project if it still exists → a fresh first-launch copy of the bundled sample.
    /// Each link falls through to the next on failure (a stale path silently, a corrupt project
    /// with an alert), so testers never boot into a dead app.
    func openInitialProject(preferred: URL? = nil) async {
        // A Finder cold-launch open (double-click / "Open With") takes priority over the remembered
        // chain — it's an explicit user intent. On failure, fall through to the normal chain below.
        if let preferred {
            do {
                try await switchProject(to: preferred)
                return
            } catch SZProjectLifecycleError.alreadyOpenElsewhere {
                presentProjectError("“\(preferred.lastPathComponent)” is already open",
                                    SZProjectLifecycleError.alreadyOpenElsewhere)
            } catch {
                presentProjectError("Couldn't open “\(preferred.lastPathComponent)”", error)
            }
        }
        if let envURL = Self.envProjectURL {
            do {
                try await switchProject(to: envURL, recordInHistory: false)
                return
            } catch {
                // Dev affordance — log loudly, then fall through to the user chain.
                status = "SZ_PROJECT failed: \(error)"
                print("[SZHost] SZ_PROJECT open failed (falling back): \(error)")
            }
        }
        // Whether the fresh-sample fallback below should become the remembered reopen target. Off
        // only when the remembered project is healthy but locked by another instance — then we boot
        // a throwaway untitled here WITHOUT overwriting the shared `openProjectPath`.
        var recordFallbackInHistory = true
        if let path = lastOpenProjectPath, FileManager.default.fileExists(atPath: path) {
            do {
                try await switchProject(to: URL(filePath: path))
                return
            } catch SZProjectLifecycleError.alreadyOpenElsewhere {
                // Another running instance already owns the remembered project. It's healthy — keep
                // it remembered — and boot THIS instance into a fresh untitled project below (so a
                // second `open -n` launch gets its own window/project instead of colliding). Do NOT
                // record that throwaway as the reopen target, or we'd clobber the remembered path in
                // the shared app-state while the other instance is still live.
                print("[SZHost] last project already open in another instance — starting a fresh untitled project")
                recordFallbackInHistory = false
            } catch {
                presentProjectError("Couldn't reopen “\((path as NSString).lastPathComponent)”", error)
                // Unloadable — forget it so the next launch goes straight to the sample.
                lastOpenProjectPath = nil
                persistAppState()
            }
        } else if lastOpenProjectPath != nil {
            // Stale path — forget it so the next launch goes straight to the sample.
            lastOpenProjectPath = nil
            persistAppState()
        }
        do {
            try await switchProject(to: try makeFreshSampleProject(), recordInHistory: recordFallbackInHistory)
        } catch {
            status = "load failed: \(error)"
            print("[SZHost] first-launch sample failed: \(error)")
            presentProjectError("Couldn't create the starter project", error)
        }
    }

    /// First-launch (and recovery) content: copy the bundled sample into a fresh untitled-project
    /// directory. The copy is the user's to mutate; the bundled resource stays pristine.
    private func makeFreshSampleProject() throws -> URL {
        guard let bundled = Bundle.main.url(forResource: "grayscale-camera", withExtension: "subz") else {
            throw SZProjectLifecycleError.sampleMissing
        }
        let dest = try SZUntitledProjects.newProjectDirectory().appending(path: "Grayscale Camera.subz")
        try FileManager.default.copyItem(at: bundled, to: dest)
        return dest
    }

    // MARK: - File menu flows

    /// File ▸ New Project (⌘N): a fresh empty untitled project (SZUntitledProjects home). No
    /// prompt about the current project — persistence is automatic and an untitled one stays
    /// reachable via Open Recent (decided 2026-07-03).
    func newProject() {
        guard !isBusyForProjectOps else { return }
        Task { @MainActor in
            do {
                let url = try SZUntitledProjects.newProjectDirectory().appending(path: "Untitled.subz")
                try SZProjectIO.save(SZProject(name: "Untitled"), to: url)
                try await switchProject(to: url)
            } catch {
                presentProjectError("Couldn't create a new project", error)
            }
        }
    }

    /// File ▸ Open… (⌘O). A `.subz` is a registered `com.apple.package` bundle, so the panel scopes
    /// to that type. Both files AND directories stay selectable (a `.subz` reads as a file once
    /// Launch Services registers the package UTI, as a plain folder before then), and the extension
    /// check on confirm is the backstop either way.
    func openProjectViaPanel() {
        guard !isBusyForProjectOps else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a SubjectiveZero project (.subz)"
        panel.prompt = "Open"
        // Include `.folder` so a `.subz` that Launch Services hasn't yet registered as a package
        // (fresh install / dev build) is still selectable as a plain directory — the extension
        // check on confirm is the real gate either way.
        if let subzType = Self.subzContentType { panel.allowedContentTypes = [subzType, .folder] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension == "subz" else {
            presentProjectError("“\(url.lastPathComponent)” is not a SubjectiveZero project",
                                SZProjectLifecycleError.notAProject)
            return
        }
        openProject(at: url)
    }

    /// Open a known path (Open Recent, the open panel). Alerts on failure; a vanished recent is
    /// pruned from the menu's backing list (it is also existence-filtered at menu build — this
    /// covers the race where it disappears between build and click).
    func openProject(at url: URL) {
        guard !isBusyForProjectOps else { return }
        Task { @MainActor in
            guard FileManager.default.fileExists(atPath: url.path) else {
                presentProjectError("“\(url.lastPathComponent)” can't be found",
                                    SZProjectLifecycleError.projectMissing)
                pruneRecentProject(url.standardizedFileURL.path)
                return
            }
            do {
                try await switchProject(to: url)
            } catch SZProjectLifecycleError.alreadyOpenElsewhere {
                presentProjectError("“\(url.lastPathComponent)” is already open",
                                    SZProjectLifecycleError.alreadyOpenElsewhere)
            } catch {
                presentProjectError("Couldn't open “\(url.lastPathComponent)”", error)
            }
        }
    }

    /// File ▸ Save (⌘S). Persistence is automatic, so for a SAVED project this is a force-flush
    /// (transcripts + sessions + graph) to disk — a reassurance, not a state change. An UNTITLED
    /// project has nowhere to save yet, so it routes to Save As… (rescue to a chosen location).
    func saveProject() {
        guard !isBusyForProjectOps, store.project != nil else { return }
        if isUntitledProject { saveProjectAs(); return }
        flushAllTranscripts()
        persistAgentSessions()
        persistProject()
        status = "saved \(loadedProjectURL?.lastPathComponent ?? "project")"
    }

    /// File ▸ Save As… (⇧⌘S) — the menu's fire-and-forget wrapper over `saveProjectAsInteractively`.
    func saveProjectAs() {
        Task { @MainActor in await saveProjectAsInteractively() }
    }

    /// Save As duplicate-and-switch (persistence is automatic; there is no Save). The bundle is
    /// self-contained (nodes, transcript sidecars, attachments), so: flush → copy → migrate the
    /// machine-local sessions to the new path key → switch → rename to the dest stem. Saving an
    /// untitled project then deletes its untitled-directory folder (its recents entry and session
    /// store go with it) — Save As from an already-saved project keeps the source (standard
    /// duplicate behavior). Returns true iff the project was saved to the chosen location; the quit
    /// prompt awaits this to decide whether to proceed.
    @MainActor
    @discardableResult
    func saveProjectAsInteractively() async -> Bool {
        guard !isBusyForProjectOps, let sourceURL = loadedProjectURL, let project = store.project else { return false }
        let panel = NSSavePanel()
        // The package content type appends `.subz`, so the name field is the bare project name.
        panel.nameFieldStringValue = project.name
        panel.message = "Save the project as a .subz bundle"
        panel.canCreateDirectories = true
        if let subzType = Self.subzContentType { panel.allowedContentTypes = [subzType] }
        // An untitled project has no meaningful home — default the panel to ~/Documents.
        if isUntitledProject {
            panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        }
        guard panel.runModal() == .OK, var dest = panel.url else { return false }
        if dest.pathExtension != "subz" { dest.appendPathExtension("subz") }

        do {
            // Freeze the source: completed transcripts + graph land in the bundle pre-copy.
            flushAllTranscripts()
            persistAgentSessions()
            persistProject()

            // Delete-then-copy (the panel already got the user's replace confirm). But first, if
            // we're about to overwrite a DIFFERENT existing bundle, make sure no other instance has
            // it open — the destructive removeItem would otherwise delete a live project out from
            // under it. A liveness probe: take then immediately drop its lock (we're overwriting).
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path),
               dest.standardizedFileURL != sourceURL.standardizedFileURL {
                do {
                    try SZProjectDirectoryLock.acquire(forProjectAt: dest).release()
                } catch SZProjectLockError.alreadyLocked {
                    presentProjectError("Can't save over “\(dest.lastPathComponent)”",
                                        SZProjectLifecycleError.alreadyOpenElsewhere)
                    return false
                }   // .cannotOpen (dest isn't lockable, e.g. not our bundle) → proceed to overwrite
            }
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: sourceURL, to: dest)
            // Agent scratch space (incl. the copied instance.lock) is per-machine working state,
            // not document content.
            try? fm.removeItem(at: dest.appending(path: ".staging"))

            // The session store is keyed by project path — seed the new key so the switch
            // restores resumable sessions instead of cold-starting every chat.
            try? SZAgentSessionIO.save(agentSessions, projectURL: dest)

            let wasUntitled = isUntitledProject
            try await switchProject(to: dest)   // releases the source lock, takes the dest lock

            // The document takes its new name from where the user put it.
            store.mutate { $0.name = dest.deletingPathExtension().lastPathComponent }
            persistProject()

            if wasUntitled {
                // The untitled copy has served its purpose — remove the Projects/<uuid>/ layer.
                try? fm.removeItem(at: sourceURL.deletingLastPathComponent())
                pruneRecentProject(sourceURL.standardizedFileURL.path)
                try? SZAgentSessionIO.save([:], projectURL: sourceURL)
            }
            return true
        } catch {
            presentProjectError("Couldn't save the project to “\(dest.lastPathComponent)”", error)
            return false
        }
    }

    // MARK: - Close / quit guard

    /// Prompt to rescue an UNTITLED project (one still in the temp `Projects/<uuid>/` home) before
    /// it's cleaned up. Saved projects autosave on every edit, so they never prompt. Returns true if
    /// the caller may proceed (saved elsewhere, discarded, or nothing to rescue); false only when the
    /// user cancels. Mirrors the prototype's single "you're about to lose the untitled project" gate.
    @MainActor
    func confirmSaveOrDiscardIfUnsaved(actionName: String) async -> Bool {
        guard isUntitledProject, store.project != nil else { return true }
        // A prompt is already up (close + quit racing over the same untitled project): don't stack a
        // second modal — refuse this caller so it doesn't proceed independently; the live prompt decides.
        guard !isClosePromptInFlight else { return false }
        isClosePromptInFlight = true
        defer { isClosePromptInFlight = false }
        let alert = NSAlert()
        alert.messageText = "Save this project before \(actionName)?"
        alert.informativeText = "Unsaved temporary project files will be removed if you discard them."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return await saveProjectAsInteractively()   // Save… (false if the panel is cancelled)
        case .alertSecondButtonReturn: discardUntitledProject(); return true        // Discard
        default:                       return false                                 // Cancel
        }
    }

    // MARK: - Recents bookkeeping

    /// The recents actually shown — existence-filtered at menu build so a deleted project never
    /// renders as a clickable item.
    var existingRecentProjectPaths: [String] {
        recentProjectPaths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// File ▸ Open Recent ▸ Clear Menu.
    func clearRecentProjects() {
        recentProjectPaths = []
        persistAppState()
    }

    /// Drop one entry (vanished recent, Save As's untitled-source cleanup) and persist.
    func pruneRecentProject(_ path: String) {
        recentProjectPaths.removeAll { $0 == path }
        persistAppState()
    }

    /// Fold a just-opened path into the host's MRU via the tested SZAppState helper (dedupe →
    /// front → cap). Caller persists (part of switchProject's history step).
    func noteRecentProject(_ path: String) {
        var state = SZAppState(recentProjectPaths: recentProjectPaths)
        state.noteRecentProject(path: path)
        recentProjectPaths = state.recentProjectPaths ?? []
    }

    // MARK: - Errors

    /// The project-op error surface: an app-modal alert (a status line is not enough for "your
    /// document didn't open"). `messageText` says what failed; the error says why.
    func presentProjectError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        // `localizedDescription` surfaces a LocalizedError's `errorDescription` (and Cocoa errors'
        // user-facing text) — plain `"\(error)"` would print the bare enum case.
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Lifecycle-specific failures (the ones with no underlying thrown error to show).
enum SZProjectLifecycleError: LocalizedError {
    case sampleMissing
    case notAProject
    case projectMissing
    case alreadyOpenElsewhere

    var errorDescription: String? {
        switch self {
        case .sampleMissing: "The bundled sample project is missing from the app's resources."
        case .notAProject: "Choose a folder with the .subz extension."
        case .projectMissing: "It may have been moved or deleted. It was removed from Open Recent."
        case .alreadyOpenElsewhere: "This project is already open in another SubjectiveZero instance."
        }
    }
}
