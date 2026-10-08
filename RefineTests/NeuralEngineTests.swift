import AVFoundation
import Testing
@testable import Refine

private struct IdentityModel: SpectralModel {
    let frameCount: Int
    func transform(real: inout [Float], imag: inout [Float]) {}
}

private final class BundleToken {}

struct MatrixSTFTTests {
    @Test func matchesTheFFT() {
        let size = 1024
        let stft = MatrixSTFT(size: size, hop: size / 2)
        let fft = RealFFT(size: size)
        let signal = SignalFixtures.whiteNoise(seconds: 0.1)

        var real: [Float] = []
        var imag: [Float] = []
        signal.withUnsafeBufferPointer { stft.analyze($0, frameCount: 1, real: &real, imag: &imag) }

        let windowed = zip(signal.prefix(size), stft.window).map(*)
        var spectrum = SpectrumFrame(binCount: fft.binCount)
        windowed.withUnsafeBufferPointer { fft.forward($0, into: &spectrum) }

        let error = zip(real, spectrum.real).map { abs($0 - $1) }.max() ?? 1
        let imagError = zip(imag, spectrum.imag).map { abs($0 - $1) }.max() ?? 1
        #expect(error < 1e-3)
        #expect(imagError < 1e-3)
    }

    @Test(arguments: [16, 64])
    func blockProcessorIsTransparent(blockFrames: Int) throws {
        let stft = MatrixSTFT(size: ApolloModel.frameSize, hop: ApolloModel.hop)
        let processor = SpectralBlockProcessor(stft: stft, model: IdentityModel(frameCount: blockFrames), margin: 4)
        let input = SignalFixtures.whiteNoise(seconds: 1.3)

        var output: [Float] = []
        var offset = 0
        for size in [300, 5_000, 17, 20_000] {
            let end = min(input.count, offset + size)
            output += try processor.process(Array(input[offset..<end]))
            offset = end
        }
        output += try processor.process(Array(input[offset...]))
        output += try processor.finish()

        #expect(output.count == input.count)
        let error = zip(input, output).map { abs($0 - $1) }.max() ?? 1
        #expect(error < 1e-3)
    }

    @Test func blockProcessorHandlesVeryShortInput() throws {
        let stft = MatrixSTFT(size: ApolloModel.frameSize, hop: ApolloModel.hop)
        let processor = SpectralBlockProcessor(stft: stft, model: IdentityModel(frameCount: 16), margin: 4)
        let input = SignalFixtures.whiteNoise(seconds: 0.005)
        let output = try processor.process(input) + processor.finish()
        #expect(output.count == input.count)
    }
}

@Suite(.enabled(if: ApolloModel.isBundled))
struct ApolloTests {
    /// Runs the app's Apollo pipeline on a 4 s MP3 excerpt and compares it with the original PyTorch model's
    /// output on the same file (`Tools/ConvertApollo`, `--reference-output`).
    @Test func matchesThePyTorchReference() throws {
        let bundle = Bundle(for: BundleToken.self)
        let probe = try #require(bundle.url(forResource: "apollo-probe", withExtension: "wav"))
        let referenceURL = try #require(bundle.url(forResource: "apollo-reference", withExtension: "wav"))

        var settings = RestorationSettings()
        settings.engine = .apollo
        settings.intensity = 1
        settings.declip = false
        // Compare the network alone: finishing stages are tested separately.
        settings.extendBandwidth = false
        settings.restoreTransients = false
        settings.restoreStereo = false
        settings.exportFormat = .wav
        let analysis = SignalFixtures.analysis(of: [0])
        let destination = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
        let job = RestorationJob(source: probe, destination: destination, analysis: analysis, settings: settings)
        let result = try ApolloRestorationEngine.run(job) { _ in }

        let restored = try readChannels(destination)
        let reference = try readChannels(referenceURL)
        #expect(restored[0].count == reference[0].count)
        for channel in 0..<2 {
            let snr = signalToNoise(reference: reference[channel], estimate: restored[channel])
            print("Apollo channel \(channel): \(snr) dB SNR against PyTorch")
            #expect(snr > 40)
        }
        #expect(result.engine == ApolloRestorationEngine.name)
    }

    private func readChannels(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return (0..<Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength)))
        }
    }

    private func signalToNoise(reference: [Float], estimate: [Float]) -> Double {
        var signal = 0.0, noise = 0.0
        for (r, e) in zip(reference, estimate) {
            signal += Double(r * r)
            noise += Double((r - e) * (r - e))
        }
        return 10 * log10(signal / max(noise, 1e-30))
    }
}
