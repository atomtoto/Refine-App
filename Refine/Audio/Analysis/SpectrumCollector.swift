import CoreGraphics

/// Accumulates the long-term average spectrum and a time × frequency grid of a mono stream.
final class SpectrumCollector {
    static let fftSize = 4096

    let sampleRate: Double
    let columns: Int
    let rows: Int

    private let framer = SpectralFramer(size: fftSize, hop: fftSize / 2)
    private let expectedSamples: Int
    private var powerSum: [Double]
    private var frameCount = 0
    private var grid: [Float]
    private var gridCounts: [Int]
    private(set) var processedSamples = 0

    init(sampleRate: Double, expectedSamples: Int, columns: Int = 720, rows: Int = 256) {
        self.sampleRate = sampleRate
        self.expectedSamples = max(expectedSamples, Self.fftSize)
        // Never more columns than frames, or short files get empty stripes.
        self.columns = min(columns, max(32, self.expectedSamples / (Self.fftSize / 2)))
        self.rows = rows
        powerSum = .init(repeating: 0, count: Self.fftSize / 2 + 1)
        grid = .init(repeating: 0, count: self.columns * rows)
        gridCounts = .init(repeating: 0, count: self.columns)
    }

    var binCount: Int { Self.fftSize / 2 + 1 }
    var binWidth: Double { sampleRate / Double(Self.fftSize) }

    /// Mean power per bin across the whole stream, relative to a full-scale sine.
    var averagePower: [Double] {
        let scale = 1 / (Double(max(frameCount, 1)) * Double(framer.referencePower))
        return powerSum.map { $0 * scale }
    }

    func consume(_ mono: [Float]) {
        processedSamples += mono.count
        let bins = binCount
        let binsPerRow = Double(bins) / Double(rows)
        framer.consume(mono) { power, position in
            frameCount += 1
            for k in 0..<bins { powerSum[k] += Double(power[k]) }

            let column = min(columns - 1, position * columns / expectedSamples)
            gridCounts[column] += 1
            let base = column * rows
            grid.withUnsafeMutableBufferPointer { grid in
                for row in 0..<rows {
                    let lower = Int(Double(row) * binsPerRow)
                    let upper = max(lower + 1, Int(Double(row + 1) * binsPerRow))
                    var sum: Float = 0
                    for k in lower..<min(upper, bins) { sum += power[k] }
                    grid[base + row] += sum / Float(upper - lower)
                }
            }
        }
    }

    /// Spectrogram with high frequencies at the top. Columns not reached yet are transparent.
    func makeImage() -> CGImage? {
        let reference = framer.referencePower
        let levels = (0..<columns).map { column -> [Float]? in
            let count = gridCounts[column]
            guard count > 0 else { return nil }
            let base = column * rows
            return (0..<rows).map { grid[base + $0] / (Float(count) * reference) }
        }
        return SpectrogramRenderer.image(columns: levels, rows: rows)
    }
}

/// Peak and clipping statistics.
struct LevelStatistics {
    static let clipThreshold: Float = 0.985

    private(set) var peak: Float = 0
    private(set) var clippedSamples = 0
    private(set) var totalSamples = 0

    var clippingRatio: Double { totalSamples > 0 ? Double(clippedSamples) / Double(totalSamples) : 0 }

    /// Counts samples in plateaus of at least three consecutive near-full-scale samples.
    mutating func consume(_ channels: [[Float]]) {
        for channel in channels {
            totalSamples += channel.count
            var run = 0
            for sample in channel {
                let magnitude = abs(sample)
                peak = max(peak, magnitude)
                if magnitude >= Self.clipThreshold {
                    run += 1
                } else {
                    if run >= 3 { clippedSamples += run }
                    run = 0
                }
            }
            if run >= 3 { clippedSamples += run }
        }
    }
}
