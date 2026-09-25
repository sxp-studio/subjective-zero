// SPDX-License-Identifier: AGPL-3.0-only
// A secret the user typed into Settings, kept in the login Keychain as one generic password
// per service. Test processes get their own service name, so a test never reads or overwrites
// the user's real key.
import Foundation
import Security
import SZCore

struct SZKeychain: Sendable {
    let service: String
    let account: String

    /// The Jev API key (Settings ▸ Experimental).
    static let jev = SZKeychain(service: "studio.sxp.SubjectiveZero.jev" + (SZAppSupport.isTestProcess ? ".tests" : ""),
                                account: "api-key")

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() -> String? {
        var item: CFTypeRef?
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces any saved value. Returns false when the Keychain refused.
    @discardableResult
    func write(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
