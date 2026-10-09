import Foundation

/// Applies a fixed complex response to each frequency bin of a stream (2048-point STFT, hop 512).
///
/// Fixed responses can't pump or smear: they behave like an equaliser, computed once per file.
final class StaticSpectralFilter {
    static let size = 2048

    private let stft = StreamingSTFT(size: size, hop: size / 4)
    private let responseReal: [Float]
    private let responseImag: [Float]?

    /// Real gains: an equaliser.
    init(gains: [Float]) {
        precondition(gains.count == Self.size / 2 + 1)
        responseReal = gains
        responseImag = nil
    }

    /// Complex response, e.g. a gain combined with a delay.
    init(real: [Float], imag: [Float]) {
        precondition(real.count == Self.size / 2 + 1 && imag.count == real.count)
        responseReal = real
        responseImag = imag
    }

    static var identityGains: [Float] { .init(repeating: 1, count: size / 2 + 1) }

    /// Frequency of bin `k` at the CD sample rate.
    static func frequency(ofBin k: Int) -> Double {
        Double(k) * AudioReader.targetSampleRate / Double(size)
    }

    func process(_ samples: [Float]) -> [Float] {
        stft.process(samples) { apply(&$0) }
    }

    func finish() -> [Float] {
        stft.finish { apply(&$0) }
    }

    private func apply(_ frame: inout SpectrumFrame) {
        if let responseImag {
            for k in frame.real.indices {
                let re = frame.real[k], im = frame.imag[k]
                frame.real[k] = re * responseReal[k] - im * responseImag[k]
                frame.imag[k] = re * responseImag[k] + im * responseReal[k]
            }
        } else {
            for k in frame.real.indices {
                frame.real[k] *= responseReal[k]
                frame.imag[k] *= responseReal[k]
            }
        }
    }
}

func raisedCosine(_ t: Double) -> Double {
    let clamped = min(max(t, 0), 1)
    return 0.5 - 0.5 * cos(.pi * clamped)
}
