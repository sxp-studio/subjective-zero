// SPDX-License-Identifier: AGPL-3.0-only
// ChatGPT plan credentials drive a private Codex app-server, independent of CLI login.
import Foundation
import Synchronization
import SZCore

public final class SZChatGPTProvider: SZProvider, Sendable {
    public static let providerID = "chatgpt"
    public let id = providerID
    public let displayName = "ChatGPT"
    public let defaultReasoningEffort = ""
    public let supportedReasoningEfforts: [String] = []
    public let supportsFastMode = false
    public let healthArgs: [String] = []
    public let installCommand = ""
    public let loginCommand = ""
    private let catalog = Mutex<SZProviderModelCatalog?>(nil)
    public var models: [SZProviderModel] { catalog.withLock { $0?.models ?? [] } }
    public var defaultModel: String { catalog.withLock { $0?.defaultModelID ?? "" } }
    public let accounts: SZChatGPTAccounts
    public let engine: SZChatGPTEngine
    private let session: URLSession
    private let threadsDirectory: URL

    public init(accounts: SZChatGPTAccounts = .shared, engine: SZChatGPTEngine = .shared,
                session: URLSession = .shared,
                threadsDirectory: URL = SZAppSupport.directory.appending(path: "ChatGPT/threads")) {
        self.accounts = accounts
        self.engine = engine
        self.session = session
        self.threadsDirectory = threadsDirectory
    }

    // account-specific catalogs are fetched after account selection, never seeded across accounts.
    public func clearCatalog() { catalog.withLock { $0 = nil } }

    public func healthReport(runner: any SZProcessRunning) async -> SZProviderHealthReport {
        do {
            let selected = try await accounts.activeAccountID()
            let account = try await accounts.accounts().first { $0.id == selected }
            guard await engine.installed else {
                return SZProviderHealthReport(providerID: id, status: .authNeeded,
                    message: "Use your ChatGPT Plus or Pro plan. Setup downloads the engine from OpenAI; no Terminal or API key needed.")
            }
            guard let account, account.connected else {
                return SZProviderHealthReport(providerID: id, status: .authNeeded,
                    message: "Continue with ChatGPT to connect your plan.")
            }
            guard account.usesPlan else {
                return SZProviderHealthReport(providerID: id, status: .authNeeded,
                    message: "Connected as \(account.label). Enable ChatGPT plan usage to run agents.")
            }
            return SZProviderHealthReport(providerID: id, status: .ready,
                message: "Using ChatGPT plan · \(account.label)")
        } catch {
            return SZProviderHealthReport(providerID: id, status: .healthFailed, message: error.localizedDescription)
        }
    }

    public func refreshModelCatalog(runner: any SZProcessRunning) async throws -> SZProviderModelCatalog? {
        guard let accountID = try await accounts.activeAccountID() else { throw SZChatGPTError("Connect a ChatGPT account first.") }
        let token = try await accounts.accessToken(for: accountID)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.timeoutInterval = 30
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SZChatGPTHTTPError(data: data, response: response) }
        guard let snapshot = Self.catalogSnapshot(data) else {
            throw SZChatGPTError("No ChatGPT models are available for this account.")
        }
        guard try await accounts.activeAccountID() == accountID else { throw CancellationError() }
        catalog.withLock { $0 = snapshot }
        return snapshot
    }

    static func catalogSnapshot(_ data: Data) -> SZProviderModelCatalog? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["models"] as? [[String: Any]] else { return nil }
        let models = rows.filter { $0["visibility"] as? String == "list" }.compactMap { row -> SZProviderModel? in
            guard let id = row["slug"] as? String, !id.isEmpty else { return nil }
            let efforts = (row["supported_reasoning_levels"] as? [[String: Any]] ?? [])
                .compactMap { $0["effort"] as? String }.filter { $0 != "none" }
            let defaultEffort = (row["default_reasoning_level"] as? String).flatMap { efforts.contains($0) ? $0 : nil }
            return SZProviderModel(id: id, displayName: row["display_name"] as? String ?? id,
                supportedReasoningEfforts: efforts, defaultReasoningEffort: defaultEffort, supportsFastMode: false)
        }
        guard !models.isEmpty else { return nil }
        return SZProviderModelCatalog(models: models, defaultModelID: models.first?.id)
    }

    public func run(_ request: SZAgentRunRequest, runner: any SZProcessRunning) async throws -> SZAgentRunResult {
        guard await engine.installed else { throw SZChatGPTError("Complete ChatGPT setup in Settings first.") }
        guard let accountID = try await accounts.activeAccountID() else { throw SZChatGPTError("Continue with ChatGPT in Settings first.") }
        let token = try await accounts.accessToken(for: accountID)
        var resolved = request
        if resolved.model == nil || resolved.model?.isEmpty == true {
            if models.isEmpty { _ = try await refreshModelCatalog(runner: runner) }
            resolved.model = defaultModel
        }
        let executable = await engine.executable
        return try await SZChatGPTAppServer().run(resolved, executable: executable, accessToken: token,
                                                 accountID: accountID, directory: threadsDirectory)
    }

    public func makeStreamConsumer() -> any SZAgentStreamConsumer { SZChatGPTStreamConsumer() }
}
