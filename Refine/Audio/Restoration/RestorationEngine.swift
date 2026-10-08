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
}

enum RestorationEvent: Sendable {
    /// Fraction done, with the restored spectrogram painted so far.
    case progress(Double, SpectrogramImage?)
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
