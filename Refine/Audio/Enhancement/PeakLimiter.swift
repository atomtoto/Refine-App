import Foundation

/// Transparent look-ahead limiter on true peaks, stereo-linked.
///
/// The gain each oversampled peak requires is held over the look-ahead window, then averaged over the same
/// window: the gain ramps down smoothly *before* the peak arrives and never lets it through. It recovers with
/// an 80 ms release. Output is aligned with the input; the latency is absorbed by `finish()`.
final class PeakLimiter {
    let ceiling: Float
    private let channelCount: Int
    private let lookahead: Int
    private let latency: Int
    private let releaseCoefficient: Float
    private var detectors: [TruePeakDetector]
    private var delayLines: [[Float]]
    private var delayPosition = 0
    /// Monotonic queue of (index, required gain) for the sliding minimum.
    private var queueIndices: [Int] = []
    private var queueGains: [Float] = []
    private var queueHead = 0
    private var averageWindow: [Float]
    private var averageSum: Double
    private var averagePosition = 0
    private var gain: Float = 1
    private var index = 0
    private var skipped = 0
    /// Deepest gain reduction applied, in dB (negative or zero).
    private(set) var deepestReduction: Float = 0

    /// - Parameter ceiling: in dBTP.
    init(ceiling: Double = -1, channelCount: Int, sampleRate: Double = AudioReader.targetSampleRate) {
        self.ceiling = Float(pow(10, ceiling / 20))
        self.channelCount = channelCount
        lookahead = Int(0.005 * sampleRate)
        latency = lookahead + TruePeakDetector.delay
        releaseCoefficient = Float(exp(-1 / (0.08 * sampleRate)))
        detectors = Array(repeating: TruePeakDetector(), count: channelCount)
        delayLines = Array(repeating: Array(repeating: 0, count: latency), count: channelCount)
        averageWindow = Array(repeating: 1, count: lookahead + 1)
        averageSum = Double(lookahead + 1)
    }

    func process(_ channels: [[Float]]) -> [[Float]] {
        run(channels, frames: channels.first?.count ?? 0)
    }

    func finish() -> [[Float]] {
        run(Array(repeating: [Float](repeating: 0, count: latency), count: channelCount), frames: latency)
    }

    private func run(_ channels: [[Float]], frames: Int) -> [[Float]] {
        var output = Array(repeating: [Float](), count: channelCount)
        for c in 0..<channelCount { output[c].reserveCapacity(frames) }
        for i in 0..<frames {
            var peak: Float = 0
            for c in 0..<channelCount {
                peak = max(peak, detectors[c].process(channels[c][i]))
            }
            let gain = nextGain(peak: peak)
            let position = delayPosition
            delayPosition = position + 1 == latency ? 0 : position + 1
            let emit = skipped == latency
            if !emit { skipped += 1 }
            for c in 0..<channelCount {
                let delayed = delayLines[c][position]
                delayLines[c][position] = channels[c][i]
                if emit { output[c].append(delayed * gain) }
            }
        }
        return output
    }

    private func nextGain(peak: Float) -> Float {
        // Gain this sample's peak requires, held over the look-ahead window plus one sample.
        let required = peak > ceiling ? ceiling / peak : 1
        while queueGains.count > queueHead, queueGains[queueGains.count - 1] >= required {
            queueGains.removeLast()
            queueIndices.removeLast()
        }
        queueGains.append(required)
        queueIndices.append(index)
        while queueIndices[queueHead] < index - lookahead - 1 { queueHead += 1 }
        if queueHead > 4_096 {
            queueGains.removeFirst(queueHead)
            queueIndices.removeFirst(queueHead)
            queueHead = 0
        }
        let held = queueGains[queueHead]
        index += 1

        // Averaged over the look-ahead window: a smooth ramp that reaches the held gain as the peak arrives.
        averageSum += Double(held - averageWindow[averagePosition])
        averageWindow[averagePosition] = held
        averagePosition = averagePosition + 1 == averageWindow.count ? 0 : averagePosition + 1
        let target = min(Float(averageSum / Double(averageWindow.count)), 1)
        gain = target < gain ? target : target + (gain - target) * releaseCoefficient
        if gain < 1 { deepestReduction = min(deepestReduction, 20 * log10(max(gain, 1e-6))) }
        return gain
    }
}
