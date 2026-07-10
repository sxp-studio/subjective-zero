// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

// Wire layer for the Jellystat reporting endpoint. The vendor name stays confined
// to this file — the app talks to SZTelemetry (SZTelemetry.swift).

struct SZJellystatConfig: Sendable {
    var apiKey: String

    static func load(bundle: Bundle = .main) -> SZJellystatConfig? {
        guard let url = bundle.url(forResource: "JellystatConfig", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(SZJellystatConfigFile.self, from: data) else {
            return nil
        }
        let apiKey = file.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return nil }
        return SZJellystatConfig(apiKey: apiKey)
    }
}

private struct SZJellystatConfigFile: Decodable {
    var apiKey: String

    private enum CodingKeys: String, CodingKey {
        case apiKey
        case api_key
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
            ?? container.decodeIfPresent(String.self, forKey: .api_key)
            ?? ""
        self.apiKey = apiKey
    }
}

enum SZJellystatReportValue: Encodable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        }
    }
}

struct SZJellystatPayload: Encodable, Sendable {
    var apiKey: String
    var installUID: String
    var report: [String: SZJellystatReportValue]

    private enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case installUID = "install_uid"
        case report
    }
}

enum SZJellystatClient {
    static let endpoint = URL(string: "https://jellystat.com/new-report")!

    static func post(_ payload: SZJellystatPayload) {
        Task.detached(priority: .utility) {
            do {
                var request = URLRequest(url: endpoint)
                request.timeoutInterval = 10
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(payload)
                _ = try await URLSession.shared.data(for: request)
            } catch {
                // Telemetry failures should never affect the creative runtime.
            }
        }
    }

    static var debugLogEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
