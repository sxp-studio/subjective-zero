// SPDX-License-Identifier: AGPL-3.0-only
// Data-edge topology — the one home of the DAG invariant. The runtime scheduler orders each frame
// with `topologicalOrder` (Kahn); the connect surfaces ask `wouldCloseCycle` BEFORE adding a data
// edge so a cycle is refused where it is attempted; and `repairDataCycles` is the load-time repair
// for a persisted cycle (a hand-edited or externally-written file), so no project fails to open for
// this reason. Flow edges are authoring intent, never checked — intent may legitimately point
// "backwards" (GRAPH_AND_NODES).
import Foundation

extension SZGraph {
    /// Kahn's algorithm over DATA edges (flow is authoring intent, not runtime order). Returns nil on a
    /// cycle. Ties broken by graph node order for determinism. Self-loops and edges naming missing
    /// nodes are skipped — they cannot order anything.
    public func topologicalOrder() -> [SZNodeID]? {
        let nodeIDs = nodes.map(\.id)
        let index = Dictionary(uniqueKeysWithValues: nodeIDs.enumerated().map { ($1, $0) })
        var indegree = Dictionary(uniqueKeysWithValues: nodeIDs.map { ($0, 0) })
        var successors: [SZNodeID: [SZNodeID]] = [:]
        for connection in connections where connection.kind == .data {
            let from = connection.from.node, to = connection.to.node
            guard index[from] != nil, index[to] != nil, from != to else { continue }
            successors[from, default: []].append(to)
            indegree[to, default: 0] += 1
        }

        var ready = nodeIDs.filter { indegree[$0] == 0 }.sorted { index[$0]! < index[$1]! }
        var result: [SZNodeID] = []
        while let next = ready.first {
            ready.removeFirst()
            result.append(next)
            for successor in successors[next] ?? [] {
                indegree[successor]! -= 1
                if indegree[successor] == 0 {
                    let position = ready.firstIndex { index[$0]! > index[successor]! } ?? ready.endIndex
                    ready.insert(successor, at: position)
                }
            }
        }
        return result.count == nodeIDs.count ? result : nil
    }

    /// Would a DATA edge `from → to` close a cycle? Returns the offending node walk
    /// (`from → to → … → from`, ready for a titled "A → B → A" message), nil if the edge is safe.
    /// A self-loop is refused here (`[from, from]`): the scheduler kernel deliberately skips
    /// self-loops rather than failing on them, so this guard is the only thing that stops one.
    public func wouldCloseCycle(from: SZNodeID, to: SZNodeID) -> [SZNodeID]? {
        if from == to { return [from, from] }
        // Reachability walk from `to` seeking `from`, over the same edge set the kernel orders by
        // (data only, both endpoints present, no self-loops); parents reconstruct the path.
        let known = Set(nodes.map(\.id))
        var successors: [SZNodeID: [SZNodeID]] = [:]
        for c in connections where c.kind == .data && c.from.node != c.to.node
            && known.contains(c.from.node) && known.contains(c.to.node) {
            successors[c.from.node, default: []].append(c.to.node)
        }
        var parents: [SZNodeID: SZNodeID] = [:]
        var visited: Set<SZNodeID> = [to]
        var frontier = [to]
        while let node = frontier.popLast() {
            for next in successors[node] ?? [] where visited.insert(next).inserted {
                parents[next] = node
                if next == from {
                    var chain = [from]           // from back up to `to`, via the discovery parents
                    var cursor = from
                    while cursor != to, let parent = parents[cursor] {
                        chain.append(parent)
                        cursor = parent
                    }
                    return [from] + chain.reversed()
                }
                frontier.append(next)
            }
        }
        return nil
    }

    /// Drop data edges until the graph orders again — the load-time repair for a persisted cycle.
    /// While `topologicalOrder()` fails, the LAST cycle-participating data edge in `connections`
    /// order goes (insertion order, so the newest edge is dropped first — deterministic). Returns
    /// the dropped edges in drop order.
    public mutating func repairDataCycles() -> [SZConnection] {
        var dropped: [SZConnection] = []
        while topologicalOrder() == nil {
            // An edge sits on a cycle exactly when its target already reaches its source. Self-loops
            // are excluded: the kernel skips them, so they are never why the order failed.
            guard let index = connections.lastIndex(where: { c in
                c.kind == .data && c.from.node != c.to.node
                    && wouldCloseCycle(from: c.from.node, to: c.to.node) != nil
            }) else { break }
            dropped.append(connections.remove(at: index))
        }
        return dropped
    }
}
