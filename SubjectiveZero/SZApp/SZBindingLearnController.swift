// SPDX-License-Identifier: AGPL-3.0-only
// The armed learn session: owns the ~30 Hz poll of a binding source's `lastEvent`/`lastKey` outputs
// and the SZCore election model that decides which control the user meant (SZBindingLearnModel
// holds the exclusion rules; this file only feeds it samples and time). At most one exists — learn
// is a focused human gesture — and it is ephemeral host state: reassignment sites cancel the old
// controller explicitly, and a node vanishing from the graph self-disarms. The render clock must
// be running for events to surface (the reads report the last encoded frame).
import Foundation
import SZCore

@MainActor
@Observable
final class SZBindingLearnController {
    let node: SZNodeID
    private(set) var model: SZBindingLearnModel
    private var pollTask: Task<Void, Never>?
    private unowned let host: SZHost

    var candidate: SZBindingLearnModel.Candidate? { model.candidate }

    init(host: SZHost, node: SZNodeID) {
        self.host = host
        self.node = node
        // The arm-time sample seeds the exclusion: whatever is mid-move right now is the previous
        // gesture, not the answer. seq 0 (or no key) means the source never emitted — nothing to exclude.
        let armEvent: (seq: Int, key: String)? = Self.sample(host: host, node: node).map { (seq: $0.seq, key: $0.key) }
        self.model = SZBindingLearnModel(armEvent: armEvent, at: Date())
        startPolling()
    }

    /// Stop observing. Idempotent; the controller is inert afterwards (a fresh arm builds a fresh
    /// controller rather than rearming this one).
    func cancel() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One read of the learn signal: `lastEvent` `[seq, value01]` + `lastKey`. nil in the runtime
    /// reload window, before the source's first event, or with a paused clock.
    private static func sample(host: SZHost, node: SZNodeID) -> (seq: Int, key: String, value01: Double)? {
        guard let values = host.runtime?.readOutputFloats(node: node, port: SZBindingSource.lastEventOutput),
              values.count >= 2, values[0] > 0,
              let key = host.runtime?.readOutputString(node: node, port: SZBindingSource.lastKeyOutput),
              !key.isEmpty else { return nil }
        return (seq: Int(values[0]), key: key, value01: Double(values[1]))
    }

    private func startPolling() {
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self else { return }
                // The node left the graph (delete, project switched under us): disarm — a candidate
                // for a vanished source must never reach a commit.
                guard self.host.store.project?.graph.node(id: self.node) != nil else {
                    self.cancel()
                    if self.host.bindingLearn === self { self.host.bindingLearn = nil }
                    return
                }
                // A nil read is the reload window (or a paused clock) — skip, don't disarm.
                guard let sample = Self.sample(host: self.host, node: self.node) else { continue }
                self.model.observe(seq: sample.seq, key: sample.key, value01: sample.value01, at: Date())
            }
        }
    }
}
