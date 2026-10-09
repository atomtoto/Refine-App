import Foundation

/// The tail every restoration shares: peak protection, 16-bit dither, file writing, and the analysis of the
/// final file.
final class RestorationOutputStage {
    private let writer: AudioWriter
    private let format: RestorationSettings.ExportFormat
    private let collector: SpectrumCollector
    private let expectedFrames: Int
    private let progressStart: Double
    private let events: (RestorationEvent) -> Void
    private var conditioner = OutputConditioner()
    private var levels = LevelStatistics()
    private var lastReport = 0.0
    private var writtenFrames = 0

    /// - Parameter progressStart: overall fraction already done when this stage starts.
    init(destination: URL, format: RestorationSettings.ExportFormat, expectedFrames: Int, progressStart: Double,
         events: @escaping (RestorationEvent) -> Void) throws {
        writer = try AudioWriter(url: destination, format: format)
        self.format = format
        self.expectedFrames = max(expectedFrames, 1)
        self.progressStart = progressStart
        collector = SpectrumCollector(sampleRate: AudioReader.targetSampleRate, expectedSamples: expectedFrames)
        self.events = events
    }

    func write(_ channels: [[Float]]) throws {
        if let frames = channels.first?.count, frames > 0 {
            writtenFrames += frames
            let conditioned = channels.map { $0.map(OutputConditioner.softClip) }
            levels.consume(conditioned)
            collector.consume(AudioReader.mixdown(conditioned))
            try writer.write(conditioner.process(channels))
        }
        let coverage = min(Double(writtenFrames) / Double(expectedFrames), 1)
        if coverage - lastReport >= 0.05 {
            lastReport = coverage
            let fraction = min(progressStart + (1 - progressStart) * coverage, 0.99)
            events(.progress(RestorationProgress(fraction: fraction, stage: .finishing, preview: nil, previewCoverage: 1)))
        }
    }

    func finish(engine: String, notes: [String]) -> RestorationOutput {
        writer.close()
        let analysis = AudioAnalyzer.makeAnalysis(
            collector: collector, levels: levels, codec: format.codec,
            sourceSampleRate: AudioReader.targetSampleRate, channelCount: AudioWriter.channelCount)
        return RestorationOutput(
            analysis: analysis,
            spectrogramPNG: collector.makeImage().flatMap(SpectrogramRenderer.pngData),
            engine: engine,
            notes: notes)
    }
}
