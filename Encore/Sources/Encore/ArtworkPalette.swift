import SwiftUI
import AppKit

struct Palette: Equatable {
    var accent: Color
    var dim: Color

    static let fallback = Palette(
        accent: Theme.fallbackAccent,
        dim: Color(hue: 0.99, saturation: 0.55, brightness: 0.22)
    )
}

/// Extracts a vibrant accent color from album artwork (Apple Music-style
/// adaptive theming). Results are cached per URL.
@MainActor
final class ArtworkPalette {
    static let shared = ArtworkPalette()
    private var cache: [URL: Palette] = [:]

    private init() {}

    func palette(for url: URL?) async -> Palette {
        guard let url else { return .fallback }
        if let cached = cache[url] { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let palette = Self.extract(from: data) else { return .fallback }
        cache[url] = palette
        return palette
    }

    nonisolated static func extract(from data: Data) -> Palette? {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let size = 24
        guard let ctx = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let pixels = ctx.data else { return nil }

        var bestScore = -1.0
        var bestHSB: (h: Double, s: Double, b: Double) = (0, 0, 0.5)
        let buffer = pixels.bindMemory(to: UInt8.self, capacity: size * size * 4)

        for i in 0..<(size * size) {
            let r = Double(buffer[i * 4]) / 255
            let g = Double(buffer[i * 4 + 1]) / 255
            let b = Double(buffer[i * 4 + 2]) / 255

            let maxC = max(r, g, b), minC = min(r, g, b)
            let delta = maxC - minC
            let brightness = maxC
            let saturation = maxC == 0 ? 0 : delta / maxC

            var hue = 0.0
            if delta > 0 {
                if maxC == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
                else if maxC == g { hue = (b - r) / delta + 2 }
                else { hue = (r - g) / delta + 4 }
                hue /= 6
                if hue < 0 { hue += 1 }
            }

            guard brightness > 0.2, brightness < 0.98 else { continue }
            let score = saturation * 0.75 + brightness * 0.25
            if score > bestScore {
                bestScore = score
                bestHSB = (hue, saturation, brightness)
            }
        }

        guard bestScore > 0 else { return Palette.fallback }

        let accent = Color(hue: bestHSB.h,
                           saturation: min(bestHSB.s, 0.72),
                           brightness: max(bestHSB.b, 0.72))
        let dim = Color(hue: bestHSB.h,
                        saturation: min(bestHSB.s + 0.1, 0.8),
                        brightness: 0.2)
        return Palette(accent: accent, dim: dim)
    }
}
