// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Darwin
import Foundation

// App-level anonymous usage telemetry: app_launch, agent_provider_default, and a
// 15-minute active-only heartbeat, all fire-and-forget over the Jellystat wire
// layer (SZJellystatClient.swift). A missing/empty JellystatConfig.json disables
// telemetry entirely; DEBUG builds print payloads instead of sending.

@MainActor
final class SZTelemetry {
    static let shared = SZTelemetry()

    struct Context {
        var providerID: String
        var providerDisplayName: String
        var modelID: String
        var reasoningEffort: String   // "" when the provider has no effort concept
        var fastMode: Bool
        var nodeCount: Int
    }

    private static let installUIDDefaultsKey = "studio.sxp.subjectivezero.jellystat.installUID"
    private static let heartbeatInterval: TimeInterval = 15 * 60
    private static let heartbeatCheckInterval: TimeInterval = 60

    private let config: SZJellystatConfig?
    private let installUID: String
    private var contextProvider: (() -> Context?)?
    private var startedAt: Date?
    private var lastHeartbeatAt: Date?
    private var heartbeatTimer: Timer?
    private var lastProviderSignature: String?

    init(bundle: Bundle = .main, userDefaults: UserDefaults = .standard) {
        self.config = SZJellystatConfig.load(bundle: bundle)
        self.installUID = Self.installUID(userDefaults: userDefaults)
    }

    func start(contextProvider: @escaping () -> Context?) {
        if startedAt != nil {
            self.contextProvider = contextProvider
            return
        }
        let now = Date()
        startedAt = now
        lastHeartbeatAt = now
        self.contextProvider = contextProvider
        trackLaunch()
        startHeartbeatTimer()
    }

    func trackDefaultProvider(context: Context) {
        // Joined-component signature — one event per distinct selection, repeats deduped.
        let signature = [
            context.providerID,
            context.modelID,
            context.reasoningEffort,
            context.fastMode ? "fast" : "standard",
        ].joined(separator: "|")
        guard signature != lastProviderSignature else { return }
        lastProviderSignature = signature

        var report = baseReport(event: "agent_provider_default")
        report["provider_id"] = .string(context.providerID)
        report["provider_display_name"] = .string(context.providerDisplayName)
        report["model_id"] = .string(context.modelID)
        report["reasoning_effort"] = .string(context.reasoningEffort)
        report["fast_mode"] = .int(context.fastMode ? 1 : 0)
        send(report)
    }

    private func startHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendHeartbeatIfNeeded()
            }
        }
    }

    private func sendHeartbeatIfNeeded(now: Date = Date()) {
        guard let startedAt,
              NSApp.isActive,
              let context = contextProvider?() else {
            return
        }
        if let lastHeartbeatAt,
           now.timeIntervalSince(lastHeartbeatAt) < Self.heartbeatInterval {
            return
        }
        lastHeartbeatAt = now

        var report = baseReport(event: "app_active_heartbeat")
        report["active_minutes_since_launch"] = .int(max(0, Int(now.timeIntervalSince(startedAt) / 60)))
        report["provider_id"] = .string(context.providerID)
        report["node_count"] = .int(context.nodeCount)
        send(report)
    }

    private func trackLaunch() {
        var report = baseReport(event: "app_launch")
        report["os_version"] = .string(ProcessInfo.processInfo.operatingSystemVersionString)
        report["cpu_arch"] = .string(Self.cpuArchitecture)
        report["hardware_model"] = .string(Self.hardwareModelIdentifier())
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            report["app_version"] = .string(version)
        }
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            report["app_build"] = .string(build)
        }
        send(report)
    }

    private func baseReport(event: String) -> [String: SZJellystatReportValue] {
        [
            "event": .string(event),
            "schema_version": .int(1),
            "debug": .int(Self.debugFlag)
        ]
    }

    private func send(_ report: [String: SZJellystatReportValue]) {
        guard let config else { return }
        let payload = SZJellystatPayload(apiKey: config.apiKey, installUID: installUID, report: report)

        #if DEBUG
        if let data = try? SZJellystatClient.debugLogEncoder.encode(payload),
           let json = String(data: data, encoding: .utf8) {
            print("Jellystat DEBUG payload: \(json)")
        }
        #else
        SZJellystatClient.post(payload)
        #endif
    }

    private static func installUID(userDefaults: UserDefaults) -> String {
        if let existing = userDefaults.string(forKey: installUIDDefaultsKey), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        userDefaults.set(created, forKey: installUIDDefaultsKey)
        return created
    }

    private static var debugFlag: Int {
        #if DEBUG
        1
        #else
        0
        #endif
    }

    private static var cpuArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static func hardwareModelIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
