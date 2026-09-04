// SPDX-License-Identifier: AGPL-3.0-only
// The synchronous half of a web node's compile gate: a JavaScriptCore parse. It reports a syntax error
// with its line without a page, so the gate can answer before the page is up. The page's own check
// (import, setup, a few updates) is the second half.
import Foundation
import JavaScriptCore
import SZCore

enum SZWebNodeCheck {
    static func parse(source: String) -> SZBuildResult {
        let lines = source.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("import ") || trimmed.hasPrefix("import{") || trimmed.hasPrefix("import\"")
        }) {
            return .failed("Node.js must not import anything: three.js arrives as ctx.three. Remove the import on line \(index + 1).")
        }
        guard source.contains("export default") else {
            return .failed("Node.js must `export default class Node { setup(ctx) {} update(ctx) {} }`.")
        }
        // the module is parsed as a function body so the class statement needs no module context
        let body = source.replacingOccurrences(of: "export default", with: "")
        guard let context = JSContext() else { return .failed("JavaScript engine unavailable") }
        var failure: String?
        context.exceptionHandler = { _, exception in
            let message = exception?.toString() ?? "syntax error"
            if let line = exception?.forProperty("line")?.toInt32(), line > 0 {
                // one line of wrapper above the source
                failure = "\(message) (line \(max(1, Int(line) - 1)))"
            } else {
                failure = message
            }
        }
        context.evaluateScript("(function() {\n" + body + "\n})")
        if let failure { return .failed(failure) }
        return .ok
    }
}
