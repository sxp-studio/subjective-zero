// SPDX-License-Identifier: AGPL-3.0-only
// SZTelemetry's first-session milestones (prompt_sent / turn_ended / node_built): once per
// process, an install-level marker that survives the process, and the payload the dashboard
// funnel reads (first_in_install, minutes_since_launch, the caller's detail).
import Foundation
import Testing
@testable import SubjectiveZero

@MainActor
private func makeTelemetry(suite: String) -> (SZTelemetry, Sink) {
    let defaults = UserDefaults(suiteName: suite)!
    let telemetry = SZTelemetry(userDefaults: defaults)
    let box = Sink()
    telemetry.reportObserverForTests = { box.value.append($0) }
    return (telemetry, box)
}

private final class Sink { var value: [[String: SZJellystatReportValue]] = [] }

@Test @MainActor func milestoneFiresOncePerProcessWithFunnelPayload() {
    let suite = "sz-telemetry-tests-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let (telemetry, sent) = makeTelemetry(suite: suite)

    telemetry.trackMilestone("prompt_sent", detail: ["provider_id": .string("claude")])
    telemetry.trackMilestone("prompt_sent", detail: ["provider_id": .string("codex")])   // deduped
    telemetry.trackMilestone("node_built")

    let events = sent.value.map { $0["event"] }
    #expect(events == [.string("prompt_sent"), .string("node_built")])
    let prompt = sent.value[0]
    #expect(prompt["first_in_install"] == .int(1))
    #expect(prompt["minutes_since_launch"] == .int(0))
    #expect(prompt["provider_id"] == .string("claude"))
    #expect(prompt["schema_version"] == .int(1))
}

@Test @MainActor func milestoneCanRequireAnEarlierOne() {
    let suite = "sz-telemetry-tests-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let (telemetry, sent) = makeTelemetry(suite: suite)
    #expect(!telemetry.hasSentMilestone("prompt_sent"))
    telemetry.trackMilestone("prompt_sent")
    #expect(telemetry.hasSentMilestone("prompt_sent"))
    #expect(sent.value.count == 1)
}

@Test @MainActor func devMachineTagRidesEveryReportOnlyWhenOptedIn() {
    let suite = "sz-telemetry-tests-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let (plain, plainSent) = makeTelemetry(suite: suite)
    plain.trackMilestone("node_built")
    #expect(plainSent.value.last?["dev"] == nil)

    UserDefaults(suiteName: suite)!.set(true, forKey: "studio.sxp.subjectivezero.jellystat.devMachine")
    let (dev, devSent) = makeTelemetry(suite: suite)
    dev.trackMilestone("node_built")
    #expect(devSent.value.last?["dev"] == .int(1))
}

@Test @MainActor func milestoneInstallMarkerOutlivesTheProcess() {
    let suite = "sz-telemetry-tests-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }

    let (first, firstSent) = makeTelemetry(suite: suite)
    first.trackMilestone("turn_ended", detail: ["failed": .int(1)])
    #expect(firstSent.value.last?["first_in_install"] == .int(1))

    // A "relaunch": a fresh instance over the same defaults — same session-level event, no
    // longer the install's first.
    let (second, secondSent) = makeTelemetry(suite: suite)
    second.trackMilestone("turn_ended", detail: ["failed": .int(0)])
    #expect(secondSent.value.last?["event"] == .string("turn_ended"))
    #expect(secondSent.value.last?["first_in_install"] == .int(0))
    #expect(secondSent.value.last?["failed"] == .int(0))
}
