// SPDX-License-Identifier: AGPL-3.0-only
// Whether a file port's value can actually be used, and if not, one sentence saying why.
//
// A node reading a file it cannot open just renders black, which is indistinguishable from a node
// nobody has given a file yet. This is the check that tells those apart — and it is the SAME
// function behind the node's pill and behind `agent_check_path`, so the user and an agent never
// describe one fault in two vocabularies.
//
// The verdict that matters most is the LAST one: a file that is present and readable but is the
// wrong KIND. A bare existence check calls that "fine" and teaches nobody anything. What kinds a
// port takes comes from the port's own `ui.fileTypes` — nothing here knows any file format.
//
// A SNAPSHOT, not live state: one `stat` at the moment it is asked. The host re-asks on writes, on
// contract changes, on project open and when the app comes back to the front; between those a
// deleted file still reads clean. Never call it per frame or from a view body — a stalled network
// mount makes a `stat` block.
import Foundation

public enum SZFileInputAudit {
    /// Why this value cannot be used, or nil when it can. `accepting` is the port's accepted
    /// extensions (empty = any file); `projectURL` resolves a bundle-relative value.
    public static func fault(path: String, accepting: [String], in projectURL: URL) -> String? {
        // Unset is NOT a fault: a node with no file yet is waiting, not broken.
        guard !path.isEmpty else { return nil }
        let resolved = SZProjectMedia.resolve(path, in: projectURL)
        let url = URL(fileURLWithPath: resolved)
        let name = url.lastPathComponent

        guard let values = try? url.resourceValues(forKeys: [.isReadableKey, .isDirectoryKey, .isPackageKey])
        else { return "no file at \(resolved)" }
        guard values.isReadable == true else { return "\(name) is not readable (permissions): \(resolved)" }

        let ext = url.pathExtension.lowercased()
        if !accepting.isEmpty {
            guard accepting.contains(ext) else {
                let kinds = accepting.map { ".\($0)" }.joined(separator: " or ")
                let has = ext.isEmpty ? "has no extension" : "is a .\(ext)"
                return "\(name) \(has), and this port takes \(kinds)"
            }
            // A declared extension may name a package, so a matching directory is exactly right.
            return nil
        }
        // Nothing declared: a plain folder is still the wrong thing to hand a file port. A PACKAGE is
        // a file as far as anyone using it is concerned, so it passes.
        if values.isDirectory == true, values.isPackage != true { return "\(name) is a folder, not a file" }
        return nil
    }

    /// Every file input of `node` that cannot be used right now, port name → reason. Ports fed by a
    /// data edge are skipped: their value arrives at runtime, so the stored default says nothing.
    public static func faults(in node: SZNode, connected: Set<String>, projectURL: URL) -> [String: String] {
        var faults: [String: String] = [:]
        for port in node.contract?.inputs ?? [] where port.ui?.kind == .filePicker {
            guard !connected.contains(port.name), case .string(let value)? = port.def else { continue }
            if let reason = fault(path: value, accepting: port.ui?.acceptedExtensions ?? [], in: projectURL) {
                faults[port.name] = reason
            }
        }
        return faults
    }

    /// The inputs of `node` that a `data` edge feeds — what `faults(in:connected:)` wants.
    public static func connectedInputs(of node: SZNodeID, in graph: SZGraph) -> Set<String> {
        Set(graph.connections.filter { $0.kind == .data && $0.to.node == node }.map(\.to.port))
    }
}
