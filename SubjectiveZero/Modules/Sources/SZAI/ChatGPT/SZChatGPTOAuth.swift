// SPDX-License-Identifier: AGPL-3.0-only
// public-client OAuth and verified OpenID identity for ChatGPT plan usage.
import Foundation
import CryptoKit
import Security

public struct SZChatGPTError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

struct SZChatGPTOAuth {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let appName = "SubjectiveZero"

    struct Attempt: Sendable {
        let state: String
        let nonce: String
        let verifier: String
        let redirect: URL
        let clientID: String?
        let createdAt: Date

        init(redirect: URL, clientID: String?) throws {
            state = try SZChatGPTOAuth.random()
            nonce = try SZChatGPTOAuth.random()
            verifier = try SZChatGPTOAuth.random()
            self.redirect = redirect
            self.clientID = clientID
            createdAt = Date()
        }

        func authorizationURL(hostID: String, idTokenHint: String?, requestConsent: Bool) -> URL {
            var values = ["client_id": clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
                          "response_type": "code", "redirect_uri": redirect.absoluteString,
                          "scope": SZChatGPTOAuth.scopes, "resource": SZChatGPTOAuth.resource,
                          "state": state, "nonce": nonce, "code_challenge_method": "S256",
                          "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL]
            if clientID == nil { values["agent_name_hint"] = SZChatGPTOAuth.appName }
            if let idTokenHint { values["id_token_hint"] = idTokenHint }
            if requestConsent { values["prompt"] = "consent" }
            var url = URLComponents(string: SZChatGPTOAuth.issuer + "/api/accounts/authorize")!
            url.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            return url.url!
        }

        func callback(_ url: URL, now: Date = Date()) throws -> (code: String, clientID: String) {
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let items = parts?.queryItems ?? []
            guard now.timeIntervalSince(createdAt) < 600,
                  url.scheme == redirect.scheme, url.host == redirect.host,
                  url.port == redirect.port, url.path == redirect.path,
                  Set(items.map(\.name)).count == items.count,
                  items.first(where: { $0.name == "state" })?.value == state else {
                throw SZChatGPTError("Sign-in could not be verified. Please try again.")
            }
            if items.contains(where: { $0.name == "error" }) {
                throw SZChatGPTError("ChatGPT sign-in was declined or cancelled.")
            }
            let returnedID = items.first(where: { $0.name == "client_id" })?.value
            guard let issued = returnedID ?? clientID, issued != "dynamic_agent_client", !issued.isEmpty,
                  clientID == nil || clientID == issued,
                  let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                throw SZChatGPTError("ChatGPT did not return a valid registration. Please try again.")
            }
            return (code, issued)
        }
    }

    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SZChatGPTError("Could not prepare secure sign-in.")
        }
        return Data(bytes).base64URL
    }

    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" +
            $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }

    struct Identity: Sendable, Equatable { let subject: String; let email: String; let name: String }

    static func verifyIDToken(_ token: String, clientID: String, nonce: String,
                              keys: Data, now: Date = Date()) throws -> Identity {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3, let headerData = Data(base64URL: parts[0]),
              let claimsData = Data(base64URL: parts[1]), let signature = Data(base64URL: parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let jwks = try JSONSerialization.jsonObject(with: keys) as? [String: Any],
              let key = (jwks["keys"] as? [[String: Any]])?.first(where: { $0["kid"] as? String == kid }),
              key["kty"] as? String == "RSA", key["use"] as? String ?? "sig" == "sig",
              let n = key["n"] as? String, let e = key["e"] as? String,
              let modulus = Data(base64URL: n), let exponent = Data(base64URL: e) else {
            throw SZChatGPTError("ChatGPT identity signature could not be verified.")
        }
        let der = asn1(0x30, integer(modulus) + integer(exponent))
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                           kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let publicKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data((parts[0] + "." + parts[1]).utf8) as CFData,
                                    signature as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any] else {
            throw SZChatGPTError("ChatGPT identity signature could not be verified.")
        }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard claims["iss"] as? String == issuer, audiences.contains(clientID),
              audiences.count == 1 || claims["azp"] as? String == clientID,
              let exp = claims["exp"] as? Double, exp > now.timeIntervalSince1970 - 5,
              let iat = claims["iat"] as? Double, iat <= now.timeIntervalSince1970 + 5,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 5,
              claims["nonce"] as? String == nonce,
              let sub = claims["sub"] as? String, !sub.isEmpty else {
            throw SZChatGPTError("ChatGPT returned an unexpected or expired identity. Please sign in again.")
        }
        return Identity(subject: sub, email: claims["email"] as? String ?? "",
                        name: claims["name"] as? String ?? "")
    }

    private static func integer(_ data: Data) -> Data {
        var value = Data(data.drop(while: { $0 == 0 }))
        if value.first.map({ $0 >= 0x80 }) ?? true { value.insert(0, at: 0) }
        return asn1(0x02, value)
    }

    private static func asn1(_ tag: UInt8, _ data: Data) -> Data {
        var count = data.count
        var length = Data()
        if count < 128 { length.append(UInt8(count)) } else {
            while count > 0 { length.insert(UInt8(count & 255), at: 0); count >>= 8 }
            length.insert(0x80 | UInt8(length.count), at: 0)
        }
        return Data([tag]) + length + data
    }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL: String) {
        let value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
}
