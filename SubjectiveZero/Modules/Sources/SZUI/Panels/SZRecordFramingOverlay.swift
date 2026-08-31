// SPDX-License-Identifier: AGPL-3.0-only
// The framing editor, shown over one viewport while the user frames a recording: dimmed surround,
// a draggable crop with corner handles and thirds lines, a live size tag, and a bottom bar with
// ratio chips and Done (esc also closes). The crop is picture-normalized and host-owned; this view
// maps it onto the tile's aspect-fitted picture rect and reports edits back.
import SwiftUI
import SZCore

public struct SZRecordFramingOverlay: View {
    private let picture: (width: Int, height: Int)   // full-frame pixel size (aspect + readout)
    private let crop: SZRect
    private let ratio: SZRecordFraming.Ratio
    private let tier: SZRecordFraming.Tier
    private let onCropChanged: (SZRect) -> Void
    private let onRatioPicked: (SZRecordFraming.Ratio) -> Void
    private let onDone: () -> Void

    /// The crop at the start of the active drag — deltas apply to this, not the live value.
    @State private var dragBase: SZRect?

    public init(picture: (width: Int, height: Int), crop: SZRect,
                ratio: SZRecordFraming.Ratio, tier: SZRecordFraming.Tier,
                onCropChanged: @escaping (SZRect) -> Void,
                onRatioPicked: @escaping (SZRecordFraming.Ratio) -> Void,
                onDone: @escaping () -> Void) {
        self.picture = picture
        self.crop = crop
        self.ratio = ratio
        self.tier = tier
        self.onCropChanged = onCropChanged
        self.onRatioPicked = onRatioPicked
        self.onDone = onDone
    }

    public var body: some View {
        GeometryReader { proxy in
            let fit = Self.pictureRect(picture: picture, in: proxy.size)
            let rect = CGRect(x: fit.minX + crop.x * fit.width,
                              y: fit.minY + crop.y * fit.height,
                              width: crop.width * fit.width,
                              height: crop.height * fit.height)
            // everything is positioned by absolute offsets from the tile's top-left, so every
            // layer must anchor there at full size — a smaller layer in a centering/bottom
            // alignment would drift against the others as the crop changes size (it did)
            ZStack(alignment: .topLeading) {
                SZCropShades(rect: rect, size: proxy.size, opacity: 0.55)
                cropFrame(rect, fit: fit)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .overlay(alignment: .bottom) {
                bar.padding(.bottom, 12)
            }
        }
        .contentShape(Rectangle())
    }

    /// The picture aspect-fitted in the tile — the same mapping the Metal present uses, so the
    /// crop sits on the pixels the take will contain.
    static func pictureRect(picture: (width: Int, height: Int), in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, picture.width > 0, picture.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = min(size.width / Double(picture.width), size.height / Double(picture.height))
        let w = Double(picture.width) * scale, h = Double(picture.height) * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func cropFrame(_ rect: CGRect, fit: CGRect) -> some View {
        let output = SZRecordFraming.outputSize(ratio: ratio, tier: tier, crop: crop, picture: picture)
        return ZStack(alignment: .topLeading) {
            // the crop body: border + thirds, draggable as a whole
            Rectangle()
                .fill(Color.white.opacity(0.001))   // hit area for the move drag
                .overlay {
                    ZStack {
                        thirds
                        Rectangle().strokeBorder(.white.opacity(0.92), lineWidth: 1.25)
                            .shadow(color: .black.opacity(0.4), radius: 1)
                    }
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .gesture(moveDrag(fit: fit))
            // the size tag, riding above the crop (inside it near the top edge of the tile)
            Text("\(ratio == .free ? "" : "\(ratio.label) · ")\(output.width) × \(output.height)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
                .offset(x: max(rect.midX - 60, 4), y: max(rect.minY - 24, 4))
                .allowsHitTesting(false)
            ForEach(Corner.allCases, id: \.self) { corner in
                handle(corner, rect: rect, fit: fit)
            }
        }
    }

    private var thirds: some View {
        ZStack {
            HStack(spacing: 0) {
                Spacer(); line(vertical: true); Spacer(); line(vertical: true); Spacer()
            }
            VStack(spacing: 0) {
                Spacer(); line(vertical: false); Spacer(); line(vertical: false); Spacer()
            }
        }
        .allowsHitTesting(false)
    }

    private func line(vertical: Bool) -> some View {
        Rectangle().fill(.white.opacity(0.28))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }

    // MARK: - Drags

    private enum Corner: CaseIterable, Hashable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private func handle(_ corner: Corner, rect: CGRect, fit: CGRect) -> some View {
        let x = corner == .topLeft || corner == .bottomLeft ? rect.minX : rect.maxX
        let y = corner == .topLeft || corner == .topRight ? rect.minY : rect.maxY
        return RoundedRectangle(cornerRadius: 2)
            .fill(.white)
            .frame(width: 8, height: 8)
            .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
            .contentShape(Rectangle().inset(by: -8))
            .offset(x: x - 4, y: y - 4)
            .gesture(resizeDrag(corner, fit: fit))
    }

    private func moveDrag(fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let base = dragBase ?? crop
                dragBase = base
                let moved = SZRect(x: base.x + value.translation.width / fit.width,
                                   y: base.y + value.translation.height / fit.height,
                                   width: base.width, height: base.height)
                onCropChanged(SZRecordFraming.clamped(moved))
            }
            .onEnded { _ in dragBase = nil }
    }

    private func resizeDrag(_ corner: Corner, fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let base = dragBase ?? crop
                dragBase = base
                let dx = value.translation.width / fit.width
                let dy = value.translation.height / fit.height
                let free = resized(base, corner: corner, dx: dx, dy: dy)
                if let aspect = ratio.aspect {
                    // ratio locked: grow from the anchored corner, aspect-preserving clamp — a
                    // per-axis clamp would silently break the lock and distort the take
                    let dirX: Double = (corner == .topRight || corner == .bottomRight) ? 1 : -1
                    let dirY: Double = (corner == .bottomLeft || corner == .bottomRight) ? 1 : -1
                    let anchor = (x: dirX > 0 ? base.x : base.x + base.width,
                                  y: dirY > 0 ? base.y : base.y + base.height)
                    onCropChanged(SZRecordFraming.aspectResized(
                        anchor: anchor, dirX: dirX, dirY: dirY, desiredWidth: free.width,
                        aspect: aspect, picture: picture))
                } else {
                    onCropChanged(SZRecordFraming.clamped(free))
                }
            }
            .onEnded { _ in dragBase = nil }
    }

    /// The free-form resize: the grabbed corner follows the drag, its opposite stays anchored.
    private func resized(_ base: SZRect, corner: Corner, dx: Double, dy: Double) -> SZRect {
        var minX = base.x, minY = base.y
        var maxX = base.x + base.width, maxY = base.y + base.height
        switch corner {
        case .topLeft: minX += dx; minY += dy
        case .topRight: maxX += dx; minY += dy
        case .bottomLeft: minX += dx; maxY += dy
        case .bottomRight: maxX += dx; maxY += dy
        }
        return SZRect(x: min(minX, maxX - 0.01), y: min(minY, maxY - 0.01),
                      width: max(maxX - minX, 0.01), height: max(maxY - minY, 0.01))
    }

    // MARK: - Bottom bar

    private var bar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(SZRecordFraming.Ratio.allCases, id: \.self) { r in
                    Button { onRatioPicked(r) } label: {
                        Text(r.label)
                            .font(.system(size: 10.5, weight: ratio == r ? .semibold : .regular))
                            .foregroundStyle(ratio == r ? .white : .white.opacity(0.6))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(ratio == r ? 0.18 : 0.07)))
                    }
                    .buttonStyle(.plain)
                }
            }
            RoundedRectangle(cornerRadius: 0.5)
                .fill(.white.opacity(0.16))
                .frame(width: 1, height: 18)   // fences the chips off from Done (the HUD divider)
            Button(action: onDone) {
                Text("Done")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)   // esc closes too
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}
