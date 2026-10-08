import Foundation
import Testing
@testable import Refine

struct FFTTests {
    @Test func sinePeaksAtItsBin() {
        let size = 2048
        let fft = RealFFT(size: size)
        let bin = 100
        let signal = (0..<size).map { Float(cos(2 * .pi * Double(bin * $0) / Double(size))) }
        var spectrum = SpectrumFrame(binCount: fft.binCount)
        signal.withUnsafeBufferPointer { fft.forward($0, into: &spectrum) }

        let magnitudes = zip(spectrum.real, spectrum.imag).map { ($0 * $0 + $1 * $1).squareRoot() }
        #expect(magnitudes.indices.max { magnitudes[$0] < magnitudes[$1] } == bin)
        #expect(abs(magnitudes[bin] - Float(size) / 2) < 1)
    }

    @Test func inverseRestoresTheSignal() {
        let fft = RealFFT(size: 1024)
        var random = SeededRandom(seed: 1)
        let signal = (0..<1024).map { _ in random.nextUnit() - 0.5 }
        var spectrum = SpectrumFrame(binCount: fft.binCount)
        signal.withUnsafeBufferPointer { fft.forward($0, into: &spectrum) }
        var back = [Float](repeating: 0, count: 1024)
        back.withUnsafeMutableBufferPointer { fft.inverse(spectrum, into: $0) }

        let error = zip(signal, back).map { abs($0 - $1) }.max() ?? 1
        #expect(error < 1e-5)
    }

    @Test func streamingSTFTIsTransparent() {
        let input = SignalFixtures.whiteNoise(seconds: 0.5)
        let stft = StreamingSTFT()
        // Uneven block sizes exercise the internal buffering.
        var output: [Float] = []
        var offset = 0
        for size in [1000, 333, 7000, 4096] where offset < input.count {
            let end = min(input.count, offset + size)
            output += stft.process(Array(input[offset..<end])) { _ in }
            offset = end
        }
        output += stft.process(Array(input[offset...])) { _ in }
        output += stft.finish { _ in }

        #expect(output.count == input.count)
        let error = zip(input, output).map { abs($0 - $1) }.max() ?? 1
        #expect(error < 1e-4)
    }
}

struct CutoffDetectorTests {
    @Test(arguments: [16_000.0, 17_000.0, 19_000.0])
    func findsAnEncoderLowPass(cutoff: Double) {
        let samples = SignalFixtures.lowPassed(SignalFixtures.whiteNoise(seconds: 3), cutoff: cutoff)
        let analysis = SignalFixtures.analysis(of: samples)
        #expect(abs(analysis.cutoffFrequency - cutoff) < 250)
        #expect(analysis.verdict == .lossy)
        #expect(analysis.estimatedBitrate != nil)
    }

    @Test func fullBandLosslessIsAuthentic() {
        let analysis = SignalFixtures.analysis(of: SignalFixtures.whiteNoise(seconds: 3), codec: .flac)
        #expect(analysis.cutoffFrequency >= CutoffDetector.fullBandFrequency)
        #expect(analysis.verdict == .authenticLossless)
        #expect(analysis.estimatedBitrate == nil)
    }

    @Test func bandLimitedLosslessIsFake() {
        let samples = SignalFixtures.lowPassed(SignalFixtures.whiteNoise(seconds: 3), cutoff: 16_000)
        let analysis = SignalFixtures.analysis(of: samples, codec: .flac)
        #expect(analysis.verdict == .fakeLossless)
        #expect(analysis.estimatedBitrate == 128)
    }

    @Test func pinkishSpectrumHasNegativeSlope() {
        // Integrated noise falls at about 6 dB per octave.
        var state: Float = 0
        let brown = SignalFixtures.whiteNoise(seconds: 3).map { sample -> Float in
            state = state * 0.97 + sample
            return state * 0.2
        }
        let analysis = SignalFixtures.analysis(of: SignalFixtures.lowPassed(brown, cutoff: 16_000))
        #expect(analysis.spectralSlope < -2)
    }
}

struct RestorationTests {
    @Test func bandwidthExtensionFillsTheMissingHighs() {
        let samples = SignalFixtures.lowPassed(SignalFixtures.whiteNoise(seconds: 2), cutoff: 16_000)
        let analysis = SignalFixtures.analysis(of: samples)
        let restorer = SpectralRestorer(
            parameters: .init(analysis: analysis, settings: RestorationSettings()), seed: 7)
        let restored = restorer.process(samples) + restorer.finish()

        #expect(restored.count == samples.count)
        #expect(restored.allSatisfy { $0.isFinite })
        #expect(SignalFixtures.energy(of: samples, above: 17_000) < 1e-6)
        #expect(SignalFixtures.energy(of: restored, above: 17_000) > 1e-3)

        let after = SignalFixtures.analysis(of: restored)
        #expect(after.cutoffFrequency > 19_500)
    }

    @Test func fullBandMaterialIsLeftAlone() {
        let samples = SignalFixtures.whiteNoise(seconds: 1)
        let analysis = SignalFixtures.analysis(of: samples, codec: .flac)
        let restorer = SpectralRestorer(
            parameters: .init(analysis: analysis, settings: RestorationSettings()), seed: 7)
        let restored = restorer.process(samples) + restorer.finish()
        let error = zip(samples, restored).map { abs($0 - $1) }.max() ?? 1
        #expect(error < 1e-4)
    }

    @Test func declipperRebuildsPeaks() {
        let truth = SignalFixtures.sine(frequency: 200, amplitude: 1.4, seconds: 0.1)
        var clipped = truth.map { min(max($0, -1), 1) }
        let before = zip(truth, clipped).map { abs($0 - $1) }.max() ?? 0
        Declipper().process(&clipped)
        let after = zip(truth, clipped).map { abs($0 - $1) }.max() ?? 0

        #expect(clipped.max() ?? 0 > 1.2)
        #expect(after < before * 0.5)
    }

    @Test func conditionerStaysInRangeAndDuplicatesMono() {
        var conditioner = OutputConditioner()
        let output = conditioner.process([[0, 0.5, -0.5, 1.8, -3]])
        #expect(output.count == 2)
        #expect(output[0] == output[1])
        #expect(abs(Int(output[0][1]) - 16_384) <= 2)
        #expect(output[0][3] <= Int16.max && output[0][3] > 32_000)
        #expect(output[0][4] < -32_000)
    }
}
