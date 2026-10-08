import Foundation

/// « Attaques » — removes MP3 pre-echo, the faint hiss that precedes drum hits, plucks and piano notes.
///
/// MP3 codes 26 ms blocks (1152 samples); when a block contains an attack, its quantisation noise spreads over the
/// whole block, including the silence-ish moments before the hit. Encoders shorten the block at attacks, so the
/// smear is mostly in the last few milliseconds — it is also what reconstruction with long STFT frames spreads.
/// That smear is what makes compressed attacks sound soft. This stage looks ahead in a very short STFT
/// (128-point, 0.73 ms hop): when the high-band energy jumps ten-fold above the level measured before the block,
/// the excess high-frequency energy in the frames leading up to the attack — right up to it — is pulled back to
/// that earlier level (at most −20 dB). Stationary sounds never trigger it, and the attack itself is untouched.
final class TransientRestorer {
    static let size = 128
    static let hop = 32
    /// Frames before an attack that may hold pre-echo: one MP3 block, 26 ms.
    static let reach = 36
    /// Frames kept back before output: long enough to see an attack `reach` frames ahead.
    static let lookahead = reach + 4
    /// Strongest attenuation of pre-echo.
    static let floorGain: Float = 0.1

    private let fft = RealFFT(size: size)
    private let window = StreamingSTFT.hannWindow(size: size)
    private let synthesisGain: Float
    private let lowestBin: Int
    private let amount: Float
    private let energyFloor: Float

    private var pending: [Float]
    private var readIndex = 0
    private var queue: [(spectrum: SpectrumFrame, gain: Float)] = []
    private var queueStart = 0
    private var energies: [Float] = []
    private var frameIndex = 0
    private var lastAttack = Int.min / 2
    private var lastAttackEnergy: Float = 0
    private var lastCleaned = Int.min / 2
    private var accumulator: [Float]
    private var samplesToDrop: Int
    private var samplesIn = 0
    private var samplesOut = 0
    private var scratch: [Float]

    /// Attacks whose pre-echo was reduced.
    private(set) var cleanedAttacks = 0

    init(amount: Double, sampleRate: Double = AudioReader.targetSampleRate) {
        self.amount = Float(min(max(amount, 0), 1))
        lowestBin = Int(2_500 / (sampleRate / Double(Self.size)))
        let window = self.window
        let overlap = (0..<Self.hop).map { offset in
            stride(from: offset, to: Self.size, by: Self.hop).reduce(Float(0)) { $0 + window[$1] * window[$1] }
        }
        synthesisGain = 1 / (overlap.reduce(0, +) / Float(Self.hop))
        // −70 dBFS in this transform's units (a full-scale sine peaks at (Σw / 2)²).
        let peak = window.reduce(0, +) / 2
        energyFloor = peak * peak * 1e-7
        pending = .init(repeating: 0, count: Self.size - Self.hop)
        accumulator = .init(repeating: 0, count: Self.size)
        samplesToDrop = Self.size - Self.hop
        scratch = .init(repeating: 0, count: Self.size)
    }

    func process(_ samples: [Float]) -> [Float] {
        pending.append(contentsOf: samples)
        samplesIn += samples.count
        var output: [Float] = []
        analyzeAvailableFrames()
        while queue.count > Self.lookahead { output += emitOldestFrame() }
        compactInput()
        return output
    }

    func finish() -> [Float] {
        pending.append(contentsOf: [Float](repeating: 0, count: Self.size))
        analyzeAvailableFrames()
        var output: [Float] = []
        while !queue.isEmpty { output += emitOldestFrame() }
        return output
    }

    // MARK: - Analysis

    private func analyzeAvailableFrames() {
        while pending.count - readIndex >= Self.size {
            pending.withUnsafeBufferPointer { input in
                scratch.withUnsafeMutableBufferPointer { frame in
                    for i in 0..<Self.size { frame[i] = input[readIndex + i] * window[i] }
                }
            }
            var spectrum = SpectrumFrame(binCount: fft.binCount)
            scratch.withUnsafeBufferPointer { fft.forward($0, into: &spectrum) }
            var energy: Float = 0
            for k in lowestBin..<fft.binCount {
                energy += spectrum.real[k] * spectrum.real[k] + spectrum.imag[k] * spectrum.imag[k]
            }
            queue.append((spectrum, 1))
            energies.append(energy)
            detectAttack(at: frameIndex)
            frameIndex += 1
            readIndex += Self.hop
            if energies.count > 128 { energies.removeFirst(energies.count - 128) }
        }
    }

    /// Energy of frame `index`, if still remembered.
    private func energy(of index: Int) -> Float? {
        let offset = index - (frameIndex - energies.count + 1)
        return energies.indices.contains(offset) ? energies[offset] : nil
    }

    private func detectAttack(at t: Int) {
        guard amount > 0, let current = energy(of: t), current > energyFloor else { return }
        // Pre-echo can itself look like an attack against the quiet before it. A real attack right after must
        // then be much stronger to count; otherwise attacks are at least one block apart.
        guard t - lastAttack > Self.reach || current > 10 * lastAttackEnergy else { return }
        // Level before the pre-echo region: 35 to 70 ms earlier.
        let baselineFrames = ((t - 96)..<(t - 48)).compactMap(energy(of:))
        guard baselineFrames.count == 48 else { return }
        let baseline = max(baselineFrames.reduce(0, +) / 48, energyFloor * 0.01)
        guard current > 10 * baseline else { return }
        // An attack stands out from everything just before it; the decay of a previous hit doesn't.
        let recent = ((t - Self.reach)..<t).compactMap(energy(of:)).max() ?? 0
        guard current > 4 * recent else { return }
        lastAttack = t
        lastAttackEnergy = current

        var corrected = false
        // Frames before the attack, within one MP3 block of it, louder than the quiet before but well below the
        // attack: that's the smeared noise. The attack only enters frame `t`, at the tail of its window.
        for j in (t - Self.reach)...(t - 1) {
            let position = j - queueStart
            guard queue.indices.contains(position), let level = energy(of: j),
                  level > 2 * baseline, level < current / 4 else { continue }
            let full = max((baseline / level).squareRoot(), Self.floorGain)
            let gain = 1 - amount * (1 - full)
            queue[position].gain = min(queue[position].gain, gain)
            corrected = true
        }
        if corrected {
            if t - lastCleaned > Self.reach { cleanedAttacks += 1 }
            lastCleaned = t
        }
    }

    // MARK: - Synthesis

    private func emitOldestFrame() -> [Float] {
        var (spectrum, gain) = queue.removeFirst()
        queueStart += 1
        if gain < 1 {
            // Taper into the attenuated band over two bins.
            for k in max(0, lowestBin - 2)..<fft.binCount {
                let blend = Float(min(1, Double(k - lowestBin + 3) / 3))
                let factor = 1 - blend * (1 - gain)
                spectrum.real[k] *= factor
                spectrum.imag[k] *= factor
            }
        }
        scratch.withUnsafeMutableBufferPointer { fft.inverse(spectrum, into: $0) }
        let synthesis = synthesisGain
        accumulator.withUnsafeMutableBufferPointer { acc in
            scratch.withUnsafeBufferPointer { frame in
                for i in 0..<Self.size { acc[i] += frame[i] * window[i] * synthesis }
            }
        }

        var output: [Float] = []
        let dropped = min(samplesToDrop, Self.hop)
        samplesToDrop -= dropped
        let available = min(Self.hop - dropped, samplesIn - samplesOut)
        if available > 0 {
            output.append(contentsOf: accumulator[dropped..<(dropped + available)])
            samplesOut += available
        }
        accumulator.removeFirst(Self.hop)
        accumulator.append(contentsOf: repeatElement(0, count: Self.hop))
        return output
    }

    private func compactInput() {
        if readIndex > 0 {
            pending.removeFirst(readIndex)
            readIndex = 0
        }
    }
}
