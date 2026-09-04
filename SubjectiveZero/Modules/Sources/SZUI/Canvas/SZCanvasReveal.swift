// SPDX-License-Identifier: AGPL-3.0-only
// Whether the node editor may move its camera to show nodes an agent just added. The rule: the
// canvas belongs to whoever touched it last. A chat message hands it to the agent; any pan, zoom,
// drag, select or edit takes it back until the next message. Pure, unit-tested headlessly.
import Foundation

enum SZCanvasReveal {
    /// True when the agent may move the camera: the user asked (`askedAt`, their last chat send) and
    /// has not touched the canvas since (`userTouchedAt`), and no gesture or prompt edit is in flight.
    static func mayMove(userTouchedAt: Date?, askedAt: Date?, interacting: Bool) -> Bool {
        guard !interacting, let askedAt else { return false }
        return (userTouchedAt ?? .distantPast) < askedAt
    }
}
