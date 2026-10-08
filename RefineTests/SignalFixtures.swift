import Foundation
@testable import Refine

enum SignalFixtures {
    static let sampleRate = 44_100.0

    static func whiteNoise(seconds: Double, amplitude: Float = 0.25, seed: UInt64 = 42) -> [Float] {
        var random = SeededRandom(seed: seed)
        return (0..<Int(seconds * sampleRate)).map { _ in (random.nextUnit() * 2 - 1) * amplitude }
    }

    static func sine(frequency: Double, amplitude: Float, seconds: Double) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    /// Brick-wall low-pass through the STFT, like an MP3 encoder's band limit.
    static func lowPassed(_ samples: [Float], cutoff: Double) -> [Float] {
        let stft = StreamingSTFT()
        let cutoffBin = Int(cutoff / (sampleRate / Double(stft.size)))
        let zeroAbove: (inout SpectrumFrame) -> Void = { frame in
            for k in cutoffBin..<frame.real.count {
                frame.real[k] = 0
                frame.imag[k] = 0
            }
        }
        return stft.process(samples, transform: zeroAbove) + stft.finish(transform: zeroAbove)
    }

    static func analysis(of samples: [Float], codec: AudioCodec = .mp3) -> AudioAnalysis {
        let collector = SpectrumCollector(sampleRate: sampleRate, expectedSamples: samples.count)
        var levels = LevelStatistics()
        levels.consume([samples])
        collector.consume(samples)
        return AudioAnalyzer.makeAnalysis(
            collector: collector, levels: levels, codec: codec, sourceSampleRate: sampleRate, channelCount: 1)
    }

    /// Energy share above `frequency`, from the long-term spectrum.
    static func energy(of samples: [Float], above frequency: Double) -> Double {
        let collector = SpectrumCollector(sampleRate: sampleRate, expectedSamples: samples.count)
        collector.consume(samples)
        let power = collector.averagePower
        let firstBin = Int(frequency / collector.binWidth)
        return power[firstBin...].reduce(0, +) / max(power.reduce(0, +), 1e-30)
    }
}
