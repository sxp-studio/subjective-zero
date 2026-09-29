// SPDX-License-Identifier: AGPL-3.0-only
// local ChatGPT registrations, protected credentials, and serialized token renewal.
import Foundation
import SZCore
import Security
import CryptoKit

public struct SZChatGPTAccount: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let connected: Bool
    public let usesPlan: Bool
}

public actor SZChatGPTAccounts {
    public static let shared = SZChatGPTAccounts(directory: SZAppSupport.directory.appending(path: "ChatGPT"),
        useKeychain: usesKeychain)
    private static var usesKeychain: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SZ_CHATGPT_TEST_FILE_CREDENTIALS"] == "1" { return false }
        #endif
        return !SZAppSupport.directory.lastPathComponent.hasPrefix("SubjectiveZero-tests-")
    }
    public static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    private let directory: URL
    private let session: URLSession
    private let useKeychain: Bool
    private var signingIn = false
    private var refreshes: [String: Task<String, Error>] = [:]

    struct Profile: Codable, Sendable {
        var id: String
        var clientID: String
        var subject = ""
        var email = ""
        var name = ""
        var accessToken: String?
        var refreshToken: String?
        var idToken: String?
        var scopes: [String] = []
        var expiresAt: Date?
        var welcomed = false
        var usesPlan: Bool { accessToken != nil && scopes.contains("chatgpt.tokens.use.direct") }
    }
    struct Database: Codable {
        var hostID = "urn:uuid:" + UUID().uuidString.lowercased()
        var activeID: String?
        var profiles: [Profile] = []
    }
    struct Tokens: Decodable {
        var access_token: String?
        var refresh_token: String?
        var id_token: String?
        var expires_in: Double?
        var scope: String?
    }

    public init(directory: URL, session: URLSession = .shared, useKeychain: Bool = true) {
        self.directory = directory
        self.session = session
        self.useKeychain = useKeychain
    }

    private func load() throws -> Database {
        let value: Database
        if useKeychain {
            var query = keychainQuery
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { value = Database(); try save(value) }
            else if status == errSecSuccess, let data = item as? Data { value = try JSONDecoder().decode(Database.self, from: data) }
            else { throw SZChatGPTError("Could not read the ChatGPT connection from macOS Keychain (\(status)).") }
        } else {
            let url = directory.appending(path: "accounts.json")
            if FileManager.default.fileExists(atPath: url.path) {
                value = try JSONDecoder().decode(Database.self, from: Data(contentsOf: url))
            } else { value = Database(); try save(value) }
        }
        return value
    }

    private var keychainQuery: [CFString: Any] {
        let name = Data(SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))).base64URL
        return [kSecClass: kSecClassGenericPassword, kSecAttrService: "studio.sxp.SubjectiveZero.ChatGPT", kSecAttrAccount: name]
    }

    private func save(_ value: Database) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(value)
        if useKeychain {
            let status = SecItemUpdate(keychainQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
            if status == errSecItemNotFound {
                var query = keychainQuery
                query[kSecValueData] = data
                query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                let added = SecItemAdd(query as CFDictionary, nil)
                guard added == errSecSuccess else { throw SZChatGPTError("Could not save the ChatGPT connection in macOS Keychain (\(added)).") }
            } else if status != errSecSuccess { throw SZChatGPTError("Could not update the ChatGPT connection in macOS Keychain (\(status)).") }
            return
        }
        let url = directory.appending(path: "accounts.json")
        let temporary = directory.appending(path: ".accounts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                              attributes: [.posixPermissions: 0o600]) else {
            throw SZChatGPTError("Could not save the ChatGPT connection.")
        }
        guard rename(temporary.path, url.path) == 0 else { throw SZChatGPTError("Could not save the ChatGPT connection.") }
    }

    public func accounts() throws -> [SZChatGPTAccount] {
        try load().profiles.map {
            SZChatGPTAccount(id: $0.id,
                label: ($0.email.isEmpty ? ($0.name.isEmpty ? "ChatGPT account" : $0.name) : $0.email), connected: $0.accessToken != nil, usesPlan: $0.usesPlan)
        }
    }

    public func activeAccountID() throws -> String? { try load().activeID }

    public func select(_ id: String) throws {
        var db = try load()
        guard db.profiles.contains(where: { $0.id == id }) else { throw SZChatGPTError("Choose a saved ChatGPT account.") }
        db.activeID = id
        try save(db)
    }

    public func needsWelcome() throws -> Bool {
        let db = try load()
        return db.profiles.first(where: { $0.id == db.activeID }).map { $0.usesPlan && !$0.welcomed } ?? false
    }

    public func acknowledgeWelcome() throws {
        var db = try load()
        guard let index = db.profiles.firstIndex(where: { $0.id == db.activeID }) else { return }
        db.profiles[index].welcomed = true
        try save(db)
    }

    public func signIn(profileID: String? = nil,
                       openBrowser: @escaping @Sendable (URL) async -> Bool) async throws {
        guard !signingIn else { throw SZChatGPTError("A ChatGPT sign-in is already in progress.") }
        signingIn = true
        defer { signingIn = false }
        let db = try load()
        let previous = db.profiles.first { $0.id == profileID }
        let listener = try await SZChatGPTCallback()
        await listener.start()
        do {
            let (attempt, callback) = try await withThrowingTaskGroup(of: (SZChatGPTOAuth.Attempt, URL).self) { group in
                group.addTask {
                    var attempt: SZChatGPTOAuth.Attempt?
                    for try await event in listener.events {
                        switch event {
                        case .ready(let redirect):
                            let next = try SZChatGPTOAuth.Attempt(redirect: redirect, clientID: previous?.clientID)
                            attempt = next
                            guard await openBrowser(next.authorizationURL(hostID: db.hostID,
                                idTokenHint: previous?.idToken, requestConsent: previous?.accessToken != nil && previous?.usesPlan == false)) else {
                                throw SZChatGPTError("Could not open the browser for ChatGPT sign-in.")
                            }
                        case .callback(let url):
                            guard let attempt else { continue }
                            return (attempt, url)
                        }
                    }
                    throw CancellationError()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(600))
                    throw SZChatGPTError("ChatGPT sign-in timed out. Please try again.")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            let returned = try attempt.callback(callback)
            var current = try load()
            let id = previous?.id ?? UUID().uuidString
            // preserve a newly issued registration even if its authorization code expires.
            if previous == nil {
                current.profiles.append(Profile(id: id, clientID: returned.clientID))
                try save(current)
            }
            let tokens = try await tokenRequest(["grant_type": "authorization_code", "client_id": returned.clientID,
                "code": returned.code, "code_verifier": attempt.verifier,
                "redirect_uri": attempt.redirect.absoluteString, "resource": SZChatGPTOAuth.resource])
            guard let idToken = tokens.id_token else { throw SZChatGPTError("ChatGPT did not return a verified identity.") }
            let (keys, response) = try await session.data(from: URL(string: SZChatGPTOAuth.issuer + "/.well-known/jwks.json")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SZChatGPTError("Could not verify ChatGPT identity. Try again.") }
            let identity = try SZChatGPTOAuth.verifyIDToken(idToken, clientID: returned.clientID, nonce: attempt.nonce, keys: keys)
            guard previous?.subject.isEmpty != false || previous?.subject == identity.subject else {
                throw SZChatGPTError("This sign-in belongs to a different account. Use Add account instead.")
            }
            try Task.checkCancellation()
            current = try load()
            guard let index = current.profiles.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
            current.profiles[index].subject = identity.subject
            current.profiles[index].email = identity.email
            current.profiles[index].name = identity.name
            apply(tokens, to: &current.profiles[index])
            current.activeID = id
            try save(current)
            await listener.stop()
        } catch {
            await listener.stop()
            throw error
        }
    }

    public func accessToken(for id: String) async throws -> String {
        let db = try load()
        guard let profile = db.profiles.first(where: { $0.id == id }), profile.usesPlan else {
            throw SZChatGPTError("Continue with ChatGPT and enable ChatGPT plan usage to run an agent.")
        }
        if let token = profile.accessToken, let expiry = profile.expiresAt, expiry.timeIntervalSinceNow > 120 { return token }
        if let task = refreshes[id] { return try await task.value }
        let task = Task { try await self.refresh(profile) }
        refreshes[id] = task
        defer { refreshes[id] = nil }
        return try await task.value
    }

    private func refresh(_ original: Profile) async throws -> String {
        let lock = open(directory.appending(path: "refresh.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw SZChatGPTError("Could not lock the ChatGPT session for renewal.") }
        defer { close(lock) }
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else { throw SZChatGPTError("Could not renew the ChatGPT session.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        defer { flock(lock, LOCK_UN) }
        guard let profile = try load().profiles.first(where: { $0.id == original.id }), profile.usesPlan else {
            throw SZChatGPTError("Please reconnect your ChatGPT account.")
        }
        if let token = profile.accessToken, let expiry = profile.expiresAt, expiry.timeIntervalSinceNow > 120 { return token }
        guard let token = profile.refreshToken else { throw SZChatGPTError("Please reconnect your ChatGPT account.") }
        do {
            let tokens = try await tokenRequest(["grant_type": "refresh_token", "client_id": profile.clientID,
                "refresh_token": token, "resource": SZChatGPTOAuth.resource])
            var db = try load()
            guard let index = db.profiles.firstIndex(where: { $0.id == profile.id }),
                  db.profiles[index].refreshToken == token else { throw CancellationError() }
            guard let access = tokens.access_token, tokens.refresh_token != nil else {
                throw SZChatGPTError("ChatGPT did not renew the connection. Please reconnect.")
            }
            apply(tokens, to: &db.profiles[index])
            try save(db)
            return access
        } catch let error as SZChatGPTHTTPError where error.requiresSignIn {
            try clearTokens(profile.id)
            throw SZChatGPTError("Your ChatGPT session ended. Continue with ChatGPT to reconnect.")
        }
    }

    public func signOut(_ id: String) async throws {
        if let task = refreshes[id] { _ = try? await task.value }
        let db = try load()
        guard let profile = db.profiles.first(where: { $0.id == id }) else { return }
        // stop new requests before revoking the remote renewable session.
        try clearTokens(id)
        guard let refresh = profile.refreshToken else { return }
        do {
            let (data, response) = try await session.data(from: URL(string: SZChatGPTOAuth.issuer + "/.well-known/openid-configuration")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let discovery = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let endpoint = discovery["revocation_endpoint"] as? String, let url = URL(string: endpoint),
                  url.scheme == "https", url.host == "auth.openai.com" else { throw SZChatGPTError("Revocation unavailable.") }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = SZChatGPTOAuth.form(["token": refresh, "token_type_hint": "refresh_token", "client_id": profile.clientID])
            let (_, reply) = try await session.data(for: request)
            guard (reply as? HTTPURLResponse)?.statusCode == 200 else { throw SZChatGPTError("Revocation unavailable.") }
        } catch {
            throw SZChatGPTError("Signed out locally. Remote revocation was not confirmed; disconnect SubjectiveZero in ChatGPT settings.")
        }
    }

    private func clearTokens(_ id: String) throws {
        var db = try load()
        guard let index = db.profiles.firstIndex(where: { $0.id == id }) else { return }
        db.profiles[index].accessToken = nil
        db.profiles[index].refreshToken = nil
        db.profiles[index].idToken = nil
        db.profiles[index].expiresAt = nil
        db.profiles[index].scopes = []
        try save(db)
    }

    private func apply(_ tokens: Tokens, to profile: inout Profile) {
        profile.accessToken = tokens.access_token
        profile.refreshToken = tokens.refresh_token ?? profile.refreshToken
        profile.idToken = tokens.id_token ?? profile.idToken
        if let scope = tokens.scope { profile.scopes = scope.split(separator: " ").map(String.init) }
        profile.expiresAt = tokens.expires_in.map { Date().addingTimeInterval($0) }
    }

    private func tokenRequest(_ values: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: URL(string: SZChatGPTOAuth.issuer + "/api/accounts/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = SZChatGPTOAuth.form(values)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SZChatGPTHTTPError(data: data, response: response)
        }
        return try JSONDecoder().decode(Tokens.self, from: data)
    }
}

struct SZChatGPTHTTPError: LocalizedError, Sendable {
    let status: Int
    let code: String
    let requestID: String?
    init(data: Data, response: URLResponse) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let raw = (object?["error"] as? String) ?? (object?["error"] as? [String: Any])?["code"] as? String ?? ""
        code = raw.range(of: "^[a-z_]{1,100}$", options: .regularExpression) != nil ? raw : ""
        requestID = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-request-id")
    }
    var requiresSignIn: Bool {
        ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated",
         "refresh_token_reused", "refresh_token_invalidated", "refresh_token_invalid"].contains(code)
    }
    var errorDescription: String? {
        if code == "subscription_sharing_usage_limit_exceeded" { return "ChatGPT usage limit reached. Open Manage usage to review your plan or app limit." }
        if code == "subscription_sharing_user_not_eligible" { return "ChatGPT plan usage is unavailable for this account or workspace." }
        return "ChatGPT request failed (HTTP \(status)\(code.isEmpty ? "" : ", " + code)). Please try again or reconnect in Settings."
    }
}
