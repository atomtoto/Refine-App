import Foundation

/// « Punch » — gives back the attacks a heavy limiter flattened, the way a transient designer does.
///
/// The signal is split into three bands (kick and bass below 150 Hz, the body up to 4 kHz, the snap above),
/// each followed by a fast and a slow envelope linked across channels. Where the fast one leaps ahead of the
/// slow one, an attack is starting, and the band is lifted by up to 6 dB for the few milliseconds the slow
/// envelope takes to catch up. Sustained sounds keep both envelopes together and pass untouched.
final class PunchShaper {
    static let maximumBoost: Double = 6

    private struct Band {
        let fastAttack: Float
        let slowAttack: Float
        let release: Float
        /// Envelope gap, in dB, below which nothing happens: absorbs the ripple of steady low notes.
        let threshold: Float
        var fast: Float = 0
        var slow: Float = 0
        var gain: Float = 1

        init(fastAttack: Double, slowAttack: Double, release: Double, threshold: Float, sampleRate: Double) {
            func coefficient(_ seconds: Double) -> Float { Float(exp(-1 / (seconds * sampleRate))) }
            self.fastAttack = coefficient(fastAttack)
            self.slowAttack = coefficient(slowAttack)
            self.release = coefficient(release)
            self.threshold = threshold
        }

        mutating func boost(level: Float, maximum: Float) -> Float {
            fast = level > fast ? level + (fast - level) * fastAttack : level + (fast - level) * release
            slow = level > slow ? level + (slow - level) * slowAttack : level + (slow - level) * release
            guard fast > 1e-4, slow > 0 else { return 1 }
            let gap = 20 * log10(fast / max(slow, 1e-9)) - threshold
            let target = pow(10, min(max(gap, 0), maximum) / 20)
            // Fast to rise, gentle to settle, so the lift never clicks.
            gain = target > gain ? target + (gain - target) * 0.9 : target + (gain - target) * 0.998
            return gain
        }
    }

    private let maximum: Float
    private let lookahead: Int
    private var splitters: [ThreeBandSplitter]
    private var bands: [Band]
    /// Band signals waiting for their gain, `lookahead` per channel.
    private var delayLines: [SIMD3<Float>]
    private var delayPosition = 0
    private var skipped = 0
    private let channelCount: Int
    private var sinceAttack = Int.max / 2
    private let refractory: Int
    private(set) var attacks = 0

    /// - Parameter amount: 0…1, how much of the 6 dB lift to allow.
    init(amount: Double, channelCount: Int, sampleRate: Double = AudioReader.targetSampleRate) {
        maximum = Float(Self.maximumBoost * min(max(amount, 0), 1))
        self.channelCount = channelCount
        lookahead = Int(0.002 * sampleRate)
        refractory = Int(0.08 * sampleRate)
        splitters = (0..<channelCount).map { _ in ThreeBandSplitter(sampleRate: sampleRate) }
        bands = [
            Band(fastAttack: 0.004, slowAttack: 0.04, release: 0.15, threshold: 2.5, sampleRate: sampleRate),
            Band(fastAttack: 0.001, slowAttack: 0.015, release: 0.08, threshold: 1.5, sampleRate: sampleRate),
            Band(fastAttack: 0.0002, slowAttack: 0.005, release: 0.04, threshold: 1.5, sampleRate: sampleRate),
        ]
        delayLines = Array(repeating: .zero, count: lookahead * channelCount)
    }

    func process(_ channels: [[Float]]) -> [[Float]] {
        run(channels, frames: channels.first?.count ?? 0)
    }

    func finish() -> [[Float]] {
        run(Array(repeating: [Float](repeating: 0, count: lookahead), count: channelCount), frames: lookahead)
    }

    private func run(_ channels: [[Float]], frames: Int) -> [[Float]] {
        var output = Array(repeating: [Float](), count: channelCount)
        for c in 0..<channelCount { output[c].reserveCapacity(frames) }
        var split = [SIMD3<Float>](repeating: .zero, count: channelCount)
        for i in 0..<frames {
            var levels = SIMD3<Float>.zero
            for c in 0..<channelCount {
                split[c] = splitters[c].split(channels[c][i])
                levels = pointwiseMax(levels, split[c].replacing(with: -split[c], where: split[c] .< 0))
            }
            let gains = SIMD3(
                bands[0].boost(level: levels[0], maximum: maximum),
                bands[1].boost(level: levels[1], maximum: maximum),
                bands[2].boost(level: levels[2], maximum: maximum))
            countAttack(lift: max(gains[0], gains[1]))

            let position = delayPosition
            delayPosition = position + 1 == lookahead ? 0 : position + 1
            let emit = skipped == lookahead
            if !emit { skipped += 1 }
            for c in 0..<channelCount {
                let delayed = delayLines[c * lookahead + position]
                delayLines[c * lookahead + position] = split[c]
                if emit { output[c].append((delayed * gains).sum()) }
            }
        }
        return output
    }

    private func countAttack(lift: Float) {
        sinceAttack += 1
        if lift > 1.41, sinceAttack > refractory {
            attacks += 1
            sinceAttack = 0
        }
    }
}

/// Linkwitz–Riley 4th-order crossovers at 150 Hz and 4 kHz. The three bands sum back to an all-pass: a flat
/// response, only the phase turns around the crossover frequencies.
struct ThreeBandSplitter {
    private var lowPass: (Biquad, Biquad)
    private var lowCut: (Biquad, Biquad)
    private var midPass: (Biquad, Biquad)
    private var highPass: (Biquad, Biquad)
    /// The phase the 4 kHz crossover puts on the upper bands, given to the low band too.
    private var lowAllPass: Biquad

    init(sampleRate: Double) {
        let low = Biquad.butterworth(lowPass: true, frequency: 150, sampleRate: sampleRate)
        let cut = Biquad.butterworth(lowPass: false, frequency: 150, sampleRate: sampleRate)
        let mid = Biquad.butterworth(lowPass: true, frequency: 4_000, sampleRate: sampleRate)
        let high = Biquad.butterworth(lowPass: false, frequency: 4_000, sampleRate: sampleRate)
        (lowPass, lowCut, midPass, highPass) = ((low, low), (cut, cut), (mid, mid), (high, high))
        lowAllPass = Biquad(b0: mid.a2, b1: mid.a1, b2: 1, a1: mid.a1, a2: mid.a2)
    }

    mutating func split(_ x: Float) -> SIMD3<Float> {
        let input = Double(x)
        let low = lowAllPass.process(lowPass.1.process(lowPass.0.process(input)))
        let rest = lowCut.1.process(lowCut.0.process(input))
        let mid = midPass.1.process(midPass.0.process(rest))
        let high = highPass.1.process(highPass.0.process(rest))
        return SIMD3(Float(low), Float(mid), Float(high))
    }
}

extension Biquad {
    /// Second-order Butterworth section (Q = 1/√2), bilinear transform.
    static func butterworth(lowPass: Bool, frequency: Double, sampleRate: Double) -> Biquad {
        let k = tan(.pi * frequency / sampleRate)
        let q = 1 / 2.0.squareRoot()
        let norm = 1 / (1 + k / q + k * k)
        let a1 = 2 * (k * k - 1) * norm
        let a2 = (1 - k / q + k * k) * norm
        return lowPass
            ? Biquad(b0: k * k * norm, b1: 2 * k * k * norm, b2: k * k * norm, a1: a1, a2: a2)
            : Biquad(b0: norm, b1: -2 * norm, b2: norm, a1: a1, a2: a2)
    }
}
