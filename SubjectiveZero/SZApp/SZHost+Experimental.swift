// SPDX-License-Identifier: AGPL-3.0-only
// Settings ▸ Experimental: the Jev switch, its key, and the key check. With Jev on and a key
// saved, the query services hand declared decisions (message sorting) to Jev first.
import Foundation
import SZAI
import SZCore
import SZUI

extension SZHost {
    /// The decider every query service gets; nil = Jev off or no key, every ask is a completion.
    var queryDecider: SZQueryDecider? {
        guard jevEnabled, let key = SZKeychain.jev.read(), !key.isEmpty else { return nil }
        return SZJevClient(key: key).decider()
    }

    func setJevEnabled(_ on: Bool) {
        jevEnabled = on && jevKeyHint != nil
        persistAppState()
    }

    /// Saves the key and checks it right away.
    func saveJevKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard SZKeychain.jev.write(trimmed) else {
            jevCheck = .problem(label: "Could not save", detail: "The Keychain refused to store the key.")
            return
        }
        jevKeyHint = Self.maskedKey(trimmed)
        verifyJevKey()
    }

    func removeJevKey() {
        SZKeychain.jev.delete()
        jevKeyHint = nil
        jevCheck = .idle
        setJevEnabled(false)
    }

    func verifyJevKey() {
        guard let key = SZKeychain.jev.read() else { return }
        jevCheck = .checking
        Task { @MainActor in
            do {
                try await SZJevClient(key: key).verify()
                jevCheck = .verified
            } catch SZJevError.noBalance {
                jevCheck = .problem(label: "No balance", detail: "The key works, but its balance is empty. Add tokens at console.typesafe.ai.")
            } catch SZJevError.keyRejected {
                jevCheck = .problem(label: "Key not recognized", detail: "Jev did not accept this key. Check it at console.typesafe.ai.")
            } catch SZJevError.rateLimited {
                jevCheck = .problem(label: "Too many requests", detail: "Jev is limiting this key right now. Try again in a minute.")
            } catch {
                jevCheck = .problem(label: "Check failed", detail: String(describing: error))
            }
        }
    }

    /// "jv_live_…a1b2": enough to tell keys apart, never the secret.
    nonisolated static func maskedKey(_ key: String) -> String {
        let prefix = key.hasPrefix("jv_live_") ? "jv_live_" : ""
        return prefix + "…" + key.suffix(4)
    }
}
