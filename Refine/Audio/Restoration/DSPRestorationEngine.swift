import Foundation

/// On-device restoration built from signal processing only: declipping, spectral hole filling,
/// bandwidth extension, then dithered conversion to 16-bit / 44.1 kHz. Streams the file in blocks,
/// so memory stays flat whatever the duration.
struct DSPRestorationEngine: RestorationEngine {
    var name: String { "Traitement du signal" }

    func restore(_ job: RestorationJob) -> AsyncThrowingStream<RestorationEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let output = try Self.run(job) { continuation.yield($0) }
                    continuation.yield(.finished(output))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func run(_ job: RestorationJob, events: (RestorationEvent) -> Void) throws -> RestorationOutput {
        let analysis = job.analysis
        let settings = job.settings
        let reader = try AudioReader(url: job.source)
        let writer = try AudioWriter(url: job.destination, format: settings.exportFormat)
        defer { writer.close() }

        let parameters = SpectralRestorer.Parameters(analysis: analysis, settings: settings)
        let restorers = (0..<reader.channelCount).map { SpectralRestorer(parameters: parameters, seed: UInt64($0 + 1)) }
        let declipper = settings.declip && analysis.isClipped ? Declipper() : nil
        // Rebuilt peaks need somewhere to go.
        let preGain: Float = declipper == nil ? 1 : 0.89
        var conditioner = OutputConditioner()
        let collector = SpectrumCollector(sampleRate: AudioReader.targetSampleRate, expectedSamples: reader.estimatedFrameCount)
        var levels = LevelStatistics()

        func emit(_ channels: [[Float]]) throws {
            guard let frames = channels.first?.count, frames > 0 else { return }
            let conditioned = channels.map { $0.map(OutputConditioner.softClip) }
            levels.consume(conditioned)
            collector.consume(AudioReader.mixdown(conditioned))
            try writer.write(conditioner.process(channels))
        }

        let total = max(reader.estimatedFrameCount, 1)
        var processed = 0
        var lastPreview = 0.0
        while var block = try reader.read(maxFrames: 32_768) {
            try Task.checkCancellation()
            processed += block.first?.count ?? 0
            if let declipper {
                for index in block.indices { declipper.process(&block[index]) }
            }
            if preGain != 1 {
                block = block.map { $0.map { $0 * preGain } }
            }
            try emit(zip(restorers, block).map { $0.process($1) })

            let fraction = min(Double(processed) / Double(total), 0.99)
            if fraction - lastPreview >= 0.02 {
                lastPreview = fraction
                events(.progress(fraction, collector.makeImage().map(SpectrogramImage.init)))
            }
        }
        try emit(restorers.map { $0.finish() })

        let restoredAnalysis = AudioAnalyzer.makeAnalysis(
            collector: collector, levels: levels, codec: settings.exportFormat == .alac ? .alac : .pcm,
            sourceSampleRate: AudioReader.targetSampleRate, channelCount: AudioWriter.channelCount)
        return RestorationOutput(
            analysis: restoredAnalysis,
            spectrogramPNG: collector.makeImage().flatMap(SpectrogramRenderer.pngData))
    }
}
