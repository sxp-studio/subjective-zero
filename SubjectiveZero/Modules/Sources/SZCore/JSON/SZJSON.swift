// SPDX-License-Identifier: AGPL-3.0-only
// The one canonical encoder for every on-disk JSON artifact (project.json, node contracts,
// app-state.json, transcript sidecars, agent-sessions.json): pretty-printed, key-sorted,
// slash-friendly — human-diffable and byte-stable across saves. Default Date strategy (seconds
// since the 2001 reference date) is deliberate and shared; changing any of this here changes EVERY
// writer at once, which is the point — the formats must not drift apart per file.
import Foundation

public enum SZJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}
