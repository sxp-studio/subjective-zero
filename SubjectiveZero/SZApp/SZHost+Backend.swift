// SPDX-License-Identifier: AGPL-3.0-only
// The host's one way to bring a renderer up: prepare (abandonable, nothing live touched) then mount.
// Opening a project and switching its target platform both go through here, so the page and the Metal
// runtime come up the same way whichever door the user took.
import Foundation
import SZCore
import SZRuntime

/// What `prepareBackend` made and `mountBackend` installs, once the Metal side committed.
struct SZPreparedBackend {
    /// The Metal side, ready to commit: the project's graph, or an empty one for a web project.
    let native: SZRuntime.SZPreparedLoad
    /// The page, started, for a web project.
    let page: SZWebRuntime?
}

extension SZHost {
    /// What the open project's renderer can do; the Metal runtime's set with nothing open.
    var capabilities: SZBackendCapabilities { backend?.capabilities ?? .native }

    /// Everything that can be done before the old project is disturbed: permissions, the Metal prepare
    /// (an empty graph for a web project, so its commit unloads the old native nodes), and for a web
    /// project the page with its three.js. Drop the result to abandon it.
    func prepareBackend(for project: SZProject, at url: URL, runtime: SZRuntime) async throws -> SZPreparedBackend {
        await runtime.requestDeclaredPermissions(for: project)
        // A Mac project on a Mac without Apple's developer tools compiles nothing: the same empty
        // prepare a browser project gets. The install landing rebuilds it (SZHost+Toolchain.swift).
        // Re-probe first: an install that landed while no sheet was polling counts now.
        if project.target == .native, toolchainMissing { await refreshToolchainAvailability() }
        nativeProjectAwaitingTools = project.target == .native && toolchainMissing
        let native = project.target == .web || nativeProjectAwaitingTools
            ? SZProject(name: project.name, author: project.author, viewport: project.viewport, target: project.target)
            : project
        let prepared = try await runtime.prepareProject(native, at: url)
        var page: SZWebRuntime?
        if project.target == .web {
            let web = SZWebRuntime(projectURL: url,
                                   threeVersion: project.web?.threeVersion ?? SZProjectWeb.currentThreeVersion)
            await web.start()
            page = web
        }
        return SZPreparedBackend(native: prepared, page: page)
    }

    /// Install a prepared backend after `runtime.commit` took its Metal side: the old page goes, the new
    /// one (if any) becomes `backend`, and node errors and thumbnails route to it. Synchronous, so
    /// nothing interleaves.
    func mountBackend(_ prepared: SZPreparedBackend) {
        webRuntime?.unmount()
        webRuntime = prepared.page
        lastPushedWatchKeys = []   // so the next refreshPreviewStream reaches the new backend even with the same set
        if let page = prepared.page {
            installNodeErrorSink(page)
            installPreviewFrameSink(page)
            // the Metal runtime holds an empty graph under a web project: nothing for it to thumbnail
            runtime?.setWatchedPreviews([], maxDimension: Self.previewMaxDimension)
        }
    }

    /// Push the open project's graph to its renderer again after an edit that is already saved.
    func reloadBackendGraph(at url: URL) throws {
        // A Mac project waiting for the tools keeps its empty graph: a reload here would compile
        // every node through the missing compiler. The install landing rebuilds it.
        guard !nativeProjectAwaitingTools, let project = store.project else { return }
        try backend?.loadProject(project, at: url)
    }
}
