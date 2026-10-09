import Foundation

/// Second-order IIR section, transposed direct form II, in double precision.
struct Biquad {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1 = 0.0, z2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        (self.b0, self.b1, self.b2, self.a1, self.a2) = (b0, b1, b2, a1, a2)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /// Power gain at `frequency`.
    func powerGain(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * .pi * frequency / sampleRate
        func magnitudeSquared(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
            let re = c0 + c1 * cos(w) + c2 * cos(2 * w)
            let im = -(c1 * sin(w) + c2 * sin(2 * w))
            return re * re + im * im
        }
        return magnitudeSquared(b0, b1, b2) / magnitudeSquared(1, a1, a2)
    }
}

/// Peak level between samples, as a DAC or a lossy encoder will see it: 4× oversampling through a windowed-sinc
/// polyphase filter (ITU-R BS.1770-4, annex 2).
struct TruePeakDetector {
    static let factor = 4
    static let tapsPerPhase = 16
    /// Samples between an input and the oversampled values that describe it.
    static let delay = tapsPerPhase / 2

    private static let phases: [[Float]] = {
        let length = factor * tapsPerPhase
        let centre = Double(length - 1) / 2
        let taps = (0..<length).map { n -> Double in
            let x = (Double(n) - centre) / Double(factor)
            let sinc = x == 0 ? 1 : sin(.pi * x) / (.pi * x)
            let t = Double(n) / Double(length - 1)
            let window = 0.35875 - 0.48829 * cos(2 * .pi * t) + 0.14128 * cos(4 * .pi * t) - 0.01168 * cos(6 * .pi * t)
            return sinc * window
        }
        return (0..<factor).map { phase in
            let coefficients = stride(from: phase, to: length, by: factor).map { taps[$0] }
            let sum = coefficients.reduce(0, +)
            return coefficients.map { Float($0 / sum) }
        }
    }()

    private var history = [Float](repeating: 0, count: tapsPerPhase)
    private var position = 0

    /// Largest oversampled magnitude around the sample `delay` steps back.
    mutating func process(_ x: Float) -> Float {
        history[position] = x
        position = (position + 1) % Self.tapsPerPhase
        var peak: Float = 0
        for phase in Self.phases {
            var sum: Float = 0
            var index = position
            for coefficient in phase {
                index = index == 0 ? Self.tapsPerPhase - 1 : index - 1
                sum += coefficient * history[index]
            }
            peak = max(peak, abs(sum))
        }
        return peak
    }
}

/// Programme loudness after ITU-R BS.1770-4 / EBU R 128 (K-weighting, 400 ms blocks every 100 ms, absolute and
/// relative gates), true peak, and a measure of punch.
///
/// Mono counts as dual mono, the way it will be played and the way Refine exports it, so a file and its
/// restoration compare on the same scale.
final class LoudnessMeter {
    let sampleRate: Double
    private var weighting: [[Biquad]] = []
    private var detectors: [TruePeakDetector] = []
    private let subBlockLength: Int
    private var fill = 0
    private var weightedSum = 0.0
    private var plainSum = 0.0
    private var subBlockPeak: Float = 0
    private var recent: [(weighted: Double, plain: Double, peak: Float)] = []
    private var blocks: [(power: Double, crest: Double)] = []
    private var truePeak: Float = 0

    init(sampleRate: Double = AudioReader.targetSampleRate) {
        self.sampleRate = sampleRate
        subBlockLength = Int(sampleRate / 10)
    }

    /// The two K-weighting stages for this sample rate: a +4 dB shelf above ≈1.7 kHz, then a high-pass at 38 Hz.
    static func kWeighting(sampleRate: Double) -> [Biquad] {
        let shelfK = tan(.pi * 1_681.974450955533 / sampleRate)
        let shelfQ = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + shelfK / shelfQ + shelfK * shelfK
        let shelf = Biquad(
            b0: (vh + vb * shelfK / shelfQ + shelfK * shelfK) / a0,
            b1: 2 * (shelfK * shelfK - vh) / a0,
            b2: (vh - vb * shelfK / shelfQ + shelfK * shelfK) / a0,
            a1: 2 * (shelfK * shelfK - 1) / a0,
            a2: (1 - shelfK / shelfQ + shelfK * shelfK) / a0)

        let passK = tan(.pi * 38.13547087602444 / sampleRate)
        let passQ = 0.5003270373238773
        let p0 = 1 + passK / passQ + passK * passK
        let highPass = Biquad(
            b0: 1, b1: -2, b2: 1,
            a1: 2 * (passK * passK - 1) / p0,
            a2: (1 - passK / passQ + passK * passK) / p0)
        return [shelf, highPass]
    }

    /// Power gain of the K-weighting at `frequency`.
    static func kWeightingGain(at frequency: Double, sampleRate: Double = AudioReader.targetSampleRate) -> Double {
        kWeighting(sampleRate: sampleRate).reduce(1) { $0 * $1.powerGain(at: frequency, sampleRate: sampleRate) }
    }

    func consume(_ channels: [[Float]]) {
        guard let frames = channels.first?.count, frames > 0 else { return }
        if weighting.count != channels.count {
            weighting = channels.map { _ in Self.kWeighting(sampleRate: sampleRate) }
            detectors = channels.map { _ in TruePeakDetector() }
        }
        let channelWeight = channels.count == 1 ? 2.0 : 1.0
        for i in 0..<frames {
            for c in channels.indices {
                let x = channels[c][i]
                var y = Double(x)
                for stage in weighting[c].indices { y = weighting[c][stage].process(y) }
                weightedSum += y * y * channelWeight
                plainSum += Double(x * x) / Double(channels.count)
                subBlockPeak = max(subBlockPeak, abs(x))
                truePeak = max(truePeak, detectors[c].process(x))
            }
            fill += 1
            if fill == subBlockLength { closeSubBlock() }
        }
    }

    private func closeSubBlock() {
        recent.append((weightedSum, plainSum, subBlockPeak))
        if recent.count > 4 { recent.removeFirst() }
        (fill, weightedSum, plainSum, subBlockPeak) = (0, 0, 0, 0)
        guard recent.count == 4 else { return }
        let length = Double(4 * subBlockLength)
        let power = recent.reduce(0) { $0 + $1.weighted } / length
        let meanSquare = recent.reduce(0) { $0 + $1.plain } / length
        let peak = recent.map(\.peak).max() ?? 0
        let crest = meanSquare > 0 && peak > 0 ? 20 * log10(Double(peak)) - 10 * log10(meanSquare) : 0
        blocks.append((power, crest))
    }

    static func loudness(ofPower power: Double) -> Double {
        -0.691 + 10 * log10(max(power, 1e-30))
    }

    /// Gated programme loudness, in LUFS.
    var integrated: Double {
        let absolute = blocks.filter { Self.loudness(ofPower: $0.power) > -70 }
        guard !absolute.isEmpty else { return -70 }
        let threshold = Self.loudness(ofPower: absolute.reduce(0) { $0 + $1.power } / Double(absolute.count)) - 10
        let gated = absolute.filter { Self.loudness(ofPower: $0.power) > threshold }
        guard !gated.isEmpty else { return -70 }
        return Self.loudness(ofPower: gated.reduce(0) { $0 + $1.power } / Double(gated.count))
    }

    var profile: LoudnessProfile {
        let loudness = integrated
        let loud = blocks.filter { Self.loudness(ofPower: $0.power) > loudness - 10 }.map(\.crest).sorted()
        let crest = loud.isEmpty ? 0 : loud[loud.count / 2]
        return LoudnessProfile(
            integrated: loudness,
            truePeak: 20 * log10(max(Double(truePeak), 1e-6)),
            crest: crest)
    }
}

/// How loud a file is and how much life its peaks still have.
///
/// Crest is the peak-to-RMS ratio of 400 ms blocks, the median over the loud passages: 10–12 dB for a typical
/// modern master, under 9.5 for one limited flat, 14 dB and more for a dynamic one.
struct LoudnessProfile: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Limited so hard that the drums have lost their attack.
        case squashed
        case natural
        /// Mastered low, with headroom left unused.
        case weak
    }

    /// Programme loudness, LUFS.
    var integrated: Double
    /// dBTP.
    var truePeak: Double
    /// dB.
    var crest: Double

    static let squashedCrest: Double = 9.5
    /// Quiet files with a low crest are sustained, not limited.
    static let squashedLoudness: Double = -13
    static let weakLoudness: Double = -20
    /// Loudness Refine aims for when it raises a quiet master (Spotify, YouTube).
    static let targetLoudness: Double = -14

    var kind: Kind {
        if crest < Self.squashedCrest && integrated > Self.squashedLoudness { return .squashed }
        if integrated < Self.weakLoudness { return .weak }
        return .natural
    }
}
