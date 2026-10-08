import Foundation

/// Restoration by Apollo, a neural network trained to turn MP3-compressed music (24–128 kbps) back into
/// full-band audio. It rebuilds the missing highs and also repairs the encoder's artefacts below the cutoff.
///
/// The file is streamed: each channel goes through a `SpectralBlockProcessor` feeding blocks of STFT frames
/// (384 frames, ≈ 3.8 s, for the bundled model) to the network, keeping the central frames of each block. The intensity setting blends the original
/// back in, which works because the network's output stays sample-aligned with its input.
struct ApolloRestorationEngine: RestorationEngine {
    static let name = "IA Apollo"
    /// Frames of context recomputed on each side of a block (0.48 s). The network's time convolutions reach
    /// ±54 frames, but with weights that fade towards the edges; the end-to-end test bounds the difference.
    static let margin = 48

    func restore(_ job: RestorationJob) -> AsyncThrowingStream<RestorationEvent, any Error> {
        .detachedRestoration { try Self.run(job, events: $0) }
    }

    /// Share of the restored signal in the mix, from the 0.1…1 intensity setting.
    static func wetMix(intensity: Double) -> Float {
        Float(min(max(0.4 + 0.6 * intensity, 0), 1))
    }

    static func run(_ job: RestorationJob, events: @escaping (RestorationEvent) -> Void) throws -> RestorationOutput {
        let settings = job.settings
        let reader = try AudioReader(url: job.source)
        let output = try RestorationOutputStage(
            destination: job.destination, format: settings.exportFormat,
            expectedFrames: reader.estimatedFrameCount, events: events)

        let model = try ApolloModel(computeUnits: settings.computeUnits.coreML)
        let stft = MatrixSTFT(size: ApolloModel.frameSize, hop: ApolloModel.hop)
        let processors = (0..<reader.channelCount).map { _ in
            SpectralBlockProcessor(stft: stft, model: model, margin: margin)
        }
        let declipper = settings.declip && job.analysis.isClipped ? Declipper() : nil
        // Rebuilt peaks need somewhere to go.
        let preGain: Float = declipper == nil ? 1 : 0.89
        let wet = wetMix(intensity: settings.intensity)
        // The processors return audio later than it goes in: keep the dry signal until its restored twin arrives.
        var dry = Array(repeating: [Float](), count: reader.channelCount)

        func emit(_ restored: [[Float]]) throws {
            let count = restored.map(\.count).min() ?? 0
            var mixed: [[Float]] = []
            for channel in restored.indices {
                let original = dry[channel].prefix(count)
                mixed.append(zip(restored[channel].prefix(count), original).map { wet * $0 + (1 - wet) * $1 })
                dry[channel].removeFirst(count)
            }
            try output.write(mixed)
        }

        while var block = try reader.read(maxFrames: 44_100) {
            try Task.checkCancellation()
            if let declipper {
                for index in block.indices { declipper.process(&block[index]) }
                block = block.map { $0.map { $0 * preGain } }
            }
            for channel in block.indices { dry[channel] += block[channel] }
            try emit(zip(processors, block).map { try $0.process($1) })
        }
        try Task.checkCancellation()
        try emit(processors.map { try $0.finish() })
        return output.finish(engine: name)
    }
}
