import Foundation

/// « Mix » — corrections a mixing engineer would make on the stereo mix itself, without separating the
/// instruments:
///
/// - **Voix** (manual): lifts or lowers what sits in the centre of the image within the voice's band. Lead
///   vocals are mixed centre, so this moves them against the rest; wide instruments barely change.
/// - **Sifflantes et dureté**: a de-esser (4.5–11 kHz) and a dynamic band on 2–5 kHz. Each compares its band
///   with a reference band, frame by frame, and only acts where that ratio jumps well above the song's own
///   usual value: a bright mix stays bright, its spikes are tamed.
/// - **Grave**: the low end is made mono below ≈120 Hz, so bass and kick stop smearing across the image.
///
/// Sibilance has no objective threshold: on well-mixed modern masters, high-band spikes range from 17 to 30 dB
/// above their median depending on the song. So de-essing is offered, off by default, for the listener to judge.
///
/// Gains are the same on both channels, so the stereo image is never skewed.
final class MixEnhancer {
    struct Options: Equatable {
        /// dB, −6…+6. 0 leaves the voice alone.
        var vocalLevel: Double = 0
        var tameSibilance = true
        var tightenBass = true
        /// 0…1.
        var amount: Double = 1
    }

    static let size = 2048
    static let hop = 512

    private struct DynamicBand {
        let band: ClosedRange<Double>
        let reference: ClosedRange<Double>
        /// dB above the song's usual ratio before anything happens.
        let threshold: Double
        let ratio: Double
        let maximum: Double
        var baseline: Double?
        var reduction = 0.0
        var events = 0
    }

    private let options: Options
    private let isStereo: Bool
    private let stft: LinkedSTFT
    private let binWidth: Double
    private let frameSeconds: Double
    private let releaseCoefficient: Double
    /// dB per frame a running median moves: 4 dB per second.
    private let medianStep: Double
    private var sibilance: DynamicBand
    private var harshness: DynamicBand
    /// Per bin: weight of the vocal band, of the sibilance band, of the harshness band, and how mono the low end is.
    private let vocalWeights: [Double]
    private let sibilanceWeights: [Double]
    private let harshnessWeights: [Double]
    private let monoWeights: [Float]
    private var gains: [Float]

    init(options: Options, channelCount: Int, sampleRate: Double = AudioReader.targetSampleRate) {
        self.options = options
        isStereo = channelCount == 2
        stft = LinkedSTFT(size: Self.size, hop: Self.hop, channelCount: channelCount)
        binWidth = sampleRate / Double(Self.size)
        frameSeconds = Double(Self.hop) / sampleRate
        releaseCoefficient = exp(-frameSeconds / 0.08)
        medianStep = 4 * frameSeconds
        sibilance = DynamicBand(band: 4_500...11_000, reference: 800...4_000, threshold: 12, ratio: 0.5, maximum: 6)
        harshness = DynamicBand(band: 2_000...5_000, reference: 250...1_500, threshold: 9, ratio: 0.5, maximum: 4)

        let bins = Self.size / 2 + 1
        let frequencies = (0..<bins).map { Double($0) * sampleRate / Double(Self.size) }
        /// 1 inside `range`, fading to 0 over a third of an octave on each side.
        func plateau(_ f: Double, _ range: ClosedRange<Double>) -> Double {
            guard f > 0 else { return 0 }
            let below = log2(f / range.lowerBound) * 3 + 1
            let above = log2(range.upperBound / f) * 3 + 1
            return raisedCosine(below) * raisedCosine(above)
        }
        vocalWeights = frequencies.map { plateau($0, 180...7_000) }
        sibilanceWeights = frequencies.map { plateau($0, 4_500...11_000) }
        harshnessWeights = frequencies.map { plateau($0, 2_000...5_000) }
        monoWeights = frequencies.map { Float(1 - raisedCosine(($0 - 90) / 70)) }
        gains = Array(repeating: 1, count: bins)
    }

    func process(_ channels: [[Float]]) -> [[Float]] {
        stft.process(channels) { transform(&$0) }
    }

    func finish() -> [[Float]] {
        stft.finish { transform(&$0) }
    }

    /// What the stage did, for the track screen.
    var notes: [String] {
        var notes: [String] = []
        if abs(options.vocalLevel) >= 0.5 {
            notes.append(options.vocalLevel > 0
                ? "Voix avancée de \(options.vocalLevel.decibels)"
                : "Voix reculée de \((-options.vocalLevel).decibels)")
        }
        if sibilance.events > 0 {
            notes.append("\(sibilance.events) sifflante\(sibilance.events > 1 ? "s" : "") adoucie\(sibilance.events > 1 ? "s" : "")")
        }
        if harshness.events > 0 {
            notes.append("Dureté des médiums apaisée sur \(harshness.events) passage\(harshness.events > 1 ? "s" : "")")
        }
        if options.tightenBass, isStereo {
            notes.append("Grave resserré en mono sous 120 Hz")
        }
        return notes
    }

    // MARK: - Per frame

    private func transform(_ spectra: inout [SpectrumFrame]) {
        let bins = gains.count
        let stereo = spectra.count == 2
        var power = [Double](repeating: 0, count: bins)
        var centre = [Double](repeating: 1, count: bins)
        for k in 0..<bins {
            let lr = spectra[0].real[k], li = spectra[0].imag[k]
            let pl = Double(lr * lr + li * li)
            guard stereo else {
                power[k] = pl
                continue
            }
            let rr = spectra[1].real[k], ri = spectra[1].imag[k]
            let pr = Double(rr * rr + ri * ri)
            power[k] = pl + pr
            // Similarity of the two channels in this bin (1 when panned dead centre, 0 when hard-panned).
            let crossReal = Double(lr * rr + li * ri), crossImag = Double(li * rr - lr * ri)
            centre[k] = pl + pr > 0 ? 2 * (crossReal * crossReal + crossImag * crossImag).squareRoot() / (pl + pr) : 0
        }

        // Detection listens to the centre, where the voice is; hi-hats and cymbals spread wide weigh less.
        let centred = (0..<bins).map { power[$0] * centre[$0] * centre[$0] }
        var decibels = [Double](repeating: 0, count: bins)
        if options.vocalLevel != 0 {
            for k in 0..<bins { decibels[k] += options.vocalLevel * vocalWeights[k] * pow(centre[k], 3) }
        }
        if options.tameSibilance {
            let sibilant = update(&sibilance, power: centred)
            let harsh = update(&harshness, power: centred)
            for k in 0..<bins {
                // Sibilance comes from the voice: centred content takes most of the cut.
                decibels[k] -= sibilant * sibilanceWeights[k] * (0.4 + 0.6 * centre[k]) + harsh * harshnessWeights[k]
            }
        }
        if options.tightenBass {
            if stereo {
                // Mono below ≈120 Hz: the Side part of those bins goes.
                for k in 0..<bins where monoWeights[k] > 0 {
                    let m = monoWeights[k] / 2
                    let sideReal = (spectra[0].real[k] - spectra[1].real[k]) * m
                    let sideImag = (spectra[0].imag[k] - spectra[1].imag[k]) * m
                    spectra[0].real[k] -= sideReal
                    spectra[0].imag[k] -= sideImag
                    spectra[1].real[k] += sideReal
                    spectra[1].imag[k] += sideImag
                }
            }
        }

        for k in 0..<bins { gains[k] = Float(pow(10, decibels[k] * options.amount / 20)) }
        for c in spectra.indices {
            for k in 0..<bins {
                spectra[c].real[k] *= gains[k]
                spectra[c].imag[k] *= gains[k]
            }
        }
    }

    private func bandPower(_ power: [Double], _ range: ClosedRange<Double>) -> Double {
        let first = max(1, Int(range.lowerBound / binWidth)), last = min(power.count - 1, Int(range.upperBound / binWidth))
        guard first <= last else { return 0 }
        return power[first...last].reduce(0, +)
    }

    /// Updates a dynamic band for this frame and returns its reduction in dB.
    private func update(_ band: inout DynamicBand, power: [Double]) -> Double {
        let level = bandPower(power, band.band), reference = bandPower(power, band.reference)
        // Quiet frames neither trigger nor teach the baseline.
        guard level + reference > Self.silence else {
            band.reduction *= releaseCoefficient
            return band.reduction
        }
        let ratio = 10 * log10(max(level, 1e-20) / max(reference, 1e-20))
        // Running median: spikes, however large, only nudge it.
        let baseline = band.baseline ?? ratio
        band.baseline = baseline + (ratio > baseline ? medianStep : -medianStep)
        let target = min(max((ratio - baseline - band.threshold) * band.ratio, 0), band.maximum)
        if target > band.reduction {
            if band.reduction < 2, target >= 2 { band.events += 1 }
            band.reduction = target
        } else {
            band.reduction = target + (band.reduction - target) * releaseCoefficient
        }
        return band.reduction
    }

    /// Power of a −60 dBFS signal in this transform's units, summed over a few bins.
    private static let silence: Double = {
        let peak = Double(StreamingSTFT.hannWindow(size: size).reduce(0, +)) / 2
        return peak * peak * 1e-6
    }()
}
