import Foundation

/// « Brillance » — brings the band rebuilt above the encoder's cutoff up to the level the rest of the spectrum
/// predicts.
///
/// Reconstruction (by Apollo or by band replication) tends to leave the new highs well below a natural level:
/// they're there on a spectrogram but barely audible. The target continues the spectral slope measured in the
/// octave below the cutoff, 1.5 dB/octave steeper to stay on the safe side, and rolls off like a CD master's
/// anti-alias filter towards 21 kHz. Only boosts, capped at +15 dB, scaled by the restoration intensity.
struct AirEqualizer {
    static let maximumBoost: Double = 15
    static let extraRolloff: Double = 1.5

    /// Linear gains for `StaticSpectralFilter`.
    let gains: [Float]
    /// Mean boost between the cutoff and 20 kHz, in dB.
    let averageBoost: Double

    /// - Parameters:
    ///   - averagePower: long-term power spectrum of the restored signal, any FFT size.
    ///   - cutoff: the source file's cutoff, where the rebuilt band starts.
    ///   - correction: equalisation applied alongside, in dB: the target extends the *corrected* slope, or a
    ///     dull mix would stay dull above its cutoff.
    static func make(
        averagePower: [Double], binWidth: Double, cutoff: Double, amount: Double,
        correction: (Double) -> Double = { _ in 0 }
    ) -> AirEqualizer? {
        guard cutoff < CutoffDetector.transparentFrequency, averagePower.count > 16, amount > 0 else { return nil }

        let raw = averagePower.indices.map { k in
            max(10 * log10(max(averagePower[k], 1e-30)), -200) + correction(Double(k) * binWidth)
        }
        let slope = CutoffDetector.slope(CutoffDetector.smoothed(raw, radius: 4), binWidth: binWidth, upTo: cutoff)
        let measured = smoothedByOctaveFraction(raw, binWidth: binWidth, fraction: 12)

        let anchorFrequency = 0.9 * cutoff
        let anchorBins = Int(0.85 * cutoff / binWidth)...Int(0.95 * cutoff / binWidth)
        let anchorLevel = anchorBins.map { measured[min($0, measured.count - 1)] }.reduce(0, +) / Double(anchorBins.count)

        func target(at frequency: Double) -> Double {
            let rolloff = 40 * raisedCosine((frequency - 20_500) / 1_000)
            return anchorLevel + (slope - extraRolloff) * log2(frequency / anchorFrequency) - rolloff
        }

        var gains = StaticSpectralFilter.identityGains
        var boosts: [Double] = []
        let fadeStart = 0.95 * cutoff
        for k in gains.indices {
            let frequency = StaticSpectralFilter.frequency(ofBin: k)
            guard frequency > fadeStart else { continue }
            let source = min(measured.count - 1, Int((frequency / binWidth).rounded()))
            let deficit = min(max(target(at: frequency) - measured[source], 0), maximumBoost)
            let boost = deficit * amount * raisedCosine((frequency - fadeStart) / (cutoff - fadeStart))
            gains[k] = Float(pow(10, boost / 20))
            if frequency >= cutoff && frequency <= 20_000 { boosts.append(boost) }
        }
        let average = boosts.isEmpty ? 0 : boosts.reduce(0, +) / Double(boosts.count)
        return AirEqualizer(gains: gains, averageBoost: average)
    }

    /// Mean over `1/fraction` of an octave around each bin, the way the ear groups frequencies.
    static func smoothedByOctaveFraction(_ values: [Double], binWidth: Double, fraction: Double) -> [Double] {
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for (i, value) in values.enumerated() { prefix[i + 1] = prefix[i] + value }
        let half = pow(2, 1 / (2 * fraction))
        return values.indices.map { k in
            let lower = max(0, Int(Double(k) / half))
            let upper = min(values.count - 1, max(lower, Int((Double(k) * half).rounded(.up))))
            return (prefix[upper + 1] - prefix[lower]) / Double(upper - lower + 1)
        }
    }
}
