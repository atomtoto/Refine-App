import Foundation

/// A model that rewrites fixed-size blocks of STFT frames.
protocol SpectralModel {
    /// Frames per call.
    var frameCount: Int { get }
    /// `real` and `imag` are row-major `[binCount × frameCount]`.
    func transform(real: inout [Float], imag: inout [Float]) throws
}

/// Streams audio through a `SpectralModel` that only accepts fixed-size blocks of frames.
///
/// Framing follows `torch.stft(center: true)`: frame `f` is centred on sample `f · hop`, and the signal is
/// reflect-padded by half a frame at both ends. Consecutive blocks overlap by `2 · margin` frames; only the
/// central frames of each block are kept, so every kept frame was computed with enough context on both sides.
/// Kept frames are overlap-added and normalised by the summed squared window, like `torch.istft`.
/// The output has exactly the input's length and alignment.
final class SpectralBlockProcessor {
    private let stft: MatrixSTFT
    private let model: SpectralModel
    private let blockFrames: Int
    private let margin: Int
    private let pad: Int

    /// Padded-domain samples; `padded[0]` is padded position `paddedStart`.
    private var padded: [Float] = []
    private var paddedStart = 0
    private var head: [Float] = []
    private var started = false
    private var inputCount = 0

    /// Overlap-add accumulators; index 0 is padded position `outputStart`.
    private var accumulator: [Float] = []
    private var envelope: [Float] = []
    private var outputStart = 0

    private var blockStart = 0
    private var keptUntil = 0

    init(stft: MatrixSTFT, model: SpectralModel, margin: Int) {
        precondition(stft.size == 2 * stft.hop, "Frames must overlap by half")
        precondition(model.frameCount > 2 * margin)
        self.stft = stft
        self.model = model
        blockFrames = model.frameCount
        self.margin = margin
        pad = stft.size / 2
    }

    /// Fraction of each block that is recomputed context rather than kept output.
    var overheadRatio: Double { Double(blockFrames) / Double(blockFrames - 2 * margin) }

    func process(_ samples: [Float]) throws -> [Float] {
        inputCount += samples.count
        if started {
            padded.append(contentsOf: samples)
        } else {
            head.append(contentsOf: samples)
            // Reflect padding needs `pad + 1` samples to mirror around the first one.
            guard head.count > pad else { return [] }
            padded = Array(head[1...pad].reversed()) + head
            head = []
            started = true
        }

        var output: [Float] = []
        // A block can run once all its frames lie inside the samples received so far.
        while paddedStart + padded.count >= (blockStart + blockFrames - 1) * stft.hop + stft.size {
            output += try runBlock(lastFrame: nil)
        }
        return output
    }

    func finish() throws -> [Float] {
        guard inputCount > 0 else { return [] }
        if !started {
            // Too short to reflect: pad with silence instead.
            padded = [Float](repeating: 0, count: pad) + head
            started = true
        }
        let signalEnd = pad + inputCount  // padded position just past the last real sample
        let available = paddedStart + padded.count - signalEnd
        if available == 0, inputCount > pad {
            // Mirror the last `pad` samples around the final one.
            let tail = padded.suffix(pad + 1)
            padded += tail.dropLast().reversed()
        } else {
            padded += [Float](repeating: 0, count: pad)
        }

        let frameTotal = 1 + inputCount / stft.hop
        var output: [Float] = []
        while keptUntil < frameTotal {
            output += try runBlock(lastFrame: frameTotal)
        }
        return output
    }

    /// Runs the block starting at `blockStart`, adds its kept frames and returns the samples now final.
    private func runBlock(lastFrame frameTotal: Int?) throws -> [Float] {
        let isLast = frameTotal.map { blockStart + blockFrames >= $0 } ?? false
        if isLast, let frameTotal {
            // End the last block on the last real frame. Padding it with silent frames instead throws neural
            // models off, and the damage spreads back through their time convolutions.
            blockStart = max(0, frameTotal - blockFrames)
        }
        let realFrames = frameTotal.map { min(blockFrames, $0 - blockStart) } ?? blockFrames

        let first = blockStart * stft.hop - paddedStart
        let needed = first + (blockFrames - 1) * stft.hop + stft.size
        if padded.count < needed {
            padded += [Float](repeating: 0, count: needed - padded.count)
        }

        var real: [Float] = []
        var imag: [Float] = []
        padded.withUnsafeBufferPointer { buffer in
            let slice = UnsafeBufferPointer(rebasing: buffer[first..<needed])
            stft.analyze(slice, frameCount: blockFrames, real: &real, imag: &imag)
        }
        if realFrames < blockFrames {
            // Shorter than one block: mirror the real frames into the remaining columns.
            Self.mirrorColumns(&real, rows: stft.binCount, columns: blockFrames, validColumns: realFrames)
            Self.mirrorColumns(&imag, rows: stft.binCount, columns: blockFrames, validColumns: realFrames)
        }
        try model.transform(real: &real, imag: &imag)
        let frames = stft.synthesize(real: real, imag: imag, frameCount: blockFrames)

        let keepEnd = isLast ? frameTotal! : blockStart + blockFrames - margin

        // Overlap-add the kept frames.
        let lastSample = (keepEnd - 1) * stft.hop + stft.size
        let required = lastSample - outputStart
        if accumulator.count < required {
            accumulator += [Float](repeating: 0, count: required - accumulator.count)
            envelope += [Float](repeating: 0, count: required - envelope.count)
        }
        for frame in keptUntil..<keepEnd {
            let column = frame - blockStart
            let offset = frame * stft.hop - outputStart
            for n in 0..<stft.size {
                accumulator[offset + n] += frames[n * blockFrames + column]
                envelope[offset + n] += stft.window[n] * stft.window[n]
            }
        }
        keptUntil = keepEnd
        blockStart += blockFrames - 2 * margin

        // Samples before the first frame still to come are complete. The reflect padding is never emitted.
        let signalEnd = pad + inputCount
        let emitEnd = min(isLast ? signalEnd : keepEnd * stft.hop, signalEnd)
        var output: [Float] = []
        if emitEnd > outputStart {
            let count = emitEnd - outputStart
            output.reserveCapacity(count)
            for i in 0..<count where outputStart + i >= pad {
                output.append(envelope[i] > 1e-10 ? accumulator[i] / envelope[i] : 0)
            }
            accumulator.removeFirst(min(count, accumulator.count))
            envelope.removeFirst(min(count, envelope.count))
            outputStart = emitEnd
        }

        // Drop input the next blocks no longer need, keeping one block of history: the last block may step back.
        let keepFrom = max(0, blockStart - blockFrames) * stft.hop - paddedStart
        if keepFrom > 0 {
            padded.removeFirst(min(keepFrom, padded.count))
            paddedStart += keepFrom
        }
        return output
    }

    private static func mirrorColumns(_ matrix: inout [Float], rows: Int, columns: Int, validColumns: Int) {
        guard validColumns > 0 else { return }
        for column in validColumns..<columns {
            let source = max(0, 2 * (validColumns - 1) - column) % validColumns
            for row in 0..<rows { matrix[row * columns + column] = matrix[row * columns + source] }
        }
    }
}
