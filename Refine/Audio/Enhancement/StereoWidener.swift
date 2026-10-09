import Foundation

/// « Espace » — reopens a stereo image the encoder narrowed in the highs.
///
/// Above the collapse frequency, the missing Side energy is rebuilt from the Mid signal: each third-octave band
/// gets its own short fixed delay (0.3–3 ms), which decorrelates it from the Mid without smearing attacks, and a
/// gain that brings the Side/Mid ratio back up to the trend measured where the image is intact — never wider.
/// The added Side cancels out in L+R, so the result stays mono-compatible.
struct StereoWidener {
    let profile: StereoProfile
    /// Complex response turning Mid into the added Side component, for `StaticSpectralFilter`.
    let responseReal: [Float]
    let responseImag: [Float]

    /// - Parameter detectionLimit: highest frequency trusted for detecting the collapse (the source's cutoff:
    ///   above it, the Side was rebuilt, not encoded).
    static func make(mid: [Double], side: [Double], binWidth: Double, detectionLimit: Double, amount: Double) -> StereoWidener? {
        let profile = StereoProfile.measure(mid: mid, side: side, binWidth: binWidth, upTo: detectionLimit)
        guard profile.kind == .collapsed, let start = profile.collapseFrequency, amount > 0 else { return nil }

        let bands = ThirdOctaveBand.bands(from: 1_000, to: 22_050).filter { $0.center > start }
        var random = SeededRandom(seed: 0xD1CE)
        let plan = bands.map { band -> (center: Double, gain: Double, delay: Double) in
            let midLevel = band.sum(mid, binWidth: binWidth)
            let sideLevel = band.sum(side, binWidth: binWidth)
            // Above 20 kHz the trend is held, not extended further.
            let targetRatio = pow(10, min(profile.expectedRatio(at: min(band.center, 20_000)), 0) / 10)
            let missing = max(0, midLevel * targetRatio - sideLevel) * amount
            let gain = midLevel > 0 ? min((missing / midLevel).squareRoot(), targetRatio.squareRoot()) : 0
            let delay = 0.000_3 + Double(random.nextUnit()) * 0.002_7
            return (band.center, gain, delay)
        }
        guard let first = plan.first else { return nil }

        var real = [Float](repeating: 0, count: StaticSpectralFilter.size / 2 + 1)
        var imag = real
        for k in real.indices {
            let frequency = StaticSpectralFilter.frequency(ofBin: k)
            guard frequency > start else { continue }
            // Gain interpolated between band centres in log-frequency; delay held per band.
            let upper = plan.firstIndex { $0.center >= frequency } ?? plan.count - 1
            let lower = max(0, upper - 1)
            let span = log2(plan[upper].center / plan[lower].center)
            let t = span > 0 ? min(max(log2(frequency / plan[lower].center) / span, 0), 1) : 0
            let gain = plan[lower].gain + (plan[upper].gain - plan[lower].gain) * t
            let delay = plan[t < 0.5 ? lower : upper].delay
            let fadeIn = raisedCosine((frequency - start) / (first.center - start))
            let phase = -2 * Double.pi * frequency * delay
            real[k] = Float(gain * fadeIn * cos(phase))
            imag[k] = Float(gain * fadeIn * sin(phase))
        }
        return StereoWidener(profile: profile, responseReal: real, responseImag: imag)
    }
}
