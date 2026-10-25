import SwiftUI
import UIKit

/// SkyBackground: the desktop's animated white-blue canvas, ported.
///
/// Same recipe as `src/gui/ios/sky_bg.py` on the desktop:
/// light blue-white base (#F2F7FF), ~30 softly-tinted Apple logos
/// drifting upward with a sine sway, 60 fps.
///
/// Same performance rules, too: every floater image is PRE-RENDERED
/// once (size + tint + opacity baked in), so each frame is just blits —
/// no per-frame rasterization, no blur, no GeometryReader. The motion
/// uses real elapsed time, so it never drifts or stutters when the
/// main thread is busy.
struct SkyBackground: View {
    private let floaters: [SkyFloater]

    init() {
        self.floaters = SkyBackground.makeFloaters()
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                guard size.width > 0, size.height > 0 else { return }
                let t = timeline.date.timeIntervalSinceReferenceDate
                for f in floaters {
                    // Drift upward, wrap in [-0.12, 1.12] like the desktop.
                    let span = 1.24
                    var ry = (f.ry0 - f.speed * t + 0.12)
                        .truncatingRemainder(dividingBy: span)
                    if ry < 0 { ry += span }
                    ry -= 0.12
                    let x = f.rx * size.width + sin(t * 0.6 + f.phase) * f.sway
                    let y = ry * size.height + cos(t * 0.4 + f.phase) * 10
                    context.draw(f.image, at: CGPoint(x: x, y: y), anchor: .center)
                }
            }
        }
        .background(Color(red: 0xF2 / 255.0, green: 0xF7 / 255.0, blue: 1.0))
        .ignoresSafeArea()
    }

    // MARK: - Pre-render (once)

    private static func makeFloaters() -> [SkyFloater] {
        // Desktop tints: soft blues, light enough to never fight content.
        let tints: [UInt32] = [0xBFD9FA, 0xA9CBF7, 0xC9DFFB, 0x9DC2F2, 0xD4E4FC]
        var rng = SeededRNG(seed: 20260930) // same seed as the desktop
        let thirds = [(0.02, 0.33), (0.335, 0.665), (0.67, 0.98)]
        var out: [SkyFloater] = []
        out.reserveCapacity(30)
        for i in 0..<30 {
            let size = CGFloat(rng.nextInt(lo: 26, hi: 92))
            let tint = tints[rng.nextInt(lo: 0, hi: tints.count - 1)]
            let opacity = rng.nextDouble(lo: 0.35, hi: 0.75)
            let image = tintedApple(size: size, hex: tint, opacity: opacity)
            let band = thirds[i % 3]
            out.append(SkyFloater(
                image: image,
                rx: rng.nextDouble(lo: band.0, hi: band.1),
                ry0: rng.nextDouble(lo: 0, hi: 1),
                speed: rng.nextDouble(lo: 0.008, hi: 0.028),
                phase: rng.nextDouble(lo: 0, hi: 2 * .pi),
                sway: rng.nextDouble(lo: 8, hi: 30)
            ))
        }
        return out
    }

    /// Rasterize the Apple logo once at `size` px, tinted, opacity baked.
    private static func tintedApple(size: CGFloat, hex: UInt32, opacity: Double) -> Image {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 3.0
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: size, height: size), format: format)
        let ui = renderer.image { _ in
            guard let symbol = UIImage(systemName: "apple.logo") else { return }
            let color = UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: 1.0
            ).withAlphaComponent(opacity)
            let tinted = symbol.withTintColor(color, renderingMode: .alwaysOriginal)
            // Fit aspect-preserved, centered — never stretched.
            let s = min(size / tinted.size.width, size / tinted.size.height)
            let w = tinted.size.width * s, h = tinted.size.height * s
            tinted.draw(in: CGRect(x: (size - w) / 2, y: (size - h) / 2,
                                   width: w, height: h))
        }
        return Image(uiImage: ui)
    }
}

/// One drifting logo. `image` is pre-rendered; the rest is motion state.
private struct SkyFloater {
    let image: Image
    let rx: Double       // relative x 0..1
    let ry0: Double      // relative y at t=0 (drifts upward, wraps)
    let speed: Double    // relative y per second
    let phase: Double
    let sway: Double     // horizontal sine amplitude in px
}

/// Deterministic xorshift RNG so the sky looks the same every launch,
/// exactly like the desktop's `random.Random(20260930)`.
private struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed | 1 }
    private mutating func next() -> UInt64 {
        var x = state
        x ^= x << 13; x ^= x >> 7; x ^= x << 17
        state = x
        return x
    }
    mutating func nextInt(lo: Int, hi: Int) -> Int {
        lo + Int(next() % UInt64(hi - lo + 1))
    }
    mutating func nextDouble(lo: Double, hi: Double) -> Double {
        lo + (Double(next() % 1_000_000) / 1_000_000.0) * (hi - lo)
    }
}
