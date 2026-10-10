import Foundation
import Testing
@testable import Refine

private let sampleRate = SignalFixtures.sampleRate

private func power(_ samples: ArraySlice<Float>, from lower: Double, to upper: Double) -> Double {
    let collector = SpectrumCollector(sampleRate: sampleRate, expectedSamples: samples.count)
    collector.consume(Array(samples))
    let spectrum = collector.averagePower
    let first = max(1, Int(lower / collector.binWidth)), last = min(spectrum.count - 1, Int(upper / collector.binWidth))
    return spectrum[first...last].reduce(0, +)
}

private func change(_ before: Double, _ after: Double) -> Double { 10 * log10(max(after, 1e-30) / max(before, 1e-30)) }

/// White noise kept between `lower` and `upper` Hz.
private func bandNoise(seconds: Double, from lower: Double, to upper: Double, amplitude: Float, seed: UInt64) -> [Float] {
    let stft = StreamingSTFT()
    let binWidth = sampleRate / Double(stft.size)
    let transform: (inout SpectrumFrame) -> Void = { frame in
        for k in frame.real.indices where !(lower...upper).contains(Double(k) * binWidth) {
            frame.real[k] = 0
            frame.imag[k] = 0
        }
    }
    let white = SignalFixtures.whiteNoise(seconds: seconds, amplitude: amplitude, seed: seed)
    return stft.process(white, transform: transform) + stft.finish(transform: transform)
}

private func sine(_ frequency: Double, amplitude: Float, count: Int) -> [Float] {
    (0..<count).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
}

private func run(_ input: [[Float]], _ options: MixEnhancer.Options) -> (output: [[Float]], enhancer: MixEnhancer) {
    let enhancer = MixEnhancer(options: options, channelCount: input.count)
    let output = zip(enhancer.process(input), enhancer.finish()).map { $0 + $1 }
    return (output, enhancer)
}

private func options(vocal: Double = 0, sibilance: Bool = false, bass: Bool = false) -> MixEnhancer.Options {
    MixEnhancer.Options(vocalLevel: vocal, tameSibilance: sibilance, tightenBass: bass, amount: 1)
}

struct LinkedSTFTTests {
    @Test func isTransparentAcrossChannels() {
        let left = SignalFixtures.whiteNoise(seconds: 1, seed: 1), right = SignalFixtures.whiteNoise(seconds: 1, seed: 2)
        let stft = LinkedSTFT(channelCount: 2)
        var output = stft.process([Array(left[..<7_000]), Array(right[..<7_000])]) { _ in }
        let rest = stft.process([Array(left[7_000...]), Array(right[7_000...])]) { _ in }
        let tail = stft.finish { _ in }
        output = (0..<2).map { output[$0] + rest[$0] + tail[$0] }
        #expect(output[0].count == left.count)
        #expect(zip(output[0], left).allSatisfy { abs($0 - $1) < 1e-4 })
        #expect(zip(output[1], right).allSatisfy { abs($0 - $1) < 1e-4 })
    }
}

struct MixEnhancerTests {
    @Test func liftsTheCentreAndLeavesTheSidesAlone() {
        let count = Int(3 * sampleRate)
        let centre = sine(1_000, amplitude: 0.2, count: count)
        let leftOnly = sine(1_600, amplitude: 0.2, count: count)
        let input = [zip(centre, leftOnly).map(+), centre]
        let output = run(input, options(vocal: 6)).output
        let steady = Int(sampleRate)..<count
        let centreGain = change(power(input[1][steady], from: 950, to: 1_050), power(output[1][steady], from: 950, to: 1_050))
        let sideGain = change(power(input[0][steady], from: 1_550, to: 1_650), power(output[0][steady], from: 1_550, to: 1_650))
        #expect(centreGain > 5 && centreGain < 6.5)
        #expect(abs(sideGain) < 1)
    }

    @Test func softensSibilantBurstsOnly() {
        let seconds = 8.0, count = Int(seconds * sampleRate)
        // A voice-like body, a faint steady hiss, and loud « s » every second.
        let body = bandNoise(seconds: seconds, from: 300, to: 3_500, amplitude: 0.5, seed: 3)
        let hiss = bandNoise(seconds: seconds, from: 5_000, to: 10_000, amplitude: 0.03, seed: 4)
        let bursts = bandNoise(seconds: seconds, from: 5_000, to: 10_000, amplitude: 0.6, seed: 5)
        let burstLength = Int(0.12 * sampleRate)
        let isBurst: (Int) -> Bool = { $0 % Int(sampleRate) >= Int(0.5 * sampleRate) && $0 % Int(sampleRate) < Int(0.5 * sampleRate) + burstLength }
        let mono = (0..<count).map { body[$0] + hiss[$0] + (isBurst($0) ? bursts[$0] : 0) }
        let (output, enhancer) = run([mono, mono], options(sibilance: true))

        // Bursts after the first few seconds, once the song's usual balance is known.
        let burst = (4 * Int(sampleRate) + Int(0.5 * sampleRate))..<(4 * Int(sampleRate) + Int(0.5 * sampleRate) + burstLength)
        let calm = (5 * Int(sampleRate) + Int(0.1 * sampleRate))..<(5 * Int(sampleRate) + Int(0.4 * sampleRate))
        let burstChange = change(power(mono[burst], from: 5_000, to: 10_000), power(output[0][burst], from: 5_000, to: 10_000))
        let calmChange = change(power(mono[calm], from: 300, to: 10_000), power(output[0][calm], from: 300, to: 10_000))
        print("De-esser: bursts \(burstChange) dB, calm \(calmChange) dB, \(enhancer.notes)")
        #expect(burstChange < -4)
        #expect(abs(calmChange) < 0.5)
    }

    @Test func leavesKicksAlone() {
        let count = Int(6 * sampleRate)
        var kicks = [Float](repeating: 0, count: count)
        for start in stride(from: 0, to: count, by: Int(0.5 * sampleRate)) {
            for i in 0..<min(Int(0.25 * sampleRate), count - start) {
                let t = Double(i) / sampleRate
                kicks[start + i] = Float(0.8 * sin(2 * .pi * (45 + 150 * exp(-t / 0.02)) * t) * exp(-t / 0.09))
            }
        }
        let (output, _) = run([kicks, kicks], options(bass: true))
        let late = Int(3 * sampleRate)..<count
        let peakBefore = kicks[late].map(abs).max() ?? 1, peakAfter = output[0][late].map(abs).max() ?? 1
        #expect(abs(20 * log10(Double(peakAfter / peakBefore))) < 1)
    }

    @Test func makesTheLowEndMono() {
        let seconds = 3.0
        let lowLeft = bandNoise(seconds: seconds, from: 30, to: 80, amplitude: 0.5, seed: 6)
        let lowRight = bandNoise(seconds: seconds, from: 30, to: 80, amplitude: 0.5, seed: 7)
        let highLeft = bandNoise(seconds: seconds, from: 500, to: 4_000, amplitude: 0.3, seed: 8)
        let highRight = bandNoise(seconds: seconds, from: 500, to: 4_000, amplitude: 0.3, seed: 9)
        let input = [zip(lowLeft, highLeft).map(+), zip(lowRight, highRight).map(+)]
        let output = run(input, options(bass: true)).output
        func side(_ channels: [[Float]]) -> [Float] { zip(channels[0], channels[1]).map { ($0 - $1) / 2 } }
        let steady = Int(sampleRate)..<input[0].count
        let lowSide = change(power(side(input)[steady], from: 30, to: 80), power(side(output)[steady], from: 30, to: 80))
        let highSide = change(power(side(input)[steady], from: 500, to: 4_000), power(side(output)[steady], from: 500, to: 4_000))
        #expect(lowSide < -20)
        #expect(abs(highSide) < 0.5)
    }

    @Test func leavesSteadyMusicAlone() {
        let seconds = 5.0
        let left = bandNoise(seconds: seconds, from: 40, to: 16_000, amplitude: 0.3, seed: 10)
        let right = bandNoise(seconds: seconds, from: 40, to: 16_000, amplitude: 0.3, seed: 11)
        let output = run([left, right], options(sibilance: true)).output
        let steady = Int(2 * sampleRate)..<left.count
        for (lower, upper) in [(200.0, 2_000.0), (2_000.0, 5_000.0), (5_000.0, 11_000.0)] {
            #expect(abs(change(power(left[steady], from: lower, to: upper), power(output[0][steady], from: lower, to: upper))) < 0.5)
        }
    }
}
