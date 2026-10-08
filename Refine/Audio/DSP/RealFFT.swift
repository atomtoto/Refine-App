import Accelerate

/// A complex spectrum: bins `0...size/2`, standard DFT scaling.
struct SpectrumFrame {
    var real: [Float]
    var imag: [Float]

    init(binCount: Int) {
        real = .init(repeating: 0, count: binCount)
        imag = .init(repeating: 0, count: binCount)
    }
}

/// Real-input FFT returning the standard DFT bins `0...size/2`, built on `vDSP.DiscreteFourierTransform`.
///
/// vDSP's complex-real transforms use a packed layout (even samples in the real part, odd samples in the
/// imaginary part, Nyquist stored in `imag[0]`) and their own scale factors. Both are hidden here, and the
/// scales are measured once at init so the class doesn't depend on documented-but-easy-to-misread constants.
final class RealFFT {
    let size: Int
    let binCount: Int

    private let forwardTransform: vDSP.DiscreteFourierTransform<Float>
    private let inverseTransform: vDSP.DiscreteFourierTransform<Float>
    private var packedReal: [Float]
    private var packedImag: [Float]
    private var resultReal: [Float]
    private var resultImag: [Float]
    private var forwardScale: Float = 1
    private var inverseScale: Float = 1

    init(size: Int) {
        precondition(size >= 32 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        binCount = size / 2 + 1
        let half = size / 2
        forwardTransform = try! vDSP.DiscreteFourierTransform(
            previous: nil, count: size, direction: .forward, transformType: .complexReal, ofType: Float.self)
        inverseTransform = try! vDSP.DiscreteFourierTransform(
            previous: forwardTransform, count: size, direction: .inverse, transformType: .complexReal, ofType: Float.self)
        packedReal = .init(repeating: 0, count: half)
        packedImag = .init(repeating: 0, count: half)
        resultReal = .init(repeating: 0, count: half)
        resultImag = .init(repeating: 0, count: half)
        calibrate()
    }

    /// Forward transform of `size` samples into `binCount` complex bins.
    func forward(_ samples: UnsafeBufferPointer<Float>, into spectrum: inout SpectrumFrame) {
        let half = size / 2
        packedReal.withUnsafeMutableBufferPointer { re in
            packedImag.withUnsafeMutableBufferPointer { im in
                for i in 0..<half {
                    re[i] = samples[2 * i]
                    im[i] = samples[2 * i + 1]
                }
            }
        }
        forwardTransform.transform(
            inputReal: packedReal, inputImaginary: packedImag,
            outputReal: &resultReal, outputImaginary: &resultImag)

        let scale = forwardScale
        resultReal.withUnsafeBufferPointer { rr in
            resultImag.withUnsafeBufferPointer { ri in
                spectrum.real.withUnsafeMutableBufferPointer { re in
                    spectrum.imag.withUnsafeMutableBufferPointer { im in
                        re[0] = rr[0] * scale
                        im[0] = 0
                        re[half] = ri[0] * scale
                        im[half] = 0
                        for k in 1..<half {
                            re[k] = rr[k] * scale
                            im[k] = ri[k] * scale
                        }
                    }
                }
            }
        }
    }

    /// Inverse transform of `binCount` complex bins into `size` samples.
    func inverse(_ spectrum: SpectrumFrame, into samples: UnsafeMutableBufferPointer<Float>) {
        let half = size / 2
        packedReal.withUnsafeMutableBufferPointer { pr in
            packedImag.withUnsafeMutableBufferPointer { pi in
                spectrum.real.withUnsafeBufferPointer { re in
                    spectrum.imag.withUnsafeBufferPointer { im in
                        pr[0] = re[0]
                        pi[0] = re[half]
                        for k in 1..<half {
                            pr[k] = re[k]
                            pi[k] = im[k]
                        }
                    }
                }
            }
        }
        inverseTransform.transform(
            inputReal: packedReal, inputImaginary: packedImag,
            outputReal: &resultReal, outputImaginary: &resultImag)

        let scale = inverseScale
        resultReal.withUnsafeBufferPointer { rr in
            resultImag.withUnsafeBufferPointer { ri in
                for i in 0..<half {
                    samples[2 * i] = rr[i] * scale
                    samples[2 * i + 1] = ri[i] * scale
                }
            }
        }
    }

    private func calibrate() {
        // A constant signal of ones has a DC bin equal to `size` in the standard DFT.
        let ones = [Float](repeating: 1, count: size)
        var spectrum = SpectrumFrame(binCount: binCount)
        ones.withUnsafeBufferPointer { forward($0, into: &spectrum) }
        forwardScale = Float(size) / spectrum.real[0]

        // Round trip that same spectrum and scale the result back to the input.
        var back = [Float](repeating: 0, count: size)
        spectrum.real[0] *= forwardScale
        back.withUnsafeMutableBufferPointer { inverse(spectrum, into: $0) }
        inverseScale = 1 / back[0]
    }
}
