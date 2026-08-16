// SPDX-License-Identifier: AGPL-3.0-only
// The `binding_*` MCP surface — the learn-to-bind vocabulary (agent-facing: this is how the Director
// turns "give me a knob for X" into graph state). The flow: arm learn on a binding-source node (MIDI,
// OSC, …), ask the human to move the control they want, poll until the move is seen, then commit —
// which lands as ONE store transaction (mappings row + a derived output on the instance contract +
// a data edge to the target). Everything durable is ordinary graph state: readable, persisted.
// This file only parses arguments: the arm lives in SZBindingLearnController and the commit/remove
// path in SZHost+DerivedBinding — one implementation shared with the controller cards' verbs.
import Foundation
import SZCore

extension SZHostBridge {
    nonisolated static var bindingToolDefinitions: [[String: Any]] {
        let node = ["type": "string", "description": "the binding-source node's id (UUID) — a controller node such as MIDI Input or OSC Input"]
        return [
            tool("binding_learn_start", "Arm learn on a controller node, then ask the user to move the physical control they want to bind (e.g. \"twist the knob you'd like to use for blur\"). Poll `binding_learn_state` until it reports the move. The render clock must be running.",
                 properties: ["node": node]),
            tool("binding_learn_stop", "Disarm learn without committing.",
                 properties: ["node": node]),
            tool("binding_learn_state", "The armed learn session's state: `{armed, seen, key, value01}`. `seen:true` means a control moved since arming — `key` identifies it (MIDI `ch1/cc7`, OSC `/1/fader1`); that's the control `binding_commit` binds if no `key` is passed explicitly.",
                 properties: ["node": node]),
            tool("binding_commit", "Commit a controller binding on a controller node: adds a `mappings` entry and surfaces it as a float output on the node (pre-scaled min→max) — one transaction, all ordinary graph state. With `target`, also wires that output to the target input; WITHOUT one, learn MINTS the output socket and the user wires it by hand. Rebinding an already-bound target — or re-learning the same key targetless — REPLACES in place. `key` defaults to the control the armed learn session elected; `min`/`max` default to the target port's declared range (0–1 when targetless).",
                 properties: [
                    "node": node,
                    "target": ["type": "object", "description": "{node: uuid, port: name} — the float input to drive (optional: omit to mint an unwired output)"],
                    "key": ["type": "string", "description": "the control's wire key as the node reports it on lastKey (optional — defaults to the learned one)"],
                    "min": ["type": "number", "description": "output value at the control's minimum (optional)"],
                    "max": ["type": "number", "description": "output value at the control's maximum (optional)"],
                    "label": ["type": "string", "description": "human name for the binding; also names the output port (optional)"],
                 ]),
            tool("binding_remove", "Remove a binding by its output port name: drops the mappings entry, the derived output, and the edges it fed — one transaction.",
                 properties: [
                    "node": node,
                    "port": ["type": "string", "description": "the binding's output port name"],
                 ]),
        ]
    }

    /// Handle a `binding_*` call, or nil if `name` isn't ours.
    func handleBindingTool(name: String, arguments: [String: Any]) throws -> String? {
        switch name {
        case "binding_learn_start": return try bindingLearnStart(arguments)
        case "binding_learn_stop":  return try bindingLearnStop(arguments)
        case "binding_learn_state": return try bindingLearnState(arguments)
        case "binding_commit":      return try bindingCommit(arguments)
        case "binding_remove":      return try bindingRemove(arguments)
        default: return nil
        }
    }

    // MARK: - handlers

    private func bindingLearnStart(_ arguments: [String: Any]) throws -> String {
        let node = try bindingSource(arguments)
        try host.armBindingLearn(source: node)
        return SZJSONRPC.encode(["armed": true, "node": node.uuidString])
    }

    private func bindingLearnStop(_ arguments: [String: Any]) throws -> String {
        let node = try bindingSource(arguments)
        host.cancelBindingLearn(source: node)
        return SZJSONRPC.encode(["armed": false])
    }

    private func bindingLearnState(_ arguments: [String: Any]) throws -> String {
        let node = try bindingSource(arguments)
        guard let learn = host.bindingLearn, learn.node == node else {
            return SZJSONRPC.encode(["armed": false, "seen": false])
        }
        guard let candidate = learn.candidate else {
            return SZJSONRPC.encode(["armed": true, "seen": false])
        }
        return SZJSONRPC.encode(["armed": true, "seen": true,
                                 "key": candidate.key, "value01": candidate.value01])
    }

    private func bindingCommit(_ arguments: [String: Any]) throws -> String {
        let node = try bindingSource(arguments)
        // Target is OPTIONAL: with one, the binding also wires output→target (the Director's flow);
        // without one, learn MINTS — table row + derived output socket, no edge — and the user wires
        // it by an ordinary canvas drag (the control-surface flow).
        var target: SZPortRef?
        if let rawTarget = arguments.object("target") {
            guard let targetNode = rawTarget.uuid("node"), let targetPort = rawTarget.string("port") else {
                throw SZMCPError.message("`target` must be {node: uuid, port: name}")
            }
            target = SZPortRef(node: targetNode, port: targetPort)
        }

        // Which control: an explicit key wins; otherwise the armed learn session's elected candidate.
        let key: String
        if let explicit = arguments.string("key"), !explicit.isEmpty {
            key = explicit
        } else {
            guard let learn = host.bindingLearn, learn.node == node, let candidate = learn.candidate else {
                throw SZMCPError.message("no control learned — arm binding_learn_start and have the user move one, or pass `key` explicitly")
            }
            key = candidate.key
        }

        let bound = try host.commitBinding(
            source: node, target: target, key: key,
            min: arguments.double("min"), max: arguments.double("max"),
            label: arguments.string("label"), origin: .agent)

        var payload: [String: Any] = ["key": bound.key, "port": bound.port,
                                      "min": bound.min, "max": bound.max]
        if let target = bound.target {
            payload["target"] = ["node": target.node.uuidString, "port": target.port]
        }
        return SZJSONRPC.encode(["bound": payload])
    }

    private func bindingRemove(_ arguments: [String: Any]) throws -> String {
        let node = try bindingSource(arguments)
        guard let portName = arguments.string("port") else {
            throw SZMCPError.message("binding_remove needs `port`")
        }
        try host.removeBinding(source: node, port: portName, origin: .agent)
        return SZJSONRPC.encode(["removed": portName])
    }

    // MARK: - helpers

    /// Resolve + validate the tool's `node` argument as a binding source (`SZNodeContract.isBindingSource`
    /// — shape-checked, not kind-checked: any node presenting the capability qualifies).
    private func bindingSource(_ arguments: [String: Any]) throws -> SZNodeID {
        guard let node = arguments.uuid("node") else {
            throw SZMCPError.message("binding tools need `node` (the controller node's UUID)")
        }
        guard host.store.project?.graph.node(id: node)?.contract?.isBindingSource == true else {
            throw SZMCPError.message("node \(node) is not a binding source (needs a `mappings` string input and a `lastKey` string output)")
        }
        return node
    }
}
