// SPDX-License-Identifier: AGPL-3.0-only
// The file-input audit: what makes a file port's value unusable, and what deliberately does not.
// The load-bearing case is the LAST one — a file that is present and readable but the wrong kind,
// which a bare existence check calls fine.
import Foundation
import Testing
@testable import SZCore

private struct Scratch {
    let root: URL
    init() {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "sz-file-audit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func file(_ name: String) -> URL {
        let url = root.appending(path: name)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        return url
    }
    func folder(_ name: String) -> URL {
        let url = root.appending(path: name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Test func anUnsetFileInputIsNotAFault() {
    let s = Scratch(); defer { s.cleanUp() }
    #expect(SZFileInputAudit.fault(path: "", accepting: [], in: s.root) == nil)
}

@Test func aMissingFileNamesThePathItLookedAt() {
    let s = Scratch(); defer { s.cleanUp() }
    let reason = SZFileInputAudit.fault(path: "gone.mov", accepting: [], in: s.root)
    #expect(reason?.hasPrefix("no file at ") == true)
    #expect(reason?.hasSuffix("/gone.mov") == true)
}

@Test func aFileInsideTheProjectIsCleanEvenThoughItsValueIsRelative() {
    let s = Scratch(); defer { s.cleanUp() }
    _ = s.folder("media/ABC")
    _ = s.file("media/ABC/IMG.MOV")
    #expect(SZFileInputAudit.fault(path: "media/ABC/IMG.MOV", accepting: [], in: s.root) == nil)
}

@Test func anAbsolutePathOutsideTheProjectIsJudgedWhereItActuallyIs() {
    let s = Scratch(); defer { s.cleanUp() }
    let outside = s.file("Downloads.MOV")
    // Resolved as itself, NOT joined to the bundle — which is what keeps an older project rendering.
    #expect(SZFileInputAudit.fault(path: outside.path, accepting: [],
                                   in: s.root.appending(path: "Elsewhere.subz")) == nil)
}

@Test func aWrongKindOfFileSaysWhatItIsAndWhatThePortTakes() {
    let s = Scratch(); defer { s.cleanUp() }
    let model = s.file("Depth.mlmodel")
    let reason = SZFileInputAudit.fault(path: model.path, accepting: ["mlpackage", "mlmodelc"], in: s.root)
    #expect(reason == "Depth.mlmodel is a .mlmodel, and this port takes .mlpackage or .mlmodelc")
}

@Test func aFileWithNoExtensionSaysSoRatherThanNamingAnEmptyKind() {
    let s = Scratch(); defer { s.cleanUp() }
    let odd = s.file("Depth")
    let reason = SZFileInputAudit.fault(path: odd.path, accepting: ["mlpackage"], in: s.root)
    #expect(reason == "Depth has no extension, and this port takes .mlpackage")
}

/// The point of declaring extensions: a FOLDER whose name matches is the file, whether or not this
/// Mac has an app that registered the type.
@Test func aFolderShapedFileIsAcceptedWhenThePortDeclaresItsExtension() {
    let s = Scratch(); defer { s.cleanUp() }
    let package = s.folder("Depth.mlpackage")
    #expect(SZFileInputAudit.fault(path: package.path, accepting: ["mlpackage"], in: s.root) == nil)
}

@Test func aPlainFolderIsAFaultWhenNothingIsDeclared() {
    let s = Scratch(); defer { s.cleanUp() }
    let folder = s.folder("Clips")
    #expect(SZFileInputAudit.fault(path: folder.path, accepting: [], in: s.root) == "Clips is a folder, not a file")
}

@Test func anUnreadableFileIsNamedAsAPermissionProblemNotAMissingOne() {
    let s = Scratch(); defer { s.cleanUp() }
    let locked = s.file("locked.mov")
    try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    let reason = SZFileInputAudit.fault(path: locked.path, accepting: [], in: s.root)
    #expect(reason?.contains("not readable") == true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
}

// MARK: - Over a whole node

private func node(_ ports: [SZPort]) -> SZNode {
    SZNode(kind: .generated, title: "Depth Map",
           contract: SZNodeContract(title: "Depth Map", sfSymbol: "cube", summary: "", inputs: ports),
           position: SZPoint(x: 0, y: 0))
}

@Test func onlyFilePortsAreAudited() {
    let s = Scratch(); defer { s.cleanUp() }
    let n = node([
        SZPort(name: "modelPath", type: .string, ui: SZPortUI(kind: .filePicker), def: .string("gone.mlpackage")),
        SZPort(name: "label", type: .string, ui: SZPortUI(kind: .field), def: .string("gone.mlpackage")),
        SZPort(name: "gain", type: .float, ui: SZPortUI(kind: .slider), def: .float(1)),
    ])
    let faults = SZFileInputAudit.faults(in: n, connected: [], projectURL: s.root)
    #expect(Array(faults.keys) == ["modelPath"])
}

/// A port fed by a wire ignores its stored default, so judging that default would be a lie.
@Test func aConnectedFilePortIsSkipped() {
    let s = Scratch(); defer { s.cleanUp() }
    let n = node([SZPort(name: "modelPath", type: .string, ui: SZPortUI(kind: .filePicker),
                         def: .string("gone.mlpackage"))])
    #expect(SZFileInputAudit.faults(in: n, connected: ["modelPath"], projectURL: s.root).isEmpty)
}

@Test func connectedInputsCountsOnlyDataEdgesIntoThisNode() {
    let a = SZNodeID(), b = SZNodeID()
    let graph = SZGraph(nodes: [], connections: [
        SZConnection(from: SZPortRef(node: a, port: "output"), to: SZPortRef(node: b, port: "modelPath"), kind: .data),
        SZConnection(from: SZPortRef(node: a, port: "output"), to: SZPortRef(node: b, port: "flowPort"), kind: .flow),
        SZConnection(from: SZPortRef(node: b, port: "output"), to: SZPortRef(node: a, port: "other"), kind: .data),
    ])
    #expect(SZFileInputAudit.connectedInputs(of: b, in: graph) == ["modelPath"])
}
