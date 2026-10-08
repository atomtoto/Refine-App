import Foundation

struct RestorationJob: Sendable {
    var source: URL
    var destination: URL
    var analysis: AudioAnalysis
    var settings: RestorationSettings
}

struct RestorationOutput: Sendable {
    /// Analysis of the restored file, showing the new bandwidth.
    var analysis: AudioAnalysis
    var spectrogramPNG: Data?
    /// Display name of the engine that produced it.
    var engine: String
    /// What the finishing stages did, in plain words.
    var notes: [String] = []
}

struct RestorationProgress: Sendable {
    enum Stage: Sendable {
        /// The engine itself: band replication or the neural network.
        case engine
        /// Finishing stages: highs, stereo image, attacks.
        case finishing
    }

    /// Overall fraction done.
    var fraction: Double
    var stage: Stage
    /// Restored spectrogram painted so far; `nil` keeps the previous one.
    var preview: SpectrogramImage?
    /// Share of the timeline the preview covers.
    var previewCoverage: Double
}

enum RestorationEvent: Sendable {
    case progress(RestorationProgress)
    case finished(RestorationOutput)
}

/// Anything that can turn a lossy file into a 16-bit / 44.1 kHz file.
protocol RestorationEngine: Sendable {
    func restore(_ job: RestorationJob) -> AsyncThrowingStream<RestorationEvent, any Error>
}

extension RestorationSettings.Engine {
    /// The engine that runs this choice.
    var implementation: any RestorationEngine {
        switch self {
        case .signal: DSPRestorationEngine()
        case .apollo: ApolloRestorationEngine()
        }
    }
}

extension AsyncThrowingStream where Element == RestorationEvent, Failure == any Error {
    /// Runs blocking restoration work on a detached task, forwarding its events and cancelling it with the stream.
    static func detachedRestoration(
        _ work: @escaping @Sendable (_ events: @escaping (RestorationEvent) -> Void) throws -> RestorationOutput
    ) -> Self {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let output = try work { continuation.yield($0) }
                    continuation.yield(.finished(output))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
