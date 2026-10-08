import Foundation

/// Per-channel spectral repair: fills quantisation holes below the cutoff, then rebuilds the missing band above
/// it by spectral band replication (SBR).
///
/// SBR copies the octave-ish just below the cutoff upward, frame by frame, so the new highs inherit the rhythm
/// and transients of the music. The copy is shaped to continue the measured spectral tilt and faded in around the
/// cutoff. Shifts are multiples of `size / hop` bins, which keeps the phase advance between frames coherent.
final class SpectralRestorer {
    struct Parameters: Sendable {
        var sampleRate: Double
        var cutoff: Double
        /// dB per octave.
        var slope: Double
        var intensity: Double
        var extendBandwidth: Bool
        var fillHoles: Bool

        /// Where the rebuilt band stops, mimicking a CD master's anti-alias roll-off.
        static let targetTop: Double = 20_800

        init(analysis: AudioAnalysis, settings: RestorationSettings, sampleRate: Double = AudioReader.targetSampleRate) {
            self.sampleRate = sampleRate
            cutoff = analysis.cutoffFrequency
            slope = analysis.spectralSlope
            intensity = min(max(settings.intensity, 0.1), 1)
            extendBandwidth = settings.extendBandwidth && analysis.hasMissingHighs
            fillHoles = settings.fillSpectralHoles && analysis.hasMissingHighs
        }

        init(sampleRate: Double, cutoff: Double, slope: Double, intensity: Double, extendBandwidth: Bool, fillHoles: Bool) {
            self.sampleRate = sampleRate
            self.cutoff = cutoff
            self.slope = slope
            self.intensity = intensity
            self.extendBandwidth = extendBandwidth
            self.fillHoles = fillHoles
        }
    }

    private let stft = StreamingSTFT(size: 2048, hop: 512)
    private let parameters: Parameters
    private var random: SeededRandom

    // Precomputed per-bin plan.
    private let cutoffBin: Int
    private let topBin: Int
    private let shift: Int
    private let synthesisGain: [Float]
    private let firstSynthesisBin: Int
    private let holeRange: Range<Int>
    private var sourceReal: [Float]
    private var sourceImag: [Float]
    private var magnitude: [Float]
    private var prefix: [Float]

    init(parameters: Parameters, seed: UInt64) {
        self.parameters = parameters
        random = SeededRandom(seed: seed)

        let binCount = stft.size / 2 + 1
        let binWidth = parameters.sampleRate / Double(stft.size)
        let nyquistBin = binCount - 1
        cutoffBin = min(nyquistBin, Int(parameters.cutoff / binWidth))
        topBin = min(nyquistBin - 4, Int(min(Parameters.targetTop, parameters.sampleRate / 2 * 0.96) / binWidth))

        // Shift by the width of the gap, but never borrow from below half the cutoff.
        let coherence = stft.size / stft.hop
        let width = max(coherence, min(topBin - cutoffBin, cutoffBin / 2))
        shift = (width + coherence - 1) / coherence * coherence

        let fadeBins = max(2, Int(250 / binWidth))
        var gains = [Float](repeating: 0, count: binCount)
        if parameters.extendBandwidth, topBin > cutoffBin + fadeBins {
            let levelOffset = (parameters.intensity - 1) * 12 - 1.5
            let topFadeStart = Double(topBin) - Double(topBin - cutoffBin) * 0.25
            for k in max(1, cutoffBin - fadeBins)..<topBin {
                let patch = k < cutoffBin ? 1 : (k - cutoffBin) / shift + 1
                let source = k - patch * shift
                guard source > 0 else { continue }
                let tilt = parameters.slope * log2(Double(k) / Double(source))
                let fadeIn = Self.raisedCosine((Double(k - cutoffBin + fadeBins)) / Double(2 * fadeBins))
                let fadeOut = 1 - Self.raisedCosine((Double(k) - topFadeStart) / (Double(topBin) - topFadeStart))
                gains[k] = Float(pow(10, (tilt + levelOffset) / 20) * fadeIn * fadeOut)
            }
        }
        synthesisGain = gains
        firstSynthesisBin = gains.firstIndex { $0 > 0 } ?? topBin

        let holeStart = max(Int(6_000 / binWidth), cutoffBin * 45 / 100)
        holeRange = parameters.fillHoles && holeStart < cutoffBin ? holeStart..<cutoffBin : 0..<0

        sourceReal = .init(repeating: 0, count: binCount)
        sourceImag = .init(repeating: 0, count: binCount)
        magnitude = .init(repeating: 0, count: binCount)
        prefix = .init(repeating: 0, count: binCount + 1)
    }

    func process(_ samples: [Float]) -> [Float] {
        stft.process(samples) { transform(&$0) }
    }

    func finish() -> [Float] {
        stft.finish { transform(&$0) }
    }

    private func transform(_ frame: inout SpectrumFrame) {
        if !holeRange.isEmpty { fillHoles(&frame) }
        if parameters.extendBandwidth { extendBandwidth(&frame) }
    }

    /// Adds low-level noise where the encoder zeroed coefficients the local envelope says should be there.
    private func fillHoles(_ frame: inout SpectrumFrame) {
        let radius = 12
        let count = magnitude.count
        for k in 0..<count {
            magnitude[k] = (frame.real[k] * frame.real[k] + frame.imag[k] * frame.imag[k]).squareRoot()
            prefix[k + 1] = prefix[k] + magnitude[k]
        }
        let amount = Float(parameters.intensity) * 0.6
        for k in holeRange {
            let lower = max(0, k - radius), upper = min(count, k + radius + 1)
            let envelope = (prefix[upper] - prefix[lower]) / Float(upper - lower)
            let floor = envelope * 0.12
            guard magnitude[k] < floor else { continue }
            let added = (floor - magnitude[k]) * amount
            let phase = random.nextUnit() * 2 * .pi
            frame.real[k] += added * cos(phase)
            frame.imag[k] += added * sin(phase)
        }
    }

    /// Replicates the band below the cutoff into the empty band above it.
    private func extendBandwidth(_ frame: inout SpectrumFrame) {
        let noiseMix: Float = 0.25
        guard firstSynthesisBin < topBin else { return }
        // Read from an untouched copy: the fade-in region overlaps the source band.
        for k in 0..<cutoffBin {
            sourceReal[k] = frame.real[k]
            sourceImag[k] = frame.imag[k]
        }
        for k in firstSynthesisBin..<topBin {
            let gain = synthesisGain[k]
            guard gain > 0 else { continue }
            let patch = k < cutoffBin ? 1 : (k - cutoffBin) / shift + 1
            let source = k - patch * shift
            let re = sourceReal[source] * gain
            let im = sourceImag[source] * gain
            let noise: Float = (re * re + im * im).squareRoot() * noiseMix
            let phase: Float = random.nextUnit() * 2 * .pi
            let coherent: Float = 1 - noiseMix
            frame.real[k] += re * coherent + noise * cos(phase)
            frame.imag[k] += im * coherent + noise * sin(phase)
        }
    }

    private static func raisedCosine(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return 0.5 - 0.5 * cos(.pi * clamped)
    }
}
