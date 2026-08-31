// SPDX-License-Identifier: AGPL-3.0-only
// Pure framing math for recording: ratio chips, resolution tiers, the output size a crop yields,
// and the full-frame size a take renders at. No AppKit; pinned by unit tests.
import Foundation

public enum SZRecordFraming {
    /// The framing overlay's ratio chips; the raw value is the persisted form.
    public enum Ratio: String, Codable, CaseIterable, Sendable {
        case wide
        case tall
        case square
        case portrait
        case free

        /// Output aspect (w/h); nil for free (the crop's own).
        public var aspect: Double? {
            switch self {
            case .wide: 16.0 / 9.0
            case .tall: 9.0 / 16.0
            case .square: 1.0
            case .portrait: 4.0 / 5.0
            case .free: nil
            }
        }

        public var label: String {
            switch self {
            case .wide: "16:9"
            case .tall: "9:16"
            case .square: "1:1"
            case .portrait: "4:5"
            case .free: "Free"
            }
        }
    }

    /// Resolution tier — the output's short side (720p / 1080p / 4K).
    public enum Tier: Int, Codable, CaseIterable, Sendable {
        case p720 = 720
        case p1080 = 1080
        case p2160 = 2160

        public var label: String { self == .p2160 ? "4K" : "\(rawValue)" }
    }

    /// The format row's choices. UI + persistence face; the engine's SZVideoCodec shares raw values.
    public enum Codec: String, Codable, CaseIterable, Sendable {
        case h264
        case hevc
        case proRes422

        public var label: String {
            switch self {
            case .h264: "H.264"
            case .hevc: "HEVC"
            case .proRes422: "ProRes"
            }
        }
    }

    /// The sound row's choices. App = only this app's audio; System = everything the Mac is
    /// playing (this app included). Any non-off source needs the Screen Recording permission.
    public enum SoundSource: String, Codable, CaseIterable, Sendable {
        case off
        case app
        case system

        public var label: String {
            switch self {
            case .off: "Off"
            case .app: "App"
            case .system: "System"
            }
        }
    }

    /// The crop region's aspect (w/h) in picture pixels.
    public static func cropAspect(_ crop: SZRect, picture: (width: Int, height: Int)) -> Double {
        let w = max(crop.width * Double(picture.width), 1)
        let h = max(crop.height * Double(picture.height), 1)
        return w / h
    }

    /// Output file dimensions: the ratio's aspect (or the crop's own, for free) at the tier's
    /// short side, long side capped 4K-class (an extreme free crop must not ask the encoder for
    /// impossible dimensions), both axes even.
    public static func outputSize(ratio: Ratio, tier: Tier, crop: SZRect,
                                  picture: (width: Int, height: Int)) -> (width: Int, height: Int) {
        let aspect = ratio.aspect ?? cropAspect(crop, picture: picture)
        let short = Double(tier.rawValue)
        var w = aspect >= 1 ? short * aspect : short
        var h = aspect >= 1 ? short : short / aspect
        let long = max(w, h)
        if long > 4096 {
            let scale = 4096 / long
            w *= scale
            h *= scale
        }
        return (even(w), even(h))
    }

    /// The full-frame size a take renders at: output size / crop fraction, long side capped
    /// 4K-class, both axes even.
    public static func renderSize(output: (width: Int, height: Int), crop: SZRect)
        -> (width: Int, height: Int) {
        var w = Double(output.width) / min(max(crop.width, 0.01), 1)
        var h = Double(output.height) / min(max(crop.height, 0.01), 1)
        let long = max(w, h)
        if long > 4096 {
            let scale = 4096 / long
            w *= scale
            h *= scale
        }
        return (even(w), even(h))
    }

    /// `crop` re-fitted to `aspect` (picture pixels): centered on the old center, as large as
    /// fits the unit square. A ratio chip's press.
    public static func fitted(_ crop: SZRect, toAspect aspect: Double,
                              picture: (width: Int, height: Int)) -> SZRect {
        // normalized width w maps to pixel aspect a as: (w * pw) / (h * ph) = a
        var w = 1.0
        var h = w * Double(picture.width) / (aspect * Double(picture.height))
        if h > 1 {
            w /= h
            h = 1
        }
        let cx = crop.x + crop.width / 2, cy = crop.y + crop.height / 2
        let x = min(max(cx - w / 2, 0), 1 - w)
        let y = min(max(cy - h / 2, 0), 1 - h)
        return SZRect(x: x, y: y, width: w, height: h)
    }

    /// A corner drag under a fixed ratio: grow the crop from the anchored (opposite) corner to
    /// `desiredWidth`, holding the chip's pixel aspect and staying inside the unit square —
    /// clamping either axis independently would break the lock and distort the take.
    /// `dirX`/`dirY` are +1 when the dragged corner sits right/below the anchor.
    public static func aspectResized(anchor: (x: Double, y: Double), dirX: Double, dirY: Double,
                                     desiredWidth: Double, aspect: Double,
                                     picture: (width: Int, height: Int),
                                     minSize: Double = 0.05) -> SZRect {
        let heightPerWidth = Double(picture.width) / (aspect * Double(picture.height))
        let availW = max(dirX > 0 ? 1 - anchor.x : anchor.x, 0.01)
        let availH = max(dirY > 0 ? 1 - anchor.y : anchor.y, 0.01)
        let maxW = min(availW, availH / heightPerWidth)
        let minW = min(max(minSize, minSize / heightPerWidth), maxW)
        let w = min(max(desiredWidth, minW), maxW)
        let h = w * heightPerWidth
        return SZRect(x: dirX > 0 ? anchor.x : anchor.x - w,
                      y: dirY > 0 ? anchor.y : anchor.y - h,
                      width: w, height: h)
    }

    /// `crop` clamped into the unit square with a minimum size — the drag guard.
    public static func clamped(_ crop: SZRect, minSize: Double = 0.05) -> SZRect {
        let w = min(max(crop.width, minSize), 1)
        let h = min(max(crop.height, minSize), 1)
        let x = min(max(crop.x, 0), 1 - w)
        let y = min(max(crop.y, 0), 1 - h)
        return SZRect(x: x, y: y, width: w, height: h)
    }

    private static func even(_ value: Double) -> Int { max(Int(value.rounded()) & ~1, 2) }
}
