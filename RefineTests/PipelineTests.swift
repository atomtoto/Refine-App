import AVFoundation
import Testing
@testable import Refine

struct PipelineTests {
    private func temporaryURL(_ ext: String) -> URL {
        URL.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
    }

    /// Writes a band-limited float WAV, standing in for a decoded MP3.
    private func makeBandLimitedFile(sampleRate: Double = 44_100) throws -> URL {
        let url = temporaryURL("wav")
        let samples = SignalFixtures.lowPassed(SignalFixtures.whiteNoise(seconds: 2), cutoff: 16_000)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<2 {
            samples.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: samples.count) }
        }
        try file.write(from: buffer)
        file.close()
        return url
    }

    @Test func analyzerReadsAFile() async throws {
        let url = try makeBandLimitedFile()
        let output = try await AudioAnalyzer.analyze(url: url)
        #expect(abs(output.analysis.cutoffFrequency - 16_000) < 250)
        #expect(output.analysis.channelCount == 2)
        #expect(abs(output.analysis.duration - 2) < 0.05)
        #expect(output.spectrogramPNG != nil)
    }

    @Test(arguments: [RestorationSettings.ExportFormat.alac, .aac, .wav])
    func restoresToCDFormat(format: RestorationSettings.ExportFormat) async throws {
        let source = try makeBandLimitedFile(sampleRate: 48_000)
        let destination = temporaryURL(format.fileExtension)
        let analysis = try await AudioAnalyzer.analyze(url: source).analysis
        var settings = RestorationSettings()
        settings.exportFormat = format

        var fractions: [Double] = []
        var output: RestorationOutput?
        let job = RestorationJob(source: source, destination: destination, analysis: analysis, settings: settings)
        for try await event in DSPRestorationEngine().restore(job) {
            switch event {
            case .progress(let fraction, _): fractions.append(fraction)
            case .finished(let result): output = result
            }
        }

        let sourceFile = try AVAudioFile(forReading: source)
        let sourceDuration = Double(sourceFile.length) / sourceFile.processingFormat.sampleRate
        let restored = try AVAudioFile(forReading: destination)
        let description = restored.fileFormat.streamDescription.pointee
        #expect(restored.fileFormat.sampleRate == 44_100)
        #expect(restored.fileFormat.channelCount == 2)
        let expectedFormat = switch format {
        case .alac: kAudioFormatAppleLossless
        case .aac: kAudioFormatMPEG4AAC
        case .wav: kAudioFormatLinearPCM
        }
        #expect(description.mFormatID == expectedFormat)
        #expect(abs(Double(restored.length) / 44_100 - sourceDuration) < 0.01)
        #expect(fractions == fractions.sorted())
        #expect((output?.analysis.cutoffFrequency ?? 0) > 19_500)
    }
}
