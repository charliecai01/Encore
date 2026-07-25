import Foundation

/// A 10-band graphic EQ setting: on/off, a preamp, and one gain per band.
public struct EQSettings: Codable, Equatable {
    public var enabled: Bool
    public var preamp: Double        // dB, clamped to Equalizer.gainRange
    public var gains: [Double]       // 10 band gains in dB, low → high
    public var presetName: String?   // nil = custom (edited away from a preset)

    public init(enabled: Bool = false,
                preamp: Double = 0,
                gains: [Double] = Array(repeating: 0, count: Equalizer.bandCount),
                presetName: String? = "Flat") {
        self.enabled = enabled
        self.preamp = preamp
        self.gains = gains
        self.presetName = presetName
    }
}

/// Shared model + persistence for the equalizer. The actual DSP runs in the
/// WKWebView via Web Audio biquad filters (see the controller scripts); this
/// enum only holds the numbers, presets, and the JS payload. Pure and
/// unit-tested; override `store` in tests.
public enum Equalizer {
    /// Master switch — **OFF (2026-07-23)**: tapping the site's `<video>` with
    /// `createMediaElementSource` permanently routes that element's audio
    /// through Web Audio, and in WKWebView the source node goes SILENT once the
    /// element loads a different track. Symptom: first song plays, every song
    /// after it is silent. `createMediaElementSource` is once-per-element and
    /// cannot be undone, so there's no in-page recovery — only never tapping
    /// the element (or reloading the page). While this is `false` the engines
    /// never call `__encore.eq(...)`, so the audio path is untouched and the
    /// EQ UI is hidden. See BUGS.md.
    public static var featureEnabled = false

    public static var store: UserDefaults = .standard
    private static let key = "equalizerSettings"

    public static let bandCount = 10
    /// ISO-ish octave centers, low → high.
    public static let frequencies: [Int] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    /// Both band gains and the preamp clamp to this range (dB).
    public static let gainRange: ClosedRange<Double> = -12...12

    /// Short axis label for a band, e.g. "500", "1k", "16k".
    public static func label(forBand i: Int) -> String {
        guard frequencies.indices.contains(i) else { return "" }
        let f = frequencies[i]
        return f >= 1000 ? "\(f / 1000)k" : "\(f)"
    }

    public struct Preset: Equatable {
        public let name: String
        public let gains: [Double]
        public init(_ name: String, _ gains: [Double]) { self.name = name; self.gains = gains }
    }

    //                                     32  64  125 250 500  1k  2k  4k  8k  16k
    public static let presets: [Preset] = [
        Preset("Flat",        [ 0,  0,  0,  0,  0,  0,  0,  0,  0,  0]),
        Preset("Bass Boost",  [ 7,  6,  5,  3,  1,  0,  0,  0,  0,  0]),
        Preset("Treble Boost",[ 0,  0,  0,  0,  0,  1,  3,  5,  6,  7]),
        Preset("Vocal",       [-2, -2, -1,  1,  3,  4,  4,  2,  1,  0]),
        Preset("Rock",        [ 5,  4,  3,  1, -1, -1,  1,  3,  4,  5]),
        Preset("Pop",         [-1,  0,  2,  4,  5,  4,  2,  0, -1, -2]),
        Preset("Loudness",    [ 6,  5,  2,  0, -1, -1,  0,  2,  5,  6]),
        Preset("Acoustic",    [ 4,  4,  3,  1,  2,  2,  3,  3,  4,  3]),
    ]

    public static func preset(named name: String) -> Preset? {
        presets.first { $0.name == name }
    }

    /// The preset whose gains exactly match, if any (so the UI can re-highlight
    /// a preset the user landed back on). Compares within 0.01 dB.
    public static func matchingPresetName(_ gains: [Double]) -> String? {
        presets.first { p in
            p.gains.count == gains.count &&
            zip(p.gains, gains).allSatisfy { abs($0 - $1) < 0.01 }
        }?.name
    }

    public static func load() -> EQSettings {
        guard let data = store.data(forKey: key),
              let decoded = try? JSONDecoder().decode(EQSettings.self, from: data) else {
            return EQSettings()
        }
        return sanitized(decoded)
    }

    public static func save(_ settings: EQSettings) {
        if let data = try? JSONEncoder().encode(sanitized(settings)) {
            store.set(data, forKey: key)
        }
    }

    /// Force 10 bands and clamp every value into range — guards against a
    /// corrupt payload or a future band-count change.
    public static func sanitized(_ settings: EQSettings) -> EQSettings {
        var out = settings
        var g = settings.gains
        if g.count != bandCount { g = Array(repeating: 0, count: bandCount) }
        out.gains = g.map { clamp($0) }
        out.preamp = clamp(settings.preamp)
        return out
    }

    private static func clamp(_ v: Double) -> Double {
        min(max(v, gainRange.lowerBound), gainRange.upperBound)
    }

    /// JSON for the `__encore.eq(...)` bridge call. Hand-built (no dictionary)
    /// so the numeric format is stable and locale-independent.
    public static func jsPayload(_ settings: EQSettings) -> String {
        let c = sanitized(settings)
        let gains = c.gains.map { fmt($0) }.joined(separator: ",")
        return "{\"enabled\":\(c.enabled),\"preamp\":\(fmt(c.preamp)),\"gains\":[\(gains)]}"
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), v)
    }
}
