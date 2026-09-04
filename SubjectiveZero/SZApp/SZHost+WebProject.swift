// SPDX-License-Identifier: AGPL-3.0-only
// The web project's own actions: export the page as one standalone file, and open it in the
// default browser.
import AppKit
import Foundation
import SZCore
import UniformTypeIdentifiers

extension SZHost {
    /// Export needs a live web project whose page has its library (the export inlines it).
    var canExportWebApp: Bool {
        capabilities.exportsWebApp && loadedProjectURL != nil
            && webRuntime.map { SZWebLibraryStore.isReady($0.threeVersion) } == true
    }

    /// Project ▸ Export as Web App… (⇧⌘E): one `.html`, revealed in the Finder when written.
    func exportWebApp() {
        guard canExportWebApp, let project = store.project else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "\(project.name).html"
        panel.title = "Export as Web App"
        panel.prompt = "Export"
        panel.message = "One file that runs in any browser. No server needed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try writeWebApp(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            status = "exported \(url.lastPathComponent)"
        } catch {
            presentProjectError("Couldn't export the web app", error)
        }
    }

    /// Project ▸ Open in Browser: the same page, written into the project's `exports/` folder and
    /// handed to the default browser.
    func openWebAppInBrowser() {
        guard canExportWebApp, let project = store.project, let projectURL = loadedProjectURL else { return }
        let folder = projectURL.appending(path: "exports")
        let url = folder.appending(path: "\(project.name).html")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeWebApp(to: url)
            NSWorkspace.shared.open(url)
            status = "opened \(url.lastPathComponent) in the browser"
        } catch {
            presentProjectError("Couldn't open the web app", error)
        }
    }

    private func writeWebApp(to url: URL) throws {
        guard let project = store.project, let projectURL = loadedProjectURL, let web = webRuntime else {
            throw SZMCPError.message("no web project loaded")
        }
        let page = try SZWebAppExport.page(project: project, projectURL: projectURL,
                                           runtimeDirectory: SZWebRuntime.runtimeDirectory,
                                           libraryDirectory: SZWebLibraryStore.directory(for: web.threeVersion))
        try page.write(to: url, atomically: true, encoding: .utf8)
    }
}
