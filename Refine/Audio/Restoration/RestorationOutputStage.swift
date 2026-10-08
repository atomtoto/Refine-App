import Foundation

/// The tail every engine shares: peak protection, 16-bit dither, file writing, and the spectrogram that
/// paints itself while the file is processed.
final class RestorationOutputStage {
    private let writer: AudioWriter
    private let format: RestorationSettings.ExportFormat
    private let collector: SpectrumCollector
    private let expectedFrames: Int
    private let events: (RestorationEvent) -> Void
    private var conditioner = OutputConditioner()
    private var levels = LevelStatistics()
    private var lastPreview = 0.0
    private var writtenFrames = 0

    init(destination: URL, format: RestorationSettings.ExportFormat, expectedFrames: Int,
         events: @escaping (RestorationEvent) -> Void) throws {
        writer = try AudioWriter(url: destination, format: format)
        self.format = format
        self.expectedFrames = max(expectedFrames, 1)
        collector = SpectrumCollector(sampleRate: AudioReader.targetSampleRate, expectedSamples: expectedFrames)
        self.events = events
    }

    /// Writes restored samples and reports progress. Progress follows the output, not the input: neural engines
    /// hand audio back a whole block later, and the live spectrogram should paint exactly what's been written.
    func write(_ channels: [[Float]]) throws {
        if let frames = channels.first?.count, frames > 0 {
            writtenFrames += frames
            let conditioned = channels.map { $0.map(OutputConditioner.softClip) }
            levels.consume(conditioned)
            collector.consume(AudioReader.mixdown(conditioned))
            try writer.write(conditioner.process(channels))
        }
        let fraction = min(Double(writtenFrames) / Double(expectedFrames), 0.99)
        if fraction - lastPreview >= 0.02 {
            lastPreview = fraction
            events(.progress(fraction, collector.makeImage().map(SpectrogramImage.init)))
        }
    }

    func finish(engine: String) -> RestorationOutput {
        writer.close()
        let analysis = AudioAnalyzer.makeAnalysis(
            collector: collector, levels: levels, codec: format.codec,
            sourceSampleRate: AudioReader.targetSampleRate, channelCount: AudioWriter.channelCount)
        return RestorationOutput(
            analysis: analysis,
            spectrogramPNG: collector.makeImage().flatMap(SpectrogramRenderer.pngData),
            engine: engine)
    }
}
