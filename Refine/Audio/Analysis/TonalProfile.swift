import Foundation

/// Where a file's tonal balance sits against a reference, in three broad strokes rather than a full curve:
/// matching a curve band by band would make every song sound the same, these three describe what people hear
/// as « dull », « boomy » or « muddy » and leave the rest of a mix's character alone.
struct TonalProfile: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case dull, balanced, bright, heavy, thin
    }

    /// Tilt from 500 Hz to the top of the analysed band compared with the reference, in dB per octave.
    /// Negative: duller than usual.
    var tilt: Double
    /// Bass (40–120 Hz) against the low mids (120–500 Hz), compared with the reference, in dB.
    var bass: Double
    /// Bump of the 150–450 Hz region over its neighbours, compared with the reference, in dB.
    var mud: Double
    /// Highest frequency the tilt was measured to.
    var upperFrequency: Double

    /// Within these, a deviation is a matter of taste: every reference master measured falls inside.
    static let tiltTolerance: Double = 1
    static let bassTolerance: Double = 4
    static let mudTolerance: Double = 3

    var kind: Kind {
        if tilt < -Self.tiltTolerance { return .dull }
        if bass > Self.bassTolerance || mud > Self.mudTolerance { return .heavy }
        if tilt > Self.tiltTolerance { return .bright }
        if bass < -Self.bassTolerance { return .thin }
        return .balanced
    }

    /// Change in dB at 4 kHz the tilt amounts to, a figure people can relate to.
    var presenceOffset: Double { tilt * log2(4_000 / 1_000) }

    /// Reference third-octave levels, relative to the 250 Hz–2 kHz mean: the long-term average of modern
    /// commercial masters (measured on 18 releases, smoothed to an octave).
    static func reference(at frequency: Double) -> Double {
        let points = referencePoints
        guard frequency > points[0].frequency else { return points[0].level }
        guard let upperIndex = points.firstIndex(where: { $0.frequency >= frequency }) else {
            return points[points.count - 1].level
        }
        let lower = points[upperIndex - 1], upper = points[upperIndex]
        let t = log2(frequency / lower.frequency) / log2(upper.frequency / lower.frequency)
        return lower.level + (upper.level - lower.level) * t
    }

    static let referencePoints: [(frequency: Double, level: Double)] = [
        (31.5, 4), (50, 6), (80, 4.5), (125, 1.5), (200, -0.5), (315, 0.3), (500, 1.2), (1_000, -1), (2_000, -4),
        (4_000, -6.3), (6_300, -5.8), (8_000, -6.3), (10_000, -7.5), (12_500, -10), (16_000, -13.5),
    ]

    /// Third-octave band levels in dB, relative to their 250 Hz–2 kHz mean.
    static func bandLevels(averagePower: [Double], binWidth: Double, upTo limit: Double)
        -> [(band: ThirdOctaveBand, level: Double)] {
        let bands = ThirdOctaveBand.bands(from: 31.5, to: limit)
        let levels = bands.map { 10 * log10(max($0.sum(averagePower, binWidth: binWidth), 1e-30)) }
        let middle = zip(bands, levels).filter { (250...2_000).contains($0.0.center) }.map(\.1)
        guard !middle.isEmpty else { return [] }
        let reference = middle.reduce(0, +) / Double(middle.count)
        return zip(bands, levels).map { ($0, $1 - reference) }
    }

    /// - Parameter cutoff: the file's cutoff; the tilt is measured below it, never in the band a codec removed.
    static func measure(averagePower: [Double], binWidth: Double, cutoff: Double) -> TonalProfile? {
        let upper = min(0.9 * cutoff, 12_500)
        let levels = bandLevels(averagePower: averagePower, binWidth: binWidth, upTo: upper)
        guard levels.count > 20 else { return nil }
        let deviations = levels.map { (frequency: $0.band.center, value: $0.level - reference(at: $0.band.center)) }
        func mean(_ range: ClosedRange<Double>) -> Double {
            let values = deviations.filter { range.contains($0.frequency) }.map(\.value)
            return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }

        // Least-squares line of the deviation against log2(frequency) above 500 Hz.
        let high = deviations.filter { $0.frequency >= 500 }
        let xs = high.map { log2($0.frequency / 1_000) }, ys = high.map(\.value)
        let meanX = xs.reduce(0, +) / Double(xs.count), meanY = ys.reduce(0, +) / Double(ys.count)
        let covariance = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let variance = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        let tilt = variance > 0 ? covariance / variance : 0

        return TonalProfile(
            tilt: tilt,
            bass: mean(40...120) - mean(125...500),
            mud: mean(160...400) - (mean(63...125) + mean(500...1_000)) / 2,
            upperFrequency: upper)
    }
}
