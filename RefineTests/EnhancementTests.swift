import Foundation
import Testing
@testable import Refine

private func bandPower(_ samples: [Float], from lower: Double, to upper: Double) -> Double {
    let collector = SpectrumCollector(sampleRate: SignalFixtures.sampleRate, expectedSamples: samples.count)
    collector.consume(samples)
    let power = collector.averagePower
    let first = Int(lower / collector.binWidth), last = min(power.count - 1, Int(upper / collector.binWidth))
    return power[first...last].reduce(0, +)
}

private func decibels(_ ratio: Double) -> Double { 10 * log10(max(ratio, 1e-30)) }

/// Applies a per-frequency gain through the STFT.
private func shaped(_ samples: [Float], gain: (Double) -> Float) -> [Float] {
    let stft = StreamingSTFT()
    let binWidth = SignalFixtures.sampleRate / Double(stft.size)
    let transform: (inout SpectrumFrame) -> Void = { frame in
        for k in frame.real.indices {
            let g = gain(Double(k) * binWidth)
            frame.real[k] *= g
            frame.imag[k] *= g
        }
    }
    return stft.process(samples, transform: transform) + stft.finish(transform: transform)
}

private func midSide(_ channels: [[Float]]) -> (mid: [Float], side: [Float]) {
    (zip(channels[0], channels[1]).map { ($0 + $1) / 2 }, zip(channels[0], channels[1]).map { ($0 - $1) / 2 })
}

private func run(_ chain: EnhancementChain, _ channels: [[Float]]) -> [[Float]] {
    let head = chain.process(channels)
    let tail = chain.finish()
    return zip(head, tail).map { $0 + $1 }
}

private func settings(air: Bool = false, stereo: Bool = false, transients: Bool = false) -> RestorationSettings {
    var settings = RestorationSettings()
    settings.intensity = 1
    settings.extendBandwidth = air
    settings.restoreStereo = stereo
    settings.restoreTransients = transients
    return settings
}

struct AirEqualizerTests {
    @Test func liftsWeakRebuiltHighsAndLeavesTheRestAlone() throws {
        // An engine output whose band above 16 kHz came back 15 dB too quiet.
        let weak = shaped(SignalFixtures.whiteNoise(seconds: 3)) { $0 > 16_000 ? 0.18 : 1 }
        let statistics = StereoStatistics()
        statistics.consume([weak])
        let air = try #require(AirEqualizer.make(
            averagePower: statistics.averageMid, binWidth: statistics.binWidth, cutoff: 16_000, amount: 1))
        let filter = StaticSpectralFilter(gains: air.gains)
        let output = filter.process(weak) + filter.finish()

        #expect(output.count == weak.count)
        #expect(decibels(bandPower(output, from: 17_000, to: 20_000) / bandPower(weak, from: 17_000, to: 20_000)) > 8)
        #expect(abs(decibels(bandPower(output, from: 1_000, to: 14_000) / bandPower(weak, from: 1_000, to: 14_000))) < 0.1)
        #expect(air.averageBoost > 5)
    }

    @Test func fullBandFilesNeedNoAir() {
        let statistics = StereoStatistics()
        statistics.consume([SignalFixtures.whiteNoise(seconds: 1)])
        #expect(AirEqualizer.make(averagePower: statistics.averageMid, binWidth: statistics.binWidth, cutoff: 21_000, amount: 1) == nil)
    }
}

struct StereoWidenerTests {
    /// Stereo below 8 kHz, mono above: the joint-stereo collapse of a low-bitrate MP3.
    private func collapsedStereo() -> [[Float]] {
        let common = SignalFixtures.whiteNoise(seconds: 3, seed: 1)
        let wide = SignalFixtures.lowPassed(SignalFixtures.whiteNoise(seconds: 3, seed: 2), cutoff: 8_000).map { $0 * 0.5 }
        return [zip(common, wide).map(+), zip(common, wide).map(-)]
    }

    private func statistics(_ channels: [[Float]]) -> StereoStatistics {
        let statistics = StereoStatistics()
        statistics.consume(channels)
        return statistics
    }

    @Test func detectsAndReopensACollapsedImage() throws {
        let input = collapsedStereo()
        let stats = statistics(input)
        let profile = StereoProfile.measure(mid: stats.averageMid, side: stats.averageSide, binWidth: stats.binWidth, upTo: 20_000)
        #expect(profile.kind == .collapsed)
        #expect((7_000...9_500).contains(profile.collapseFrequency ?? 0))

        let analysis = SignalFixtures.analysis(of: midSide(input).mid)
        let chain = EnhancementChain(settings: settings(stereo: true), analysis: analysis, statistics: stats, channelCount: 2)
        let output = run(chain, input)
        #expect(output[0].count == input[0].count)

        let before = midSide(input), after = midSide(output)
        let ratioAfter = decibels(bandPower(after.side, from: 10_000, to: 16_000) / bandPower(after.mid, from: 10_000, to: 16_000))
        #expect(abs(ratioAfter - profile.expectedRatio(at: 13_000)) < 3)
        // Mid untouched: the added Side cancels out in L+R.
        #expect(abs(decibels(bandPower(after.mid, from: 1_000, to: 16_000) / bandPower(before.mid, from: 1_000, to: 16_000))) < 0.1)
        #expect(chain.notes.contains { $0.contains("stéréo") })
    }

    @Test func gradualNarrowingIsNotACollapse() {
        // Side falling about 5 dB per octave above 2 kHz, like many real mixes, MP3 or not.
        let common = SignalFixtures.whiteNoise(seconds: 3, seed: 5)
        let side = shaped(SignalFixtures.whiteNoise(seconds: 3, seed: 6)) { f in
            Float(0.5 * pow(max(f, 2_000) / 2_000, -5.0 / 20 / log10(2)))
        }
        let stats = statistics([zip(common, side).map(+), zip(common, side).map(-)])
        let profile = StereoProfile.measure(mid: stats.averageMid, side: stats.averageSide, binWidth: stats.binWidth, upTo: 20_000)
        #expect(profile.kind == .intact)
        #expect(profile.trendSlope < -2)
    }

    @Test func leavesMonoAndIntactImagesAlone() {
        let mono = SignalFixtures.whiteNoise(seconds: 2)
        let wide = [SignalFixtures.whiteNoise(seconds: 2, seed: 3), SignalFixtures.whiteNoise(seconds: 2, seed: 4)]
        for input in [[mono, mono], wide] {
            let stats = statistics(input)
            let profile = StereoProfile.measure(mid: stats.averageMid, side: stats.averageSide, binWidth: stats.binWidth, upTo: 20_000)
            #expect(profile.kind != .collapsed)
            let chain = EnhancementChain(
                settings: settings(stereo: true), analysis: SignalFixtures.analysis(of: mono), statistics: stats, channelCount: 2)
            let output = run(chain, input)
            #expect(zip(output[0], input[0]).allSatisfy { abs($0 - $1) < 1e-6 })
        }
    }
}

struct TransientRestorerTests {
    private let rate = SignalFixtures.sampleRate
    private let hits = [0.5, 1.0, 1.5]

    /// Percussive hits, each preceded by 20 ms of high-frequency hiss like an MP3 block's spread noise.
    private func hitsWithPreEcho() -> [Float] {
        var random = SeededRandom(seed: 9)
        var signal = (0..<Int(2 * rate)).map { _ in (random.nextUnit() - 0.5) * 2e-4 }
        var previous: Float = 0
        for hit in hits {
            let start = Int(hit * rate)
            for n in (start - Int(0.02 * rate))..<start {
                let noise = random.nextUnit() - 0.5
                signal[n] += (noise - previous) * 0.04
                previous = noise
            }
            for n in 0..<Int(0.15 * rate) {
                signal[start + n] += (random.nextUnit() - 0.5) * Float(exp(-Double(n) / (0.03 * rate)))
            }
        }
        return signal
    }

    private func energy(_ samples: [Float], from start: Double, to end: Double) -> Double {
        samples[Int(start * rate)..<Int(end * rate)].reduce(0) { $0 + Double($1 * $1) }
    }

    @Test func removesPreEchoAndKeepsTheAttack() {
        let input = hitsWithPreEcho()
        let restorer = TransientRestorer(amount: 1)
        let output = restorer.process(input) + restorer.finish()
        #expect(output.count == input.count)
        #expect(restorer.cleanedAttacks == hits.count)

        for hit in hits {
            let preBefore = energy(input, from: hit - 0.018, to: hit - 0.006)
            let preAfter = energy(output, from: hit - 0.018, to: hit - 0.006)
            #expect(decibels(preBefore / preAfter) > 6)
            let attackBefore = energy(input, from: hit + 0.002, to: hit + 0.04)
            let attackAfter = energy(output, from: hit + 0.002, to: hit + 0.04)
            #expect(abs(decibels(attackAfter / attackBefore)) < 1)
        }
    }

    @Test func leavesSteadySoundsAlone() {
        let input = SignalFixtures.whiteNoise(seconds: 2)
        let restorer = TransientRestorer(amount: 1)
        let output = restorer.process(input) + restorer.finish()
        #expect(restorer.cleanedAttacks == 0)
        #expect(zip(input, output).map { abs($0 - $1) }.max() ?? 1 < 1e-4)
    }
}
