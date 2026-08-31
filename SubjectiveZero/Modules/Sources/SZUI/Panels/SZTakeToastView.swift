// SPDX-License-Identifier: AGPL-3.0-only
// The finished-take toast: last-frame thumbnail, "Recording N saved", length · dimensions · fps,
// and a Reveal button. Quiet glass card, bottom-right of the workspace; the host owns
// presentation and auto-dismiss.
import SwiftUI

public struct SZTakeToastView: View {
    private let title: String
    private let subtitle: String
    private let thumbnail: NSImage?
    private let onReveal: () -> Void

    public init(title: String, subtitle: String, thumbnail: NSImage?,
                onReveal: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.thumbnail = thumbnail
        self.onReveal = onReveal
    }

    public var body: some View {
        HStack(spacing: 10) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 72, maxHeight: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button("Reveal", action: onReveal)
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.leading, 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.14), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}
