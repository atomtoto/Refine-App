import Foundation

/// Long-term power spectra of the Mid (L+R)/2 and Side (L−R)/2 signals of a stream.
final class StereoStatistics {
    static let fftSize = 4096

    let sampleRate: Double
    private let midFramer = SpectralFramer(size: fftSize, hop: fftSize / 2)
    private let sideFramer = SpectralFramer(size: fftSize, hop: fftSize / 2)
    private var midSum: [Double]
    private var sideSum: [Double]
    private var midFrames = 0
    private var sideFrames = 0

    init(sampleRate: Double = AudioReader.targetSampleRate) {
        self.sampleRate = sampleRate
        midSum = .init(repeating: 0, count: Self.fftSize / 2 + 1)
        sideSum = .init(repeating: 0, count: Self.fftSize / 2 + 1)
    }

    var binWidth: Double { sampleRate / Double(Self.fftSize) }
    var averageMid: [Double] { midSum.map { $0 / Double(max(midFrames, 1)) } }
    var averageSide: [Double] { sideSum.map { $0 / Double(max(sideFrames, 1)) } }

    /// Mono input counts as pure Mid.
    func consume(_ channels: [[Float]]) {
        guard let left = channels.first else { return }
        let right = channels.count > 1 ? channels[1] : left
        let count = min(left.count, right.count)
        var mid = [Float](repeating: 0, count: count)
        var side = [Float](repeating: 0, count: count)
        for i in 0..<count {
            mid[i] = (left[i] + right[i]) * 0.5
            side[i] = (left[i] - right[i]) * 0.5
        }
        midFramer.consume(mid) { power, _ in
            midFrames += 1
            for k in power.indices { midSum[k] += Double(power[k]) }
        }
        sideFramer.consume(side) { power, _ in
            sideFrames += 1
            for k in power.indices { sideSum[k] += Double(power[k]) }
        }
    }
}

/// Third-octave bands, the resolution at which the ear judges stereo width.
struct ThirdOctaveBand: Equatable {
    var lower: Double
    var center: Double
    var upper: Double

    static func bands(from lowest: Double, to highest: Double) -> [ThirdOctaveBand] {
        stride(from: 0, through: 60, by: 1).compactMap { n -> ThirdOctaveBand? in
            let center = lowest * pow(2, Double(n) / 3)
            guard center <= highest else { return nil }
            return ThirdOctaveBand(lower: center * pow(2, -1.0 / 6), center: center, upper: center * pow(2, 1.0 / 6))
        }
    }

    func sum(_ power: [Double], binWidth: Double) -> Double {
        let first = max(1, Int((lower / binWidth).rounded(.up)))
        let last = min(power.count - 1, Int(upper / binWidth))
        guard first <= last else { return 0 }
        return power[first...last].reduce(0, +)
    }
}

/// How wide a file's stereo image is, and where it narrows.
///
/// Low-bitrate MP3s use joint stereo: to save bits, the encoder starves the Side signal in the highs, so the
/// image collapses towards the centre above some frequency. Real mixes often get narrower towards the highs too,
/// but gradually. So the Side/Mid ratio's trend is fitted where the image is safe (1.5–6 kHz) and extended
/// upwards; a collapse is a fall well below that trend, held to the top of the analysed band.
struct StereoProfile: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case mono, intact, collapsed
    }

    var kind: Kind
    /// Side-to-Mid power ratio of the fitted trend at 4 kHz, in dB.
    var referenceRatio: Double
    /// How the ratio evolves with frequency, in dB per octave.
    var trendSlope: Double = 0
    /// Lowest frequency of the collapsed region, in Hz.
    var collapseFrequency: Double?

    /// Below this Side/Mid ratio, a file is effectively mono.
    static let monoThreshold: Double = -25
    /// A band is collapsed when its ratio falls this far below the trend.
    static let collapseDrop: Double = 9

    /// Side/Mid ratio the trend predicts at `frequency`, in dB.
    func expectedRatio(at frequency: Double) -> Double {
        referenceRatio + trendSlope * log2(frequency / 4_000)
    }

    static func measure(mid: [Double], side: [Double], binWidth: Double, upTo limit: Double) -> StereoProfile {
        let ratios = ratioByBand(mid: mid, side: side, binWidth: binWidth, upTo: limit)
        let reference = ratios.filter { (1_500...6_000).contains($0.band.center) }
        guard reference.count >= 3 else { return StereoProfile(kind: .mono, referenceRatio: -100) }

        // Least-squares line of ratio against log2(frequency / 4 kHz).
        let xs = reference.map { log2($0.band.center / 4_000) }, ys = reference.map(\.ratio)
        let meanX = xs.reduce(0, +) / Double(xs.count), meanY = ys.reduce(0, +) / Double(ys.count)
        let covariance = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let variance = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        let slope = variance > 0 ? min(max(covariance / variance, -8), 3) : 0
        let profile = StereoProfile(kind: .intact, referenceRatio: meanY - slope * meanX, trendSlope: slope)
        guard meanY > monoThreshold else { return StereoProfile(kind: .mono, referenceRatio: meanY) }

        // The collapse must start above 6 kHz and hold up to the highest band analysed.
        let high = ratios.filter { $0.band.center > 6_000 }
        func collapsed(_ entry: (band: ThirdOctaveBand, ratio: Double)) -> Bool {
            entry.ratio < profile.expectedRatio(at: entry.band.center) - collapseDrop
        }
        guard let index = high.firstIndex(where: collapsed), high[index...].allSatisfy(collapsed) else { return profile }
        var result = profile
        result.kind = .collapsed
        result.collapseFrequency = high[index].band.lower
        return result
    }

    /// Side/Mid ratio per third-octave band, skipping bands without meaningful Mid content.
    static func ratioByBand(mid: [Double], side: [Double], binWidth: Double, upTo limit: Double)
        -> [(band: ThirdOctaveBand, ratio: Double)] {
        let bands = ThirdOctaveBand.bands(from: 1_000, to: min(limit, 20_000))
        let midLevels = bands.map { $0.sum(mid, binWidth: binWidth) }
        let loudest = midLevels.max() ?? 0
        return zip(bands, midLevels).compactMap { band, midLevel in
            guard loudest > 0, midLevel > loudest * 1e-6 else { return nil }
            let sideLevel = band.sum(side, binWidth: binWidth)
            return (band, 10 * log10(max(sideLevel, 1e-30) / midLevel))
        }
    }
}
