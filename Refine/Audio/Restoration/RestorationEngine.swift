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
}

enum RestorationEvent: Sendable {
    /// Fraction done, with the restored spectrogram painted so far.
    case progress(Double, SpectrogramImage?)
    case finished(RestorationOutput)
}

enum RestorationError: LocalizedError {
    case engineUnavailable

    var errorDescription: String? { "Ce moteur de restauration n'est pas encore disponible." }
}

/// Anything that can turn a lossy file into a 16-bit / 44.1 kHz file.
/// The DSP engine ships today; a Core ML engine can be dropped in behind the same interface.
protocol RestorationEngine: Sendable {
    var name: String { get }
    func restore(_ job: RestorationJob) -> AsyncThrowingStream<RestorationEvent, any Error>
}
