// SPDX-License-Identifier: AGPL-3.0-only
// The web project's page is served in-process over `subz://app/...`, no socket, no server: the runtime
// files from the app bundle, three.js from the version cache, and the project's own node files from
// its `.subz`. One host (`app`) so every module import is same-origin. Read-only but for the one POST
// door for preview atlases, traversal-guarded, never cached by WebKit (a hot reload bumps `?v=` anyway).
import Foundation
import WebKit

final class SZWebSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "subz"
    static let indexURL = URL(string: "subz://app/runtime/index.html")!

    private let runtimeDirectory: URL
    private let libraryDirectory: URL
    private let projectURL: URL
    private let threeVersion: String

    init(runtimeDirectory: URL, libraryDirectory: URL, projectURL: URL, threeVersion: String) {
        self.runtimeDirectory = runtimeDirectory
        self.libraryDirectory = libraryDirectory
        self.projectURL = projectURL
        self.threeVersion = threeVersion
    }

    /// Where the page's POSTed preview atlases land (`subz://app/previews?layout=&seq=`): the raw body and
    /// the request URL. WebKit delivers the task on the main thread, so the sink must hand the bytes off.
    var onPreviewBody: ((Data, URL) -> Void)?

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        if task.request.httpMethod == "POST" {
            guard url.host() == "app", url.path == "/previews", let body = task.request.httpBody else {
                task.didFailWithError(URLError(.unsupportedURL))
                return
            }
            onPreviewBody?(body, url)
            task.didReceive(HTTPURLResponse(url: url, statusCode: 204, httpVersion: "HTTP/1.1",
                                            headerFields: ["Access-Control-Allow-Origin": "*"])!)
            task.didFinish()
            return
        }
        guard let (data, mime) = resource(for: url) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
            "Access-Control-Allow-Origin": "*",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// `/runtime/<file>` → bundle, `/lib/three/<version>/<file>` → cache, `/project/<path>` → the `.subz`.
    private func resource(for url: URL) -> (Data, String)? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.host() == "app", parts.count >= 2 else { return nil }
        let root: URL
        let rest: [String]
        switch parts[0] {
        case "runtime":
            root = runtimeDirectory
            rest = Array(parts[1...])
        case "lib":
            guard parts.count >= 4, parts[1] == "three", parts[2] == threeVersion else { return nil }
            root = libraryDirectory
            rest = Array(parts[3...])
        case "project":
            root = projectURL
            rest = Array(parts[1...])
        default:
            return nil
        }
        guard !rest.contains(where: { $0 == ".." || $0.isEmpty }) else { return nil }
        let file = rest.reduce(root) { $0.appending(path: $1) }.standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/"),
              var data = try? Data(contentsOf: file) else { return nil }
        if parts[0] == "runtime", rest == ["index.html"] {
            // the page pins its three.js through the importmap; the version is the project's
            let page = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "__THREE_VERSION__", with: threeVersion)
            data = Data(page.utf8)
        }
        return (data, Self.mimeType(for: file.pathExtension))
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "json": "application/json"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "css": "text/css"
        default: "application/octet-stream"
        }
    }
}
