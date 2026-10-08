import Accelerate

/// Short-time Fourier transform of any frame size, computed as matrix products against a precomputed,
/// windowed DFT basis. Matches `torch.stft` / `torch.istft` with a periodic Hann window, which is what
/// Apollo was trained with (882-point frames, not a power of two, so vDSP's FFTs don't apply).
///
/// Spectra are row-major `[binCount × frames]` matrices: one row per frequency bin, one column per frame.
final class MatrixSTFT {
    let size: Int
    let hop: Int
    let binCount: Int
    let window: [Float]

    /// `[binCount × size]`: rows of cos and −sin, pre-multiplied by the window.
    private let forwardCos: [Float]
    private let forwardSin: [Float]
    /// `[size × 2·binCount]`: inverse real DFT for stacked [real; imag] spectra, pre-multiplied by the window.
    private let inverseBasis: [Float]

    init(size: Int, hop: Int) {
        self.size = size
        self.hop = hop
        binCount = size / 2 + 1
        let window = StreamingSTFT.hannWindow(size: size)
        self.window = window

        var cosines = [Float](repeating: 0, count: binCount * size)
        var sines = [Float](repeating: 0, count: binCount * size)
        var inverse = [Float](repeating: 0, count: size * 2 * binCount)
        for k in 0..<binCount {
            // Hermitian symmetry: interior bins stand for two conjugate bins of the full spectrum.
            let weight: Double = (k == 0 || 2 * k == size) ? 1 : 2
            for n in 0..<size {
                let angle = 2 * Double.pi * Double(k * n % size) / Double(size)
                let w = Double(window[n])
                cosines[k * size + n] = Float(cos(angle) * w)
                sines[k * size + n] = Float(-sin(angle) * w)
                inverse[n * 2 * binCount + k] = Float(weight * cos(angle) * w / Double(size))
                inverse[n * 2 * binCount + binCount + k] = Float(-weight * sin(angle) * w / Double(size))
            }
        }
        forwardCos = cosines
        forwardSin = sines
        inverseBasis = inverse
    }

    /// Spectra of `frameCount` frames read from `samples`, frame `f` starting at `f · hop`.
    /// `samples` must hold at least `(frameCount − 1) · hop + size` values.
    func analyze(_ samples: UnsafeBufferPointer<Float>, frameCount: Int, real: inout [Float], imag: inout [Float]) {
        precondition(samples.count >= (frameCount - 1) * hop + size)
        // Column f of the frame matrix is samples[f·hop ..< f·hop + size].
        var frames = [Float](repeating: 0, count: size * frameCount)
        frames.withUnsafeMutableBufferPointer { frames in
            for f in 0..<frameCount {
                let start = f * hop
                for n in 0..<size { frames[n * frameCount + f] = samples[start + n] }
            }
        }
        real = .init(repeating: 0, count: binCount * frameCount)
        imag = .init(repeating: 0, count: binCount * frameCount)
        vDSP_mmul(forwardCos, 1, frames, 1, &real, 1, vDSP_Length(binCount), vDSP_Length(frameCount), vDSP_Length(size))
        vDSP_mmul(forwardSin, 1, frames, 1, &imag, 1, vDSP_Length(binCount), vDSP_Length(frameCount), vDSP_Length(size))
    }

    /// Windowed time-domain frames `[size × frameCount]` for the given spectra, ready for overlap-add.
    func synthesize(real: [Float], imag: [Float], frameCount: Int) -> [Float] {
        let stacked = real + imag
        var frames = [Float](repeating: 0, count: size * frameCount)
        vDSP_mmul(inverseBasis, 1, stacked, 1, &frames, 1, vDSP_Length(size), vDSP_Length(frameCount), vDSP_Length(2 * binCount))
        return frames
    }
}
