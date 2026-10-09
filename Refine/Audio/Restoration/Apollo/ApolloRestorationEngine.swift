import Foundation

/// Restoration by Apollo, a neural network trained to turn MP3-compressed music (24–128 kbps) back into
/// full-band audio. It rebuilds the missing highs and also repairs the encoder's artefacts below the cutoff;
/// the shared finishing stages then take care of the level of the new highs, the stereo image and pre-echo.
///
/// Each channel goes through a `SpectralBlockProcessor` feeding blocks of STFT frames (384 frames, ≈ 3.8 s,
/// for the bundled model) to the network, keeping the central frames of each block. The network's output is
/// used as is: blending the original back in would bring its artefacts back too.
struct ApolloRestorationEngine: RestorationEngine {
    static let name = "IA Apollo"
    /// Frames of context recomputed on each side of a block (0.48 s). The network's time convolutions reach
    /// ±54 frames, but with weights that fade towards the edges; the end-to-end test bounds the difference.
    static let margin = 48

    func restore(_ job: RestorationJob) -> AsyncThrowingStream<RestorationEvent, any Error> {
        .detachedRestoration { try Self.run(job, events: $0) }
    }

    static func run(_ job: RestorationJob, events: @escaping (RestorationEvent) -> Void) throws -> RestorationOutput {
        try RestorationPipeline.run(job, engineName: name, engineShare: 0.85, events: events) { reader, sink in
            let model = try ApolloModel(computeUnits: job.settings.computeUnits.coreML)
            let stft = MatrixSTFT(size: ApolloModel.frameSize, hop: ApolloModel.hop)
            let processors = (0..<reader.channelCount).map { _ in
                SpectralBlockProcessor(stft: stft, model: model, margin: margin)
            }
            let declipper = job.settings.declip && job.analysis.isClipped ? Declipper() : nil
            // Rebuilt peaks need somewhere to go.
            let preGain: Float = declipper == nil ? 1 : 0.89

            while var block = try reader.read(maxFrames: 44_100) {
                try Task.checkCancellation()
                if let declipper {
                    for index in block.indices { declipper.process(&block[index]) }
                    block = block.map { $0.map { $0 * preGain } }
                }
                try sink(zip(processors, block).map { try $0.process($1) })
            }
            try Task.checkCancellation()
            try sink(processors.map { try $0.finish() })
        }
    }
}
