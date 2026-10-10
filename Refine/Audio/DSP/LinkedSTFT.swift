import Foundation

/// `StreamingSTFT` for several channels in lockstep: each frame's transform sees every channel's spectrum at
/// once, which stereo-aware processing needs (what's centred, what's wide).
///
/// Output has the same length as the input once `finish` has been called.
final class LinkedSTFT {
    let size: Int
    let hop: Int
    let channelCount: Int

    private let fft: RealFFT
    private let window: [Float]
    private let synthesisGain: Float
    private var pending: [[Float]]
    private var accumulators: [[Float]]
    private var frame: [Float]
    private var spectra: [SpectrumFrame]
    private var samplesToDrop: Int
    private var samplesIn = 0
    private var samplesOut = 0

    init(size: Int = 2048, hop: Int = 512, channelCount: Int) {
        precondition(size % hop == 0, "Hop must divide the frame size")
        self.size = size
        self.hop = hop
        self.channelCount = channelCount
        fft = RealFFT(size: size)
        let window = StreamingSTFT.hannWindow(size: size)
        self.window = window
        let overlapSum = (0..<hop).map { offset in
            stride(from: offset, to: size, by: hop).reduce(Float(0)) { $0 + window[$1] * window[$1] }
        }
        synthesisGain = 1 / (overlapSum.reduce(0, +) / Float(hop))
        pending = Array(repeating: Array(repeating: 0, count: size - hop), count: channelCount)
        accumulators = Array(repeating: Array(repeating: 0, count: size), count: channelCount)
        frame = .init(repeating: 0, count: size)
        spectra = Array(repeating: SpectrumFrame(binCount: size / 2 + 1), count: channelCount)
        samplesToDrop = size - hop
    }

    /// Feeds samples through `transform` and returns the output that is ready so far.
    func process(_ input: [[Float]], transform: (inout [SpectrumFrame]) -> Void) -> [[Float]] {
        for c in 0..<channelCount { pending[c].append(contentsOf: input[c]) }
        samplesIn += input.first?.count ?? 0
        return run(transform: transform)
    }

    /// Flushes the tail. The total output length equals the total input length.
    func finish(transform: (inout [SpectrumFrame]) -> Void) -> [[Float]] {
        for c in 0..<channelCount { pending[c].append(contentsOf: repeatElement(0, count: size)) }
        return run(transform: transform)
    }

    private func run(transform: (inout [SpectrumFrame]) -> Void) -> [[Float]] {
        var output = Array(repeating: [Float](), count: channelCount)
        var readIndex = 0
        while pending[0].count - readIndex >= size {
            for c in 0..<channelCount {
                pending[c].withUnsafeBufferPointer { input in
                    frame.withUnsafeMutableBufferPointer { frame in
                        for i in 0..<size { frame[i] = input[readIndex + i] * window[i] }
                    }
                }
                frame.withUnsafeBufferPointer { fft.forward($0, into: &spectra[c]) }
            }
            transform(&spectra)

            let dropped = min(samplesToDrop, hop)
            samplesToDrop -= dropped
            let available = min(hop - dropped, samplesIn - samplesOut)
            for c in 0..<channelCount {
                frame.withUnsafeMutableBufferPointer { fft.inverse(spectra[c], into: $0) }
                let gain = synthesisGain
                accumulators[c].withUnsafeMutableBufferPointer { acc in
                    frame.withUnsafeBufferPointer { frame in
                        window.withUnsafeBufferPointer { window in
                            for i in 0..<size { acc[i] += frame[i] * window[i] * gain }
                        }
                    }
                }
                if available > 0 { output[c].append(contentsOf: accumulators[c][dropped..<(dropped + available)]) }
                accumulators[c].removeFirst(hop)
                accumulators[c].append(contentsOf: repeatElement(0, count: hop))
            }
            if available > 0 { samplesOut += available }
            readIndex += hop
        }
        for c in 0..<channelCount { pending[c].removeFirst(readIndex) }
        return output
    }
}
