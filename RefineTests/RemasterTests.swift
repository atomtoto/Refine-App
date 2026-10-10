import Foundation
import Testing
@testable import Refine

private let sampleRate = SignalFixtures.sampleRate

private func loudness(_ channels: [[Float]]) -> LoudnessProfile {
    let meter = LoudnessMeter()
    meter.consume(channels)
    return meter.profile
}

private func truePeak(_ channels: [[Float]]) -> Double {
    var detectors = channels.map { _ in TruePeakDetector() }
    var peak: Float = 0
    for c in channels.indices {
        for x in channels[c] + [Float](repeating: 0, count: TruePeakDetector.delay * 2) {
            peak = max(peak, detectors[c].process(x))
        }
    }
    return 20 * log10(Double(peak))
}

private func rms(_ samples: ArraySlice<Float>) -> Double {
    (samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count)).squareRoot()
}

/// White noise shaped through the STFT so its third-octave levels follow `level(frequency)` in dB.
private func noise(seconds: Double, seed: UInt64 = 3, level: @escaping (Double) -> Double) -> [Float] {
    let stft = StreamingSTFT()
    let binWidth = sampleRate / Double(stft.size)
    let transform: (inout SpectrumFrame) -> Void = { frame in
        for k in 1..<frame.real.count {
            let frequency = Double(k) * binWidth
            // Third-octave bands widen with frequency: white noise gains 1 dB per band, so compensate.
            let gain = Float(pow(10, (level(frequency) - 10 * log10(frequency / 1_000)) / 20))
            frame.real[k] *= gain
            frame.imag[k] *= gain
        }
        frame.real[0] = 0
        frame.imag[0] = 0
    }
    let white = SignalFixtures.whiteNoise(seconds: seconds, seed: seed)
    let shaped = stft.process(white, transform: transform) + stft.finish(transform: transform)
    let peak = shaped.map(abs).max() ?? 1
    return shaped.map { $0 / peak * 0.5 }
}

private func tonalProfile(_ samples: [Float]) throws -> TonalProfile {
    let statistics = StereoStatistics()
    statistics.consume([samples])
    return try #require(TonalProfile.measure(
        averagePower: statistics.averageMid, binWidth: statistics.binWidth, cutoff: 20_000))
}

struct LoudnessMeterTests {
    @Test func matchesTheStandardOnASine() {
        // BS.1770: a 1 kHz sine at −20 dBFS peak in each of two channels reads −20 LUFS (−23 per channel).
        let sine = SignalFixtures.sine(frequency: 1_000, amplitude: 0.1, seconds: 5)
        #expect(abs(loudness([sine, sine]).integrated - -20) < 0.1)
        // Mono is measured as dual mono.
        #expect(abs(loudness([sine]).integrated - loudness([sine, sine]).integrated) < 0.01)
    }

    @Test func seesPeaksBetweenSamples() {
        // A quarter-rate sine sampled 45° off its crests: samples peak at −3 dB, the wave at 0 dB.
        let samples = (0..<44_100).map { Float(sin(.pi / 2 * Double($0) + .pi / 4)) }
        #expect(abs(truePeak([samples])) < 0.3)
        #expect((samples.map(abs).max() ?? 0) < 0.72)
    }

    @Test func tellsSquashedFromNatural() {
        let drums = drumLoop(seconds: 8)
        #expect(loudness([drums, drums]).kind != .squashed)
        let squashed = limitedFlat(drums)
        #expect(loudness([squashed, squashed]).kind == .squashed)
        let weak = drums.map { $0 * 0.05 }
        #expect(loudness([weak, weak]).kind == .weak)
    }
}

struct TonalTests {
    @Test func referenceBalanceIsLeftAlone() throws {
        let reference = noise(seconds: 6) { TonalProfile.reference(at: $0) }
        let profile = try tonalProfile(reference)
        #expect(profile.kind == .balanced)
        #expect(abs(profile.tilt) < 0.3)
        #expect(TonalEqualizer.make(profile: profile, amount: 1) == nil)
    }

    @Test func dullBalanceIsDetectedAndBrightened() throws {
        // 2 dB per octave darker than the reference above 1 kHz: −6 dB at 8 kHz.
        let darkening: (Double) -> Double = { -2 * max(log2($0 / 1_000), 0) }
        let dull = noise(seconds: 6) { TonalProfile.reference(at: $0) + darkening($0) }
        let profile = try tonalProfile(dull)
        #expect(profile.kind == .dull)
        #expect(profile.tilt < -1.5)

        let equalizer = try #require(TonalEqualizer.make(profile: profile, amount: 1))
        // At 8 kHz the deficit was 6 dB; what's beyond the tolerance (3 dB at 8 kHz) is mostly made up.
        let remaining = darkening(8_000) + equalizer.gain(at: 8_000)
        #expect(remaining > -4.5 && remaining < -2)
        #expect(abs(equalizer.gain(at: 500)) < 0.5)
        #expect(!equalizer.notes.isEmpty)
    }
}

struct PeakLimiterTests {
    @Test func holdsTheCeilingOnTruePeaks() {
        let loud = SignalFixtures.whiteNoise(seconds: 2, amplitude: 1.8, seed: 9)
        let impulses = (0..<88_200).map { $0 % 11_025 == 0 ? Float(2.5) : 0 }
        let input = [loud, impulses]
        let limiter = PeakLimiter(ceiling: -1, channelCount: 2)
        let head = limiter.process(input)
        let output = zip(head, limiter.finish()).map { $0 + $1 }
        #expect(output[0].count == input[0].count)
        #expect(truePeak(output) < -0.9)
    }

    @Test func leavesQuietAudioUntouchedAndAligned() {
        let quiet = SignalFixtures.whiteNoise(seconds: 1, amplitude: 0.3, seed: 4)
        let limiter = PeakLimiter(ceiling: -1, channelCount: 1)
        // Odd block sizes exercise the latency bookkeeping.
        var output: [Float] = []
        var offset = 0
        for size in [10, 1_000, 7, 30_000, 20_000] {
            output += limiter.process([Array(quiet[offset..<min(offset + size, quiet.count)])])[0]
            offset = min(offset + size, quiet.count)
        }
        output += limiter.process([Array(quiet[offset...])])[0] + limiter.finish()[0]
        #expect(output.count == quiet.count)
        #expect(zip(output, quiet).allSatisfy { abs($0 - $1) < 1e-7 })
    }
}

/// Kick and snare hits, each a sharp attack and a decay, over a sustained pad.
private func drumLoop(seconds: Double) -> [Float] {
    var random = SeededRandom(seed: 5)
    let count = Int(seconds * sampleRate)
    var samples = (0..<count).map { i -> Float in
        let t = Double(i) / sampleRate
        return Float(0.05 * sin(2 * .pi * 220 * t) + 0.04 * sin(2 * .pi * 330 * t))
    }
    let beat = Int(0.25 * sampleRate)
    for start in stride(from: 0, to: count, by: beat) {
        let isSnare = (start / beat) % 2 == 1
        for i in 0..<min(Int(0.2 * sampleRate), count - start) {
            let t = Double(i) / sampleRate
            let hit = isSnare
                ? Double(random.nextUnit() * 2 - 1) * 0.7 * exp(-t / 0.03)
                : 0.9 * sin(2 * .pi * (55 + 120 * exp(-t / 0.01)) * t) * exp(-t / 0.08)
            samples[start + i] += Float(hit)
        }
    }
    return samples
}

/// What a brick-wall mastering limiter does: 12 dB of gain into a hard ceiling.
private func limitedFlat(_ samples: [Float]) -> [Float] {
    samples.map { min(max($0 * 4, -0.9), 0.9) }
}

struct PunchShaperTests {
    @Test func bringsBackFlattenedAttacks() {
        let squashed = limitedFlat(drumLoop(seconds: 8))
        let shaper = PunchShaper(amount: 1, channelCount: 2)
        let output = zip(shaper.process([squashed, squashed]), shaper.finish()).map { $0 + $1 }
        #expect(output[0].count == squashed.count)
        let before = loudness([squashed, squashed]).crest
        let after = loudness(output).crest
        print("Punch: crest \(before) → \(after) dB, \(shaper.attacks) attacks")
        #expect(after - before > 3)
        #expect(shaper.attacks >= 20)
    }

    @Test func leavesSustainedSoundsAlone() {
        let steady = (0..<Int(4 * sampleRate)).map { i -> Float in
            let t = Double(i) / sampleRate
            return Float(0.3 * sin(2 * .pi * 80 * t) + 0.2 * sin(2 * .pi * 1_000 * t) + 0.1 * sin(2 * .pi * 6_000 * t))
        }
        let shaper = PunchShaper(amount: 1, channelCount: 1)
        let output = shaper.process([steady])[0] + shaper.finish()[0]
        let settled = Int(sampleRate)..<steady.count
        let change = 20 * log10(rms(output[settled]) / rms(steady[settled]))
        #expect(abs(change) < 0.2)
        #expect(shaper.attacks <= 1)
    }
}

struct RemasterChainTests {
    private func settings() -> RestorationSettings {
        var settings = RestorationSettings()
        settings.intensity = 1
        settings.extendBandwidth = false
        settings.restoreStereo = false
        settings.restoreTransients = false
        settings.tameSibilance = false
        settings.tightenBass = false
        return settings
    }

    private func run(_ input: [[Float]], settings: RestorationSettings) -> [[Float]] {
        let statistics = StereoStatistics()
        statistics.consume(input)
        let chain = EnhancementChain(
            settings: settings, analysis: SignalFixtures.analysis(of: input[0], codec: .flac),
            statistics: statistics, loudness: loudness(input), channelCount: input.count)
        return zip(chain.process(input), chain.finish()).map { $0 + $1 }
    }

    @Test func raisesAWeakMasterTowardsTheTarget() {
        let weak = drumLoop(seconds: 8).map { $0 * 0.08 }
        let input = [weak, weak]
        #expect(loudness(input).kind == .weak)
        let output = run(input, settings: settings())
        #expect(output[0].count == weak.count)
        let result = loudness(output)
        print("Weak: \(loudness(input).integrated) → \(result.integrated) LUFS, true peak \(result.truePeak)")
        #expect(result.integrated > loudness(input).integrated + 4)
        #expect(result.integrated < LoudnessProfile.targetLoudness + 0.5)
        #expect(result.truePeak < -0.9)
    }

    @Test func givesSquashedMastersRoomToBreathe() {
        let squashed = limitedFlat(drumLoop(seconds: 8))
        let input = [squashed, squashed]
        let output = run(input, settings: settings())
        let before = loudness(input), after = loudness(output)
        print("Squashed: crest \(before.crest) → \(after.crest), \(before.integrated) → \(after.integrated) LUFS")
        #expect(after.crest - before.crest > 2.5)
        #expect(after.truePeak < -0.9)
    }
}
