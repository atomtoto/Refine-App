import Foundation

/// On-device restoration built from signal processing only: declipping, spectral hole filling,
/// bandwidth extension, then dithered conversion to 16-bit / 44.1 kHz. Streams the file in blocks,
/// so memory stays flat whatever the duration.
struct DSPRestorationEngine: RestorationEngine {
    static let name = "Traitement du signal"

    func restore(_ job: RestorationJob) -> AsyncThrowingStream<RestorationEvent, any Error> {
        .detachedRestoration { try Self.run(job, events: $0) }
    }

    static func run(_ job: RestorationJob, events: @escaping (RestorationEvent) -> Void) throws -> RestorationOutput {
        let analysis = job.analysis
        let settings = job.settings
        let reader = try AudioReader(url: job.source)
        let output = try RestorationOutputStage(
            destination: job.destination, format: settings.exportFormat,
            expectedFrames: reader.estimatedFrameCount, events: events)

        let parameters = SpectralRestorer.Parameters(analysis: analysis, settings: settings)
        let restorers = (0..<reader.channelCount).map { SpectralRestorer(parameters: parameters, seed: UInt64($0 + 1)) }
        let declipper = settings.declip && analysis.isClipped ? Declipper() : nil
        // Rebuilt peaks need somewhere to go.
        let preGain: Float = declipper == nil ? 1 : 0.89

        while var block = try reader.read(maxFrames: 32_768) {
            try Task.checkCancellation()
            if let declipper {
                for index in block.indices { declipper.process(&block[index]) }
            }
            if preGain != 1 {
                block = block.map { $0.map { $0 * preGain } }
            }
            try output.write(zip(restorers, block).map { $0.process($1) })
        }
        try output.write(restorers.map { $0.finish() })
        return output.finish(engine: name)
    }
}
