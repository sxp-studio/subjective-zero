// SPDX-License-Identifier: AGPL-3.0-only
// Export as Web App: one self-contained `.html` a web project runs from anywhere. The page runtime,
// three.js and every node's source are inlined (modules as data: URLs through an importmap), the
// graph rides as a boot payload, and a no-op transport stands in for the app. No network, no server,
// no reference back to the app's `subz://` scheme.
import Foundation
import SZCore

enum SZWebAppExport {
    enum Failure: Error, LocalizedError {
        case missing(String)
        case libraryShape

        var errorDescription: String? {
            switch self {
            case .missing(let what): "Could not export: \(what) is missing."
            case .libraryShape: "Could not export: this three.js build does not look like the one the app knows."
            }
        }
    }

    /// The whole page. `libraryDirectory` holds the project's pinned three.js files (SZWebLibraryStore).
    static func page(project: SZProject, projectURL: URL, runtimeDirectory: URL, libraryDirectory: URL) throws -> String {
        let runtime = try read(runtimeDirectory.appending(path: "sz-runtime.js"), "the page runtime")
        var module = try read(libraryDirectory.appending(path: SZWebLibraryStore.moduleFile), "three.js")
        let core = try read(libraryDirectory.appending(path: SZWebLibraryStore.coreFile), "three.js")
        // the module imports its core by relative path; a data: URL has no path, so it goes by name
        let rewritten = module.replacingOccurrences(of: "\"./three.core.min.js\"", with: "\"three-core\"")
            .replacingOccurrences(of: "'./three.core.min.js'", with: "'three-core'")
        guard rewritten != module else { throw Failure.libraryShape }
        module = rewritten

        let payload = SZWebRuntime.loadPayload(project: project, projectURL: projectURL) { node in
            let source = SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: node.id, target: .web)
            guard let data = try? Data(contentsOf: source) else { return nil }
            return dataURL(data)
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let bootData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw Failure.missing("the graph")
        }
        let boot = String(decoding: bootData, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
        let importmap = "{ \"imports\": { \"three\": \"\(dataURL(Data(module.utf8)))\", \"three-core\": \"\(dataURL(Data(core.utf8)))\" } }"
        let title = project.name.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <script type="importmap">\(importmap)</script>
        <style>
          html, body { margin: 0; height: 100%; background: #000; overflow: hidden; }
          canvas { display: block; width: 100%; height: 100%; }
        </style>
        </head>
        <body>
        <canvas id="sz-canvas"></canvas>
        <script>
        // the exported page has no app behind it: the graph boots from here, and messages go nowhere
        window.sz = Object.freeze({ onMessage: () => {}, post: () => {}, boot: \(boot) });
        </script>
        <script type="module">
        \(runtime.replacingOccurrences(of: "</script", with: "<\\/script"))
        </script>
        </body>
        </html>
        """
    }

    static func dataURL(_ data: Data) -> String {
        "data:text/javascript;base64," + data.base64EncodedString()
    }

    private static func read(_ url: URL, _ what: String) throws -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.missing(what) }
        return text
    }
}
