import Foundation

/// Finds the low-pass "ceiling" lossy encoders leave in a spectrum.
///
/// Lossy encoders discard everything above a fixed frequency (≈16–17 kHz at 128 kbps, ≈20 kHz at 320 kbps),
/// which shows up as a cliff of several tens of dB in the long-term average spectrum. Natural recordings roll
/// off gradually instead.
enum CutoffDetector {
    /// At or above this, a file is considered to cover the full CD band.
    static let fullBandFrequency: Double = 20_800
    /// At or above this, a lossy file's missing highs are barely audible.
    static let transparentFrequency: Double = 19_900

    struct Result: Equatable {
        var cutoff: Double
        /// Spectral tilt below the cutoff, in dB per octave.
        var slope: Double
    }

    static func detect(averagePower: [Double], sampleRate: Double) -> Result {
        let binCount = averagePower.count
        let binWidth = sampleRate / Double((binCount - 1) * 2)
        let nyquist = sampleRate / 2
        func bin(_ frequency: Double) -> Int { min(binCount - 1, max(0, Int(frequency / binWidth))) }

        let decibels = smoothed(averagePower.map { max(10 * log10(max($0, 1e-30)), -200) }, radius: 4)

        // Largest drop between the 400 Hz below and the 400 Hz above each candidate frequency.
        let window = max(4, bin(400))
        let gap = max(1, bin(100))
        let lowest = bin(9_000)
        let highest = min(bin(21_800), binCount - 1 - window)
        var bestBin = highest
        var bestDrop = -Double.infinity
        var bestLevels = (below: 0.0, above: 0.0)
        if lowest < highest {
            for k in lowest...highest {
                let below = mean(decibels[(k - window)..<(k - gap)])
                let above = mean(decibels[(k + gap + 1)...(k + window)])
                if below - above > bestDrop {
                    bestDrop = below - above
                    bestBin = k
                    bestLevels = (below, above)
                }
            }
        }

        let reference = mean(decibels[bin(500)..<bin(4_000)])
        let cutoff: Double
        if bestDrop >= 18 {
            // Snap to the actual edge: the highest bin still above the midpoint of the cliff.
            let midpoint = (bestLevels.below + bestLevels.above) / 2
            let edge = ((bestBin - window)...(bestBin + window)).last { decibels[$0] > midpoint } ?? bestBin
            cutoff = Double(edge) * binWidth
        } else if let edge = (bin(1_000)..<binCount).last(where: { decibels[$0] > reference - 95 }) {
            cutoff = edge >= bin(fullBandFrequency) ? nyquist : Double(edge) * binWidth
        } else {
            cutoff = nyquist
        }

        return Result(cutoff: cutoff, slope: slope(decibels, binWidth: binWidth, upTo: cutoff))
    }

    /// Least-squares fit of level against log2(frequency) over the octave below `cutoff`.
    private static func slope(_ decibels: [Double], binWidth: Double, upTo cutoff: Double) -> Double {
        let lower = max(1, Int(cutoff / 2 / binWidth))
        let upper = min(decibels.count - 1, Int(cutoff * 0.95 / binWidth))
        guard upper - lower > 8 else { return -9 }
        let xs = (lower...upper).map { log2(Double($0) * binWidth) }
        let ys = (lower...upper).map { decibels[$0] }
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        var numerator = 0.0
        var denominator = 0.0
        for (x, y) in zip(xs, ys) {
            numerator += (x - meanX) * (y - meanY)
            denominator += (x - meanX) * (x - meanX)
        }
        guard denominator > 0 else { return -9 }
        return min(max(numerator / denominator, -20), -2)
    }

    private static func smoothed(_ values: [Double], radius: Int) -> [Double] {
        values.indices.map { i in
            mean(values[max(0, i - radius)...min(values.count - 1, i + radius)])
        }
    }

    private static func mean(_ values: ArraySlice<Double>) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}
