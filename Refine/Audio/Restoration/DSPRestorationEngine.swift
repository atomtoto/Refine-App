import Foundation

/// On-device restoration built from signal processing only: declipping, spectral hole filling and
/// bandwidth extension, followed by the shared finishing stages. Streams the file in blocks, so memory stays
/// flat whatever the duration.
struct DSPRestorationEngine: RestorationEngine {
    static let name = "Traitement du signal"

    func restore(_ job: RestorationJob) -> AsyncThrowingStream<RestorationEvent, any Error> {
        .detachedRestoration { try Self.run(job, events: $0) }
    }

    static func run(_ job: RestorationJob, events: @escaping (RestorationEvent) -> Void) throws -> RestorationOutput {
        try RestorationPipeline.run(job, engineName: name, engineShare: 0.6, events: events) { reader, sink in
            let parameters = SpectralRestorer.Parameters(analysis: job.analysis, settings: job.settings)
            let restorers = (0..<reader.channelCount).map { SpectralRestorer(parameters: parameters, seed: UInt64($0 + 1)) }
            let declipper = job.settings.declip && job.analysis.isClipped ? Declipper() : nil
            // Rebuilt peaks need somewhere to go.
            let preGain: Float = declipper == nil ? 1 : 0.89

            while var block = try reader.read(maxFrames: 32_768) {
                try Task.checkCancellation()
                if let declipper {
                    for index in block.indices { declipper.process(&block[index]) }
                    block = block.map { $0.map { $0 * preGain } }
                }
                try sink(zip(restorers, block).map { $0.process($1) })
            }
            try sink(restorers.map { $0.finish() })
        }
    }
}
