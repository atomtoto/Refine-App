import AVFoundation

/// Two passes shared by every engine.
///
/// 1. The engine's core (band replication or the neural network) writes to a lossless float file next to the
///    destination, while the Mid/Side statistics of its output are gathered and the spectrogram paints itself.
/// 2. The finishing stages, tuned from those statistics, run over that file on the way to the final export.
///
/// The second pass is cheap: equalisation, transient and dynamics work, no neural network.
enum RestorationPipeline {
    /// Hands the engine's restored blocks to the first pass.
    typealias Sink = (_ channels: [[Float]]) throws -> Void

    /// - Parameters:
    ///   - engineShare: share of the overall progress taken by the engine pass.
    ///   - core: reads `reader`, restores, and passes the result to the sink.
    static func run(
        _ job: RestorationJob, engineName: String, engineShare: Double,
        events: @escaping (RestorationEvent) -> Void,
        core: (_ reader: AudioReader, _ sink: Sink) throws -> Void
    ) throws -> RestorationOutput {
        let reader = try AudioReader(url: job.source)
        let intermediateURL = job.destination.deletingPathExtension().appendingPathExtension("pass1.caf")
        defer { try? FileManager.default.removeItem(at: intermediateURL) }

        let firstPass = try IntermediateStage(
            url: intermediateURL, channelCount: reader.channelCount,
            expectedFrames: reader.estimatedFrameCount, share: engineShare, events: events)
        try core(reader) { try firstPass.write($0) }
        firstPass.close()
        try Task.checkCancellation()

        let chain = EnhancementChain(
            settings: job.settings, analysis: job.analysis, statistics: firstPass.statistics,
            loudness: firstPass.loudness.profile, channelCount: reader.channelCount)
        let restored = try AudioReader(url: intermediateURL)
        let output = try RestorationOutputStage(
            destination: job.destination, format: job.settings.exportFormat,
            expectedFrames: reader.estimatedFrameCount, progressStart: engineShare, events: events)
        while let block = try restored.read(maxFrames: 32_768) {
            try Task.checkCancellation()
            try output.write(chain.process(block))
        }
        try output.write(chain.finish())
        return output.finish(engine: engineName, notes: chain.notes)
    }
}

/// First-pass sink: a float32 CAF, Mid/Side statistics, loudness, and the live spectrogram.
final class IntermediateStage {
    let statistics = StereoStatistics()
    let loudness = LoudnessMeter()

    private var file: AVAudioFile?
    private let buffer: AVAudioPCMBuffer
    private let collector: SpectrumCollector
    private let expectedFrames: Int
    private let share: Double
    private let events: (RestorationEvent) -> Void
    private var writtenFrames = 0
    private var lastPreview = 0.0

    init(url: URL, channelCount: Int, expectedFrames: Int, share: Double,
         events: @escaping (RestorationEvent) -> Void) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioReader.targetSampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else {
            throw AudioWriterError.bufferAllocationFailed
        }
        self.file = file
        self.buffer = buffer
        self.expectedFrames = max(expectedFrames, 1)
        self.share = share
        self.events = events
        collector = SpectrumCollector(sampleRate: AudioReader.targetSampleRate, expectedSamples: expectedFrames)
    }

    func write(_ channels: [[Float]]) throws {
        guard let file, let frames = channels.first?.count, frames > 0, let data = buffer.floatChannelData else { return }
        var offset = 0
        while offset < frames {
            let count = min(Int(buffer.frameCapacity), frames - offset)
            for channel in 0..<Int(buffer.format.channelCount) {
                channels[min(channel, channels.count - 1)].withUnsafeBufferPointer { source in
                    data[channel].update(from: source.baseAddress! + offset, count: count)
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            offset += count
        }
        statistics.consume(channels)
        loudness.consume(channels)
        collector.consume(AudioReader.mixdown(channels.map { $0.map(OutputConditioner.softClip) }))
        writtenFrames += frames

        let coverage = min(Double(writtenFrames) / Double(expectedFrames), 1)
        if coverage - lastPreview >= 0.02 {
            lastPreview = coverage
            events(.progress(RestorationProgress(
                fraction: share * coverage, stage: .engine,
                preview: collector.makeImage().map(SpectrogramImage.init), previewCoverage: coverage)))
        }
    }

    func close() {
        file?.close()
        file = nil
    }
}
