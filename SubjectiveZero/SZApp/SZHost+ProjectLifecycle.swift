// SPDX-License-Identifier: AGPL-3.0-only
// Project lifecycle — the document-UI intents behind Project ▸ New / Open… / Open Recent /
// Save As…, and the launch chain. This file owns WHEN each runs (panels, menu items, launch) and
// the error surface (NSAlert — testers must see why an open failed, not read a status line); the
// mechanics live in SZHost (switchProject, relocateProject), which touches private host state.
//
// There is NO Save item for a placed project: it is written as it changes (persistProject on every
// edit), so one would imply dirty state that doesn't exist. An untitled project is the real case —
// it has nowhere to save yet — so it shows Save… on ⌘S, which opens the Save As panel.
//
// Two classes of intent, and only one of them can hurt a working fleet:
//  - PLACE the document (Save As): duplicate-and-relocate. Writes, tears nothing down, so agent
//    activity is no reason to refuse it.
//  - REPLACE the document (New, Open, Open Recent): switchProject tears live runs down, so these
//    refuse while an agent owns the project.
import AppKit
import Foundation
import SZCore
import UniformTypeIdentifiers

extension SZHost {
    /// New / Open / Open Recent REPLACE the document, so they refuse while an agent owns it:
    /// `switchProject` tears live runs down, and their output would land in the next project's
    /// store. An open counts too, so a second one can't start on top of one. Does NOT gate edits.
    /// Menu items disable on this; the methods guard on it too (the MCP surface can race a click).
    var isBusyForProjectSwitch: Bool { agentsOwnProject || openingProject != nil }

    /// Save As refuses only while the document is mid-swap — what we would write is about to be
    /// replaced. Agent activity is deliberately absent: it tears nothing down (`relocateProject`),
    /// and the app is already writing this project to disk throughout a run.
    var isOpeningProject: Bool { openingProject != nil }

    /// The agent half alone: what `switchProject` re-checks across its own suspensions, where the
    /// opening flag is its own and must not read as someone else's claim. The `chatInFlight` term
    /// is NOT redundant with the claims: `cancelRun` releases eagerly while a killed CLI can stream
    /// for seconds more, and the physical stream is still writing during that window.
    /// Queued-but-undelivered messages deliberately do NOT block (they persist and redeliver).
    var agentsOwnProject: Bool { isRunning || ledger.anyHeld || !chatInFlight.isEmpty }

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
        guard !isBusyForProjectSwitch else { return }
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
        guard !isBusyForProjectSwitch else { return }
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
        guard !isBusyForProjectSwitch else { return }
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

    /// A Save As that turned out to name the project we are already in. There is deliberately no
    /// Save item for a placed project — it is written as it changes — so this is not "saving", it is
    /// landing the one thing automatic persistence cannot: a prompt still being typed. It must NOT
    /// re-enter the panel, or picking your own project would bounce you straight back into it.
    private func saveInPlace() {
        flushPendingPromptEdit()
        flushEverything()
        status = "saved \(loadedProjectURL?.lastPathComponent ?? "project")"
    }

    /// File ▸ Save As… (⇧⌘S) — the menu's entry point; only the quit prompt cares about the result.
    func saveProjectAs() {
        saveProjectAsInteractively()
    }

    /// Copy the bundle, then relocate onto the copy — never a switch, which is what made a save
    /// unsafe mid-run. Untitled → the temp folder goes once the new location is written AND
    /// recorded, so a crash between the two still reopens one of them; saved → the source stays,
    /// as a duplicate does. Not async on purpose: everything after the panel is one uninterruptible
    /// MainActor stretch, and a signature that cannot suspend keeps a future `await` out of it.
    /// True iff the project was saved — the quit prompt reads this to decide whether to proceed.
    @MainActor
    @discardableResult
    func saveProjectAsInteractively() -> Bool {
        // Checked up front as well as after the panel: showing a whole save panel that can only end
        // in silence is worse than refusing. Same fact the menu items grey out on.
        guard !isOpeningProject, hasSavableProject, let project = store.project else { return false }
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
        // Re-read AFTER the panel: `runModal` spins a nested runloop that pumps the MainActor, so a
        // turn, a delivery or a promote can have landed while it was up.
        guard let sourceURL = loadedProjectURL, store.project != nil else { return false }
        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let target = dest.resolvingSymlinksInPath().standardizedFileURL
        // Saving onto ourselves is a Save, not a copy — the removeItem below would delete the live
        // bundle and the copy would then have nothing to read.
        guard target != source else { saveInPlace(); return true }
        // A destination under whatever this save will REMOVE afterwards: inside the bundle it would
        // recurse the copy, and for an untitled rescue the cleanup takes the whole `Projects/<uuid>/`
        // wrapper, so a sibling picked in that folder would be deleted moments after being written.
        let doomed = SZUntitledProjects.contains(sourceURL) ? source.deletingLastPathComponent() : source
        guard !target.path.hasPrefix(doomed.path + "/") else {
            presentProjectError("Can't save inside the project itself",
                                SZProjectLifecycleError.destinationInsideProject)
            return false
        }

        let fm = FileManager.default
        do {
            // One synchronous stretch from here: every host write into the bundle is MainActor, so
            // not suspending is what makes the copy atomic against the agents still working in it.

            // Freeze the source COMPLETELY — the new location has to carry the whole recovery set
            // (transcripts, both queues, run history, graph), not the graph alone.
            flushPendingPromptEdit()
            flushEverything()

            // Delete-then-copy (the panel already got the user's replace confirm). But first, if
            // we're about to overwrite an existing bundle, make sure no other instance has it open —
            // the destructive removeItem would otherwise delete a live project out from under it.
            // A liveness probe: take then immediately drop its lock (we're overwriting).
            if fm.fileExists(atPath: dest.path) {
                do {
                    try SZProjectDirectoryLock.acquire(forProjectAt: dest).release()
                } catch SZProjectLockError.alreadyLocked {
                    presentProjectError("Can't save over “\(dest.lastPathComponent)”",
                                        SZProjectLifecycleError.alreadyOpenElsewhere)
                    return false
                }   // .cannotOpen (dest isn't lockable, e.g. not our bundle) → proceed to overwrite
                try fm.removeItem(at: dest)
            }
            // `.staging` travels: the destination IS the live document now, so its undelivered
            // messages, scheduled asks, feed epoch and the fleet's not-yet-promoted node sources
            // must move with it. The copied instance.lock is inert — flock state is per open file
            // description and is not copied — and `relocateProject` takes its own.
            try fm.copyItem(at: sourceURL, to: dest)
            do {
                // The one writer outside the MainActor discipline is a spawned CLI, which holds the
                // bundle as a writable directory. Reading the copy back turns a torn write into a
                // clean failure instead of a silently corrupt save.
                _ = try SZProjectIO.load(from: dest)
                try relocateProject(to: dest)   // releases the source lock, takes the dest lock
            } catch {
                // Nothing has moved yet, so the half-written copy is litter — take it back out
                // rather than leaving a bundle the user never got.
                try? fm.removeItem(at: dest)
                throw error
            }

            // The document takes its new name from where the user put it.
            store.mutate { $0.name = dest.deletingPathExtension().lastPathComponent }
            persistProject()

            // LAST, and only now: the relocation has written the full set at the new path and
            // recorded it as the reopen target, so removing the temp home can no longer strand us.
            if SZUntitledProjects.contains(sourceURL) {
                try? fm.removeItem(at: sourceURL.deletingLastPathComponent())
                pruneRecentProject(sourceURL.standardizedFileURL.path)
            }
            status = "saved \(dest.lastPathComponent)"
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
        case .alertFirstButtonReturn:  return saveProjectAsInteractively()   // Save… (false if the panel is cancelled)
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
    case destinationInsideProject

    var errorDescription: String? {
        switch self {
        case .sampleMissing: "The bundled sample project is missing from the app's resources."
        case .notAProject: "Choose a folder with the .subz extension."
        case .projectMissing: "It may have been moved or deleted. It was removed from Open Recent."
        case .alreadyOpenElsewhere: "This project is already open in another SubjectiveZero instance."
        case .destinationInsideProject: "Pick a location outside the project you are saving."
        }
    }
}
