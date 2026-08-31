// SPDX-License-Identifier: AGPL-3.0-only
// The Recording Options sheet (gear menu / app menu, and the record dot's first-ever press):
// every sticky take setting. Values are host-owned; Framing's Edit hands the stage to the crop
// overlay on the viewport.
import SwiftUI
import SZCore

public struct SZRecordSettingsSheet: View {
    private let framingSummary: String
    private let tier: SZRecordFraming.Tier
    private let fps: Int
    private let codec: SZRecordFraming.Codec
    private let outputSize: (width: Int, height: Int)
    private let sound: SZRecordFraming.SoundSource
    private let onEditFraming: () -> Void
    private let onPickTier: (SZRecordFraming.Tier) -> Void
    private let onPickFPS: (Int) -> Void
    private let onPickCodec: (SZRecordFraming.Codec) -> Void
    private let onPickSound: (SZRecordFraming.SoundSource) -> Void

    @Environment(\.dismiss) private var dismiss

    public init(framingSummary: String, tier: SZRecordFraming.Tier, fps: Int,
                codec: SZRecordFraming.Codec, outputSize: (width: Int, height: Int),
                sound: SZRecordFraming.SoundSource,
                onEditFraming: @escaping () -> Void,
                onPickTier: @escaping (SZRecordFraming.Tier) -> Void,
                onPickFPS: @escaping (Int) -> Void,
                onPickCodec: @escaping (SZRecordFraming.Codec) -> Void,
                onPickSound: @escaping (SZRecordFraming.SoundSource) -> Void) {
        self.framingSummary = framingSummary
        self.tier = tier
        self.fps = fps
        self.codec = codec
        self.outputSize = outputSize
        self.sound = sound
        self.onEditFraming = onEditFraming
        self.onPickTier = onPickTier
        self.onPickFPS = onPickFPS
        self.onPickCodec = onPickCodec
        self.onPickSound = onPickSound
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recording Options")
                .font(.system(size: 15, weight: .semibold))
                .padding(.bottom, 14)

            row("Framing") {
                Text(framingSummary)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 12)
                Button("Edit Framing") {
                    dismiss()
                    onEditFraming()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
            row("Resolution") {
                segments(SZRecordFraming.Tier.allCases, selected: tier,
                         label: \.label, pick: onPickTier)
            }
            row("Frame rate") {
                segments([30, 60], selected: fps, label: { "\($0)" }, pick: onPickFPS)
            }
            row("Format") {
                segments(SZRecordFraming.Codec.allCases, selected: codec,
                         label: \.label, pick: onPickCodec)
            }
            row("Sound") {
                // App = only this app's audio; System = everything the Mac is playing
                segments(SZRecordFraming.SoundSource.allCases, selected: sound,
                         label: \.label, pick: onPickSound)
            }

            Divider().padding(.vertical, 12)
            HStack {
                Text("Records \(outputSize.width) × \(outputSize.height). Saved for next time.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 20)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.regular)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            value()
        }
        .padding(.vertical, 7)
    }

    private func segments<T: Hashable>(_ options: [T], selected: T,
                                       label: @escaping (T) -> String,
                                       pick: @escaping (T) -> Void) -> some View {
        HStack(spacing: 1) {
            ForEach(options, id: \.self) { option in
                let on = option == selected
                Button { pick(option) } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(.white.opacity(on ? 0.16 : 0)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.07)))
        .frame(maxWidth: .infinity)
    }
}
