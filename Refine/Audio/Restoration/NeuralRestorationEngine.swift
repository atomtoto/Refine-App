import Foundation

/// Slot for a neural restorer, such as an Apollo-style MP3 restoration model converted with coremltools.
///
/// Expected model contract, to stay interchangeable with the DSP pipeline:
/// - input `magnitude`: log-magnitude STFT, shape [1, 1025, frames] (2048-point Hann, hop 512, 44.1 kHz)
/// - output `magnitude`: same shape, with the band above the cutoff reconstructed
/// Phases would come from `SpectralRestorer`'s band replication, then the same 16-bit conditioning applies.
struct NeuralRestorationEngine: RestorationEngine {
    static let modelName = "RefineRestorer"

    static var isAvailable: Bool {
        Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") != nil
    }

    var name: String { "IA neuronale" }

    func restore(_ job: RestorationJob) -> AsyncThrowingStream<RestorationEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: RestorationError.engineUnavailable) }
    }
}
