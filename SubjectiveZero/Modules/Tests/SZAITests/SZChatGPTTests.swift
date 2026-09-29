// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import Security
import CryptoKit
import Synchronization
@testable import SZAI

@Suite(.serialized)
struct SZChatGPTTests {
    @Test func defaultRunnerDispatchesToDirectProvider() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider: any SZProvider = SZChatGPTProvider(
            accounts: SZChatGPTAccounts(directory: directory, useKeychain: false),
            engine: SZChatGPTEngine(directory: directory.appending(path: "engine")))
        let health = await provider.healthReport()
        #expect(health.status == .authNeeded)
        #expect(!health.message.contains("No health check"))
        do {
            _ = try await provider.run(SZAgentRunRequest(prompt: "OK", workingDirectory: directory, cacheDirectory: directory))
            Issue.record("an uninstalled engine cannot run")
        } catch { #expect(error.localizedDescription.contains("Complete ChatGPT setup")) }
    }

    @Test func modelsComeOnlyFromAccountCatalog() throws {
        let data = Data(#"{"models":[{"slug":"account-model","display_name":"Account Model","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}],"default_reasoning_level":"high","additional_speed_tiers":["fast"]},{"slug":"hidden","visibility":"hide"}]}"#.utf8)
        let catalog = try #require(SZChatGPTProvider.catalogSnapshot(data))
        #expect(catalog.models.map(\.id) == ["account-model"])
        #expect(catalog.models.first?.displayName == "Account Model")
        #expect(catalog.defaultModelID == "account-model")
        #expect(catalog.models.first?.defaultReasoningEffort == "high")
        #expect(catalog.models.first?.supportsFastMode == true)
        let standard = try #require(SZChatGPTProvider.catalogSnapshot(Data(#"{"models":[{"slug":"standard","visibility":"list","additional_speed_tiers":[]}]}"#.utf8)))
        #expect(standard.models.first?.supportsFastMode == false)
    }

    @Test func registrationUsesPKCEAndReauthorizationPreservesClient() throws {
        let callback = URL(string: "http://127.0.0.1:15432/auth/callback")!
        let first = try SZChatGPTOAuth.Attempt(redirect: callback, clientID: nil)
        let url = first.authorizationURL(hostID: "urn:uuid:test", idTokenHint: nil, requestConsent: false)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(.init(name: "client_id", value: "dynamic_agent_client")))
        #expect(query.contains(.init(name: "agent_name_hint", value: "SubjectiveZero")))
        #expect(query.contains(.init(name: "code_challenge", value: Data(SHA256.hash(data: Data(first.verifier.utf8))).base64URL)))
        let returned = try first.callback(URL(string: callback.absoluteString + "?state=\(first.state)&code=code&client_id=oaiapp_test")!)
        #expect(returned.clientID == "oaiapp_test")
        let again = try SZChatGPTOAuth.Attempt(redirect: callback, clientID: returned.clientID)
        let next = again.authorizationURL(hostID: "urn:uuid:test", idTokenHint: "hint", requestConsent: false)
        #expect(!next.absoluteString.contains("agent_name_hint"))
        #expect(again.state != first.state)
        #expect(again.nonce != first.nonce)
        #expect(again.verifier != first.verifier)
        #expect(try again.callback(URL(string: callback.absoluteString + "?state=\(again.state)&code=next")!).clientID == returned.clientID)
        #expect(throws: SZChatGPTError.self) {
            try again.callback(URL(string: callback.absoluteString + "?state=\(again.state)&code=next&client_id=oaiapp_wrong")!)
        }
    }

    @Test func rejectsUntrustedCallbacks() throws {
        let redirect = URL(string: "http://127.0.0.1:12345/auth/callback")!
        let attempt = try SZChatGPTOAuth.Attempt(redirect: redirect, clientID: nil)
        for query in ["state=wrong&code=c&client_id=oaiapp_x", "state=\(attempt.state)&error=access_denied",
                      "state=\(attempt.state)&code=c", "state=\(attempt.state)&code=c&client_id=dynamic_agent_client",
                      "state=\(attempt.state)&state=\(attempt.state)&code=c&client_id=oaiapp_x"] {
            #expect(throws: SZChatGPTError.self) { try attempt.callback(URL(string: redirect.absoluteString + "?" + query)!) }
        }
        let valid = URL(string: redirect.absoluteString + "?state=\(attempt.state)&code=c&client_id=oaiapp_x")!
        #expect(throws: SZChatGPTError.self) { try attempt.callback(valid, now: attempt.createdAt.addingTimeInterval(601)) }
        #expect(throws: SZChatGPTError.self) { try attempt.callback(URL(string: valid.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost"))!) }
    }

    @Test func verifiesIdentitySignatureAndClaims() throws {
        let privateKey = try #require(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var cursor = 0
        func tlv() -> Data {
            cursor += 1
            var count = Int(der[cursor]); cursor += 1
            if count >= 128 {
                let bytes = count & 127; count = 0
                for _ in 0..<bytes { count = (count << 8) | Int(der[cursor]); cursor += 1 }
            }
            let result = der[cursor..<cursor+count]; cursor += count; return result
        }
        _ = tlv(); cursor = der.count > 255 ? 4 : 3
        let n = Data(tlv().drop(while: { $0 == 0 })); let e = Data(tlv())
        let keys = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "test", "kty": "RSA", "n": n.base64URL, "e": e.base64URL]]])
        let now = Date()
        let claims: [String: Any] = ["iss": SZChatGPTOAuth.issuer, "aud": "oaiapp_test", "sub": "person",
            "nonce": "nonce", "iat": now.timeIntervalSince1970, "exp": now.addingTimeInterval(60).timeIntervalSince1970]
        func token(_ claims: [String: Any]) throws -> String {
            let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test"]).base64URL
            let body = try JSONSerialization.data(withJSONObject: claims).base64URL
            let signed = header + "." + body
            let signature = try #require(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(signed.utf8) as CFData, nil)) as Data
            return signed + "." + signature.base64URL
        }
        let jwt = try token(claims)
        #expect(try SZChatGPTOAuth.verifyIDToken(jwt, clientID: "oaiapp_test", nonce: "nonce", keys: keys).subject == "person")
        for (key, value) in [("iss", "https://other.example"), ("aud", "oaiapp_other"), ("nonce", "wrong"), ("sub", "")] {
            var invalid = claims; invalid[key] = value
            let jwt = try token(invalid)
            #expect(throws: SZChatGPTError.self) { try SZChatGPTOAuth.verifyIDToken(jwt, clientID: "oaiapp_test", nonce: "nonce", keys: keys) }
        }
        #expect(throws: SZChatGPTError.self) { try SZChatGPTOAuth.verifyIDToken(jwt, clientID: "oaiapp_test", nonce: "nonce", keys: keys, now: now.addingTimeInterval(120)) }
        var parts = jwt.split(separator: ".").map(String.init)
        var tampered = claims; tampered["sub"] = "attacker"
        parts[1] = try JSONSerialization.data(withJSONObject: tampered).base64URL
        #expect(throws: SZChatGPTError.self) { try SZChatGPTOAuth.verifyIDToken(parts.joined(separator: "."), clientID: "oaiapp_test", nonce: "nonce", keys: keys) }
    }

    @Test func hostIDPersistsAndCredentialsStayPrivate() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = SZChatGPTAccounts(directory: root, useKeychain: false)
        #expect(try await accounts.accounts().isEmpty)
        let file = root.appending(path: "accounts.json")
        let first = try JSONDecoder().decode(SZChatGPTAccounts.Database.self, from: Data(contentsOf: file))
        #expect(first.hostID.hasPrefix("urn:uuid:"))
        _ = try await SZChatGPTAccounts(directory: root, useKeychain: false).accounts()
        let second = try JSONDecoder().decode(SZChatGPTAccounts.Database.self, from: Data(contentsOf: file))
        #expect(first.hostID == second.hostID)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int == 0o700)
    }

    @Test func concurrentTurnsShareOneTokenRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = SZChatGPTAccounts.Profile(id: "account", clientID: "oaiapp_test")
        profile.subject = "person"; profile.accessToken = "expired"; profile.refreshToken = "refresh"
        profile.scopes = ["chatgpt.tokens.use.direct"]; profile.expiresAt = Date(timeIntervalSince1970: 0)
        let db = SZChatGPTAccounts.Database(activeID: "account", profiles: [profile])
        try JSONEncoder().encode(db).write(to: root.appending(path: "accounts.json"))
        let count = Mutex(0)
        SZChatGPTTestHTTP.handler.withLock { $0 = { _ in
            count.withLock { $0 += 1 }
            return (200, Data(#"{"access_token":"fresh","refresh_token":"rotated","expires_in":3600}"#.utf8))
        } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SZChatGPTTestHTTP.self]
        let accounts = SZChatGPTAccounts(directory: root, session: URLSession(configuration: config), useKeychain: false)
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await accounts.accessToken(for: "account") } }
            for try await token in group { #expect(token == "fresh") }
        }
        #expect(count.withLock { $0 } == 1)
        let saved = try JSONDecoder().decode(SZChatGPTAccounts.Database.self, from: Data(contentsOf: root.appending(path: "accounts.json")))
        #expect(saved.profiles[0].refreshToken == "rotated")
    }

    @Test func longTurnsRenewNearExpiryAndRejectInsufficientLifetime() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = SZChatGPTAccounts.Profile(id: "account", clientID: "oaiapp_test")
        profile.accessToken = "three-minutes-left"; profile.refreshToken = "refresh"
        profile.scopes = ["chatgpt.tokens.use.direct"]; profile.expiresAt = Date().addingTimeInterval(180)
        try JSONEncoder().encode(SZChatGPTAccounts.Database(activeID: profile.id, profiles: [profile]))
            .write(to: root.appending(path: "accounts.json"))
        let lifetimes = Mutex([3600, 60])
        SZChatGPTTestHTTP.handler.withLock { $0 = { _ in
            let lifetime = lifetimes.withLock { $0.removeFirst() }
            return (200, Data("{\"access_token\":\"renewed\",\"refresh_token\":\"rotated\",\"expires_in\":\(lifetime)}".utf8))
        } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SZChatGPTTestHTTP.self]
        let accounts = SZChatGPTAccounts(directory: root, session: URLSession(configuration: config), useKeychain: false)
        #expect(try await accounts.accessToken(for: profile.id) == "three-minutes-left")
        #expect(try await accounts.accessToken(for: profile.id,
            minimumValidity: SZChatGPTAppServer.defaultTimeout + 120) == "renewed")
        await #expect(throws: SZChatGPTError.self) {
            try await accounts.accessToken(for: profile.id, minimumValidity: 4000)
        }
        #expect(lifetimes.withLock { $0.isEmpty })
    }

    @Test func duplicateEmailsHaveDistinctStableRegistrationLabels() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var first = SZChatGPTAccounts.Profile(id: "shared-first", clientID: "oaiapp_one")
        var second = SZChatGPTAccounts.Profile(id: "shared-second", clientID: "oaiapp_two")
        var third = SZChatGPTAccounts.Profile(id: "unique", clientID: "oaiapp_three")
        first.email = "same@example.com"; second.email = first.email; third.email = "other@example.com"
        try JSONEncoder().encode(SZChatGPTAccounts.Database(profiles: [first, second, third]))
            .write(to: root.appending(path: "accounts.json"))
        let accounts = SZChatGPTAccounts(directory: root, useKeychain: false)
        let before = try await accounts.accounts()
        #expect(Set(before.map(\.label)).count == 3)
        #expect(before[0].label.hasPrefix("same@example.com · "))
        #expect(before[2].label == "other@example.com")
        try await accounts.select(second.id)
        #expect(try await accounts.accounts().map(\.label) == before.map(\.label))
    }

    @Test func accountSwitchDiscardsPendingCatalogEvenAfterSwitchingBack() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var first = SZChatGPTAccounts.Profile(id: "first", clientID: "oaiapp_one")
        first.accessToken = "test-token"; first.scopes = ["chatgpt.tokens.use.direct"]
        first.expiresAt = Date().addingTimeInterval(3600)
        let second = SZChatGPTAccounts.Profile(id: "second", clientID: "oaiapp_two")
        try JSONEncoder().encode(SZChatGPTAccounts.Database(activeID: first.id, profiles: [first, second]))
            .write(to: root.appending(path: "accounts.json"))
        let started = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        SZChatGPTTestHTTP.handler.withLock { $0 = { _ in
            started.withLock { $0 = true }
            _ = release.wait(timeout: .now() + 5)
            return (200, Data(#"{"models":[{"slug":"stale","visibility":"list"}]}"#.utf8))
        } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SZChatGPTTestHTTP.self]
        let session = URLSession(configuration: config)
        let accounts = SZChatGPTAccounts(directory: root, session: session, useKeychain: false)
        let provider = SZChatGPTProvider(accounts: accounts, session: session)
        let task = Task { try await provider.refreshModelCatalog(runner: SZSystemProcessRunner()) }
        let deadline = Date().addingTimeInterval(3)
        while !started.withLock({ $0 }), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(started.withLock { $0 })
        try await accounts.select(second.id); provider.clearCatalog()
        try await accounts.select(first.id); provider.clearCatalog()
        release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(provider.models.isEmpty)
    }

    @Test func archiveMismatchNeverRunsAnUnverifiedEngine() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("tampered".utf8).write(to: file)
        #expect(throws: SZChatGPTError.self) { try SZChatGPTEngine.verifyArchive(at: file, digest: String(repeating: "0", count: 64)) }
    }

    @Test(arguments: [false, true]) @MainActor
    func transportRequiresCompletedTurnAndResumesSavedThread(fast: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appending(path: "server")
        let source = #"""
        #!/usr/bin/python3
        import sys,json,os
        assert ('service_tier="fast"' in sys.argv) != ('service_tier="default"' in sys.argv)
        with open('tier.json','w') as f: json.dump('fast' if 'service_tier="fast"' in sys.argv else 'default',f)
        for line in sys.stdin:
            message=json.loads(line)
            method=message.get('method')
            if method=='initialize':
                assert message['params']['clientInfo']['name']=='SubjectiveZero'
                print(json.dumps({'id':1,'result':{}}),flush=True)
            elif method=='thread/resume':
                assert message['params']['threadId']=='saved-thread'
                print(json.dumps({'id':2,'result':{'thread':{'id':'saved-thread'}}}),flush=True)
            elif method=='turn/start':
                assert message['params']['effort']=='high'
                print(json.dumps({'id':3,'result':{'turn':{'id':'turn'}}}),flush=True)
                print(json.dumps({'method':'item/completed','params':{'item':{'type':'agentMessage','text':'partial '+os.environ['SZ_CHATGPT_ACCESS_TOKEN']}}}),flush=True)
                print(json.dumps({'method':'turn/completed','params':{'turn':{'status':'failed','error':{'message':'usage limit'}}}}),flush=True)
        """#
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let request = SZAgentRunRequest(prompt: "hello", workingDirectory: root, cacheDirectory: root,
                                        resumeSessionID: "account/saved-thread", reasoningEffort: "high", fastMode: fast, timeout: 10)
        let result = try await SZChatGPTAppServer().run(request, executable: script, accessToken: "secret-sentinel",
                                                       accountID: "account", directory: root.appending(path: "threads"))
        #expect(try JSONDecoder().decode(String.self, from: Data(contentsOf: root.appending(path: "tier.json"))) == (fast ? "fast" : "default"))
        #expect(result.outcome.failed)
        #expect(result.outcome.sessionID == "account/saved-thread")
        #expect(result.outcome.message == "usage limit")
        #expect(!result.process.output.contains("secret-sentinel"))
        #expect(result.process.output.contains("[redacted]"))
        await #expect(throws: SZChatGPTError.self) {
            try await SZChatGPTAppServer().run(request, executable: script, accessToken: "secret",
                                               accountID: "other", directory: root)
        }
    }
}

private final class SZChatGPTTestHTTP: URLProtocol, @unchecked Sendable {
    static let handler = Mutex<(@Sendable (URLRequest) -> (Int, Data))?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.handler.withLock { $0 }!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
