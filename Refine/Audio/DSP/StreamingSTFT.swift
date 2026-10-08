import Foundation

/// Hann-windowed short-time Fourier transform with overlap-add resynthesis, fed in arbitrary block sizes.
///
/// Output has the same length as the input, with no latency once `finish` has been called: the
/// `size - hop` leading samples of internal delay are dropped automatically.
final class StreamingSTFT {
    let size: Int
    let hop: Int

    private let fft: RealFFT
    private let window: [Float]
    private let synthesisGain: Float
    private var pending: [Float]
    private var readIndex = 0
    private var accumulator: [Float]
    private var frame: [Float]
    private var spectrum: SpectrumFrame
    private var samplesToDrop: Int
    private var samplesIn = 0
    private var samplesOut = 0

    init(size: Int = 2048, hop: Int = 512) {
        precondition(size % hop == 0, "Hop must divide the frame size")
        self.size = size
        self.hop = hop
        fft = RealFFT(size: size)
        let window = Self.hannWindow(size: size)
        self.window = window
        // Sum of squared analysis × synthesis windows across overlapping frames is constant.
        let overlapSum = (0..<hop).map { offset in
            stride(from: offset, to: size, by: hop).reduce(Float(0)) { $0 + window[$1] * window[$1] }
        }
        synthesisGain = 1 / (overlapSum.reduce(0, +) / Float(hop))
        pending = .init(repeating: 0, count: size - hop)
        accumulator = .init(repeating: 0, count: size)
        frame = .init(repeating: 0, count: size)
        spectrum = SpectrumFrame(binCount: size / 2 + 1)
        samplesToDrop = size - hop
    }

    static func hannWindow(size: Int) -> [Float] {
        (0..<size).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(size)) }
    }

    /// Feeds samples through `transform` and returns the output that is ready so far.
    func process(_ input: [Float], transform: (inout SpectrumFrame) -> Void) -> [Float] {
        pending.append(contentsOf: input)
        samplesIn += input.count
        return run(transform: transform)
    }

    /// Flushes the tail. The total output length equals the total input length.
    func finish(transform: (inout SpectrumFrame) -> Void) -> [Float] {
        pending.append(contentsOf: [Float](repeating: 0, count: size))
        return run(transform: transform)
    }

    private func run(transform: (inout SpectrumFrame) -> Void) -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(pending.count - readIndex)

        while pending.count - readIndex >= size {
            pending.withUnsafeBufferPointer { input in
                frame.withUnsafeMutableBufferPointer { frame in
                    for i in 0..<size { frame[i] = input[readIndex + i] * window[i] }
                }
            }
            frame.withUnsafeBufferPointer { fft.forward($0, into: &spectrum) }
            transform(&spectrum)
            frame.withUnsafeMutableBufferPointer { fft.inverse(spectrum, into: $0) }

            let gain = synthesisGain
            accumulator.withUnsafeMutableBufferPointer { acc in
                frame.withUnsafeBufferPointer { frame in
                    window.withUnsafeBufferPointer { window in
                        for i in 0..<size { acc[i] += frame[i] * window[i] * gain }
                    }
                }
            }

            let dropped = min(samplesToDrop, hop)
            samplesToDrop -= dropped
            let available = min(hop - dropped, samplesIn - samplesOut)
            if available > 0 {
                output.append(contentsOf: accumulator[dropped..<(dropped + available)])
                samplesOut += available
            }

            accumulator.removeFirst(hop)
            accumulator.append(contentsOf: repeatElement(0, count: hop))
            readIndex += hop
        }

        pending.removeFirst(readIndex)
        readIndex = 0
        return output
    }
}

/// Analysis-only framing: windowed power spectra of a stream, without resynthesis.
final class SpectralFramer {
    let size: Int
    let hop: Int
    /// Power of a full-scale sine's peak bin, used as the 0 dBFS reference.
    let referencePower: Float

    private let fft: RealFFT
    private let window: [Float]
    private var pending: [Float] = []
    private var consumed = 0
    private var frame: [Float]
    private var spectrum: SpectrumFrame
    private var power: [Float]

    init(size: Int = 4096, hop: Int = 2048) {
        self.size = size
        self.hop = hop
        fft = RealFFT(size: size)
        window = StreamingSTFT.hannWindow(size: size)
        let peak = window.reduce(0, +) / 2
        referencePower = peak * peak
        frame = .init(repeating: 0, count: size)
        spectrum = SpectrumFrame(binCount: size / 2 + 1)
        power = .init(repeating: 0, count: size / 2 + 1)
    }

    /// Calls `body` with each complete frame's power spectrum and the frame's start position in the stream.
    func consume(_ samples: [Float], body: (_ power: [Float], _ position: Int) -> Void) {
        pending.append(contentsOf: samples)
        var start = 0
        while pending.count - start >= size {
            pending.withUnsafeBufferPointer { input in
                frame.withUnsafeMutableBufferPointer { frame in
                    for i in 0..<size { frame[i] = input[start + i] * window[i] }
                }
            }
            frame.withUnsafeBufferPointer { fft.forward($0, into: &spectrum) }
            power.withUnsafeMutableBufferPointer { power in
                for k in 0..<power.count {
                    power[k] = spectrum.real[k] * spectrum.real[k] + spectrum.imag[k] * spectrum.imag[k]
                }
            }
            body(power, consumed + start)
            start += hop
        }
        pending.removeFirst(start)
        consumed += start
    }
}
