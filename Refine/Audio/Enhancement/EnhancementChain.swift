import Foundation

/// Finishing stages run on an engine's output: « Équilibre tonal » (`TonalEqualizer`), « Brillance »
/// (`AirEqualizer`), « Espace » (`StereoWidener`), « Mix » (`MixEnhancer`), « Attaques »
/// (`TransientRestorer`), « Punch » (`PunchShaper`), then the volume and a true-peak limiter. Equalisation, widening and volume are fixed per
/// file, computed from the long-term statistics of the engine's output, so they never pump.
///
/// Stereo audio is processed as Mid/Side: the equalisation applies to both, the rebuilt Side is added to S,
/// and L/R are recombined before the time-domain stages.
final class EnhancementChain {
    private let channelCount: Int
    private let midFilter: StaticSpectralFilter?
    private let sideFilter: StaticSpectralFilter?
    private let widenFilter: StaticSpectralFilter?
    private let mix: MixEnhancer?
    private let transients: [TransientRestorer]
    private let tonal: TonalEqualizer?
    private let air: AirEqualizer?
    private let widener: StereoWidener?
    private let punch: PunchShaper?
    /// Linear volume change.
    private let gain: Float
    private let limiter: PeakLimiter?

    /// - Parameters:
    ///   - analysis: the source file's analysis (for its cutoff).
    ///   - statistics: long-term Mid/Side spectra of the engine's output.
    ///   - loudness: loudness of the engine's output.
    init(
        settings: RestorationSettings, analysis: AudioAnalysis, statistics: StereoStatistics,
        loudness: LoudnessProfile? = nil, channelCount: Int
    ) {
        self.channelCount = channelCount
        let amount = Self.amount(intensity: settings.intensity)
        let mid = statistics.averageMid
        let side = statistics.averageSide
        let total = zip(mid, side).map { $0 + $1 }

        let tonal = settings.rebalanceTone
            ? TonalProfile.measure(averagePower: total, binWidth: statistics.binWidth, cutoff: analysis.cutoffFrequency)
                .flatMap { TonalEqualizer.make(profile: $0, amount: amount) }
            : nil
        self.tonal = tonal
        air = settings.extendBandwidth
            ? AirEqualizer.make(
                averagePower: mid, binWidth: statistics.binWidth, cutoff: analysis.cutoffFrequency, amount: amount,
                correction: { tonal?.gain(at: $0) ?? 0 })
            : nil
        widener = settings.restoreStereo && channelCount == 2
            ? StereoWidener.make(
                mid: mid, side: side, binWidth: statistics.binWidth,
                detectionLimit: min(analysis.cutoffFrequency, 20_000), amount: amount)
            : nil

        var equalizerGains: [Float]?
        if air != nil || widener != nil || tonal != nil {
            var gains = air?.gains ?? StaticSpectralFilter.identityGains
            if let tonal {
                for k in gains.indices {
                    gains[k] *= Float(pow(10, tonal.gain(at: StaticSpectralFilter.frequency(ofBin: k)) / 20))
                }
            }
            equalizerGains = gains
            midFilter = StaticSpectralFilter(gains: gains)
            sideFilter = channelCount == 2 ? StaticSpectralFilter(gains: gains) : nil
            widenFilter = widener.map { StaticSpectralFilter(real: $0.responseReal, imag: $0.responseImag) }
        } else {
            midFilter = nil
            sideFilter = nil
            widenFilter = nil
        }
        let mixOptions = MixEnhancer.Options(
            vocalLevel: min(max(settings.vocalLevel, -6), 6), tameSibilance: settings.tameSibilance,
            tightenBass: settings.tightenBass, amount: amount)
        mix = mixOptions.vocalLevel != 0 || mixOptions.tameSibilance || mixOptions.tightenBass
            ? MixEnhancer(options: mixOptions, channelCount: channelCount)
            : nil
        transients = settings.restoreTransients
            ? (0..<channelCount).map { _ in TransientRestorer(amount: amount) }
            : []

        // Dynamics: punch for squashed masters, volume for weak ones.
        let squashed = loudness?.kind == .squashed
        let punchAmount = loudness.map { amount * min(max((LoudnessProfile.squashedCrest + 3 - $0.crest) / 4, 0.4), 1) } ?? 0
        punch = settings.restorePunch && squashed ? PunchShaper(amount: punchAmount, channelCount: channelCount) : nil
        var volume = 0.0
        if settings.adjustLoudness, let loudness {
            let change = Self.loudnessChange(gains: equalizerGains, mid: mid, side: side, binWidth: statistics.binWidth)
            switch loudness.kind {
            case .weak:
                // Up to −14 LUFS, without asking the limiter for more than 3 dB.
                let wanted = LoudnessProfile.targetLoudness - (loudness.integrated + change)
                volume = min(max(min(wanted, 2 - (loudness.truePeak + change)), 0), 12)
            case .squashed where punch != nil:
                // Room for the attacks the punch stage brings back, or the limiter would flatten them again.
                volume = -0.75 * PunchShaper.maximumBoost * punchAmount
            default:
                break
            }
        }
        gain = Float(pow(10, volume / 20))
        limiter = settings.adjustLoudness ? PeakLimiter(channelCount: channelCount) : nil
    }

    /// Loudness change an equaliser will cause, in LU: its power gain weighted by the signal's K-weighted spectrum.
    static func loudnessChange(gains: [Float]?, mid: [Double], side: [Double], binWidth: Double) -> Double {
        guard let gains else { return 0 }
        let filterBinWidth = StaticSpectralFilter.frequency(ofBin: 1)
        var before = 0.0, after = 0.0
        for k in 1..<min(mid.count, side.count) {
            let frequency = Double(k) * binWidth
            let weighted = (mid[k] + side[k]) * LoudnessMeter.kWeightingGain(at: frequency)
            let g = Double(gains[min(gains.count - 1, Int((frequency / filterBinWidth).rounded()))])
            before += weighted
            after += weighted * g * g
        }
        return before > 0 && after > 0 ? 10 * log10(after / before) : 0
    }

    /// Full dose from « Équilibré » up; « Subtil » still does something audible.
    static func amount(intensity: Double) -> Double {
        min(1, (max(intensity, 0) / RestorationSettings.Preset.balanced.intensity).squareRoot())
    }

    func process(_ channels: [[Float]]) -> [[Float]] {
        let equalized = equalize(channels) { filter, samples in filter.process(samples) }
        return shapeDynamics(restoreTransients(mix?.process(equalized) ?? equalized))
    }

    func finish() -> [[Float]] {
        var tail = equalize(Array(repeating: [], count: channelCount)) { filter, _ in filter.finish() }
        if let mix { tail = zip(mix.process(tail), mix.finish()).map { $0 + $1 } }
        var processed = restoreTransients(tail)
        if !transients.isEmpty { processed = zip(processed, transients).map { $0 + $1.finish() } }
        return shapeDynamics(processed, finishing: true)
    }

    /// What the finishing stages did, for the track screen.
    var notes: [String] {
        var notes: [String] = []
        if let air, air.averageBoost >= 0.5 {
            notes.append("Aigus reconstruits renforcés de \(Int(air.averageBoost.rounded())) dB")
        }
        if let start = widener?.profile.collapseFrequency {
            notes.append("Image stéréo rouverte au-dessus de \(start.kilohertz)")
        }
        let attacks = transients.map(\.cleanedAttacks).max() ?? 0
        if attacks > 0 {
            notes.append("\(attacks) attaque\(attacks > 1 ? "s" : "") débarrassée\(attacks > 1 ? "s" : "") du pré-écho")
        }
        notes += tonal?.notes ?? []
        notes += mix?.notes ?? []
        if let punch, punch.attacks > 0 {
            notes.append("Punch rendu à \(punch.attacks) attaque\(punch.attacks > 1 ? "s" : "")")
        }
        let volume = 20 * log10(Double(gain))
        if volume >= 0.5 {
            notes.append("Volume remonté de \(volume.decibels), vers \(Int(LoudnessProfile.targetLoudness)) LUFS")
        } else if volume <= -0.5 {
            notes.append("Volume abaissé de \((-volume).decibels) pour laisser respirer les attaques")
        }
        return notes
    }

    // MARK: - Stages

    private func equalize(_ channels: [[Float]], run: (StaticSpectralFilter, [Float]) -> [Float]) -> [[Float]] {
        guard let midFilter else { return channels }
        guard channelCount == 2, let sideFilter, channels.count == 2 else {
            return [run(midFilter, channels.first ?? [])]
        }
        let left = channels[0], right = channels[1]
        let mid = zip(left, right).map { ($0 + $1) * 0.5 }
        let side = zip(left, right).map { ($0 - $1) * 0.5 }
        let newMid = run(midFilter, mid)
        var newSide = run(sideFilter, side)
        if let widenFilter {
            let added = run(widenFilter, mid)
            for i in 0..<min(newSide.count, added.count) { newSide[i] += added[i] }
        }
        let count = min(newMid.count, newSide.count)
        return [
            (0..<count).map { newMid[$0] + newSide[$0] },
            (0..<count).map { newMid[$0] - newSide[$0] },
        ]
    }

    private func shapeDynamics(_ channels: [[Float]], finishing: Bool = false) -> [[Float]] {
        var result = channels
        if let punch {
            result = finishing ? zip(punch.process(result), punch.finish()).map { $0 + $1 } : punch.process(result)
        }
        if gain != 1 {
            result = result.map { channel in channel.map { $0 * gain } }
        }
        if let limiter {
            result = finishing ? zip(limiter.process(result), limiter.finish()).map { $0 + $1 } : limiter.process(result)
        }
        return result
    }

    private func restoreTransients(_ channels: [[Float]]) -> [[Float]] {
        guard !transients.isEmpty else { return channels }
        return zip(channels, transients).map { $1.process($0) }
    }
}
