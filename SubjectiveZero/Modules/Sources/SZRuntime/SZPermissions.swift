// SPDX-License-Identifier: AGPL-3.0-only
// The runtime's permission broker (RUNTIME.md). The runtime owns *permissions*; the capability itself
// (camera/microphone capture) lives in the node. This is the single place that queries / requests the OS
// entitlements a node declares — minimal by design (one case per entitlement a node actually uses;
// `.camera`, `.microphone` and `.screenRecording`), extended as a node needs it.
//
// `isAuthorized` is a safe synchronous status read (no prompt, no usage-description requirement — usable
// from tests). `requestAccess` prompts (the camera/microphone cases require their usage description in
// the host app's Info.plist); it is only ever called from the app (the host pre-grants declared
// permissions before loading a node), never from headless tests.
@preconcurrency import AVFoundation
import CoreGraphics
import SZCore

public final class SZPermissions: Sendable {
    public init() {}

    /// Whether `entitlement` is currently authorized. Synchronous, never prompts — safe anywhere.
    public func isAuthorized(_ entitlement: SZEntitlement) -> Bool {
        switch entitlement {
        case .camera: AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .screenRecording: CGPreflightScreenCaptureAccess()
        }
    }

    /// Request `entitlement`, prompting once if undetermined; returns the grant. Requires the matching
    /// usage description in the host bundle (`NSCameraUsageDescription` for `.camera`,
    /// `NSMicrophoneUsageDescription` for `.microphone`).
    public func requestAccess(_ entitlement: SZEntitlement) async -> Bool {
        switch entitlement {
        case .camera: await AVCaptureDevice.requestAccess(for: .video)
        case .microphone: await AVCaptureDevice.requestAccess(for: .audio)
        // macOS applies a fresh Screen Recording grant only after the app relaunches, so the first
        // grant returns false here and the node runs on its fallback until then (same caveat the
        // recorder lives with in SZHost+Recording).
        case .screenRecording: CGRequestScreenCaptureAccess()
        }
    }
}
