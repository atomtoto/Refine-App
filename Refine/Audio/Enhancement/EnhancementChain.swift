import Foundation

/// Finishing stages run on an engine's output: « Brillance » (`AirEqualizer`), « Espace » (`StereoWidener`)
/// and « Attaques » (`TransientRestorer`). Equalisation and widening are fixed per file, computed from the
/// long-term statistics of the engine's output, so they never pump.
///
/// Stereo audio is processed as Mid/Side: the air boost applies to both, the rebuilt Side is added to S, and
/// L/R are recombined before the transient stage, which runs per channel.
final class EnhancementChain {
    private let channelCount: Int
    private let midFilter: StaticSpectralFilter?
    private let sideFilter: StaticSpectralFilter?
    private let widenFilter: StaticSpectralFilter?
    private let transients: [TransientRestorer]
    private let air: AirEqualizer?
    private let widener: StereoWidener?

    /// - Parameters:
    ///   - analysis: the source file's analysis (for its cutoff).
    ///   - statistics: long-term Mid/Side spectra of the engine's output.
    init(settings: RestorationSettings, analysis: AudioAnalysis, statistics: StereoStatistics, channelCount: Int) {
        self.channelCount = channelCount
        let amount = Self.amount(intensity: settings.intensity)
        let mid = statistics.averageMid
        let side = statistics.averageSide

        air = settings.extendBandwidth
            ? AirEqualizer.make(averagePower: mid, binWidth: statistics.binWidth, cutoff: analysis.cutoffFrequency, amount: amount)
            : nil
        widener = settings.restoreStereo && channelCount == 2
            ? StereoWidener.make(
                mid: mid, side: side, binWidth: statistics.binWidth,
                detectionLimit: min(analysis.cutoffFrequency, 20_000), amount: amount)
            : nil

        if air != nil || widener != nil {
            let gains = air?.gains ?? StaticSpectralFilter.identityGains
            midFilter = StaticSpectralFilter(gains: gains)
            sideFilter = channelCount == 2 ? StaticSpectralFilter(gains: gains) : nil
            widenFilter = widener.map { StaticSpectralFilter(real: $0.responseReal, imag: $0.responseImag) }
        } else {
            midFilter = nil
            sideFilter = nil
            widenFilter = nil
        }
        transients = settings.restoreTransients
            ? (0..<channelCount).map { _ in TransientRestorer(amount: amount) }
            : []
    }

    /// Full dose from « Équilibré » up; « Subtil » still does something audible.
    static func amount(intensity: Double) -> Double {
        min(1, (max(intensity, 0) / RestorationSettings.Preset.balanced.intensity).squareRoot())
    }

    func process(_ channels: [[Float]]) -> [[Float]] {
        restoreTransients(equalize(channels) { filter, samples in filter.process(samples) })
    }

    func finish() -> [[Float]] {
        let tail = equalize(Array(repeating: [], count: channelCount)) { filter, _ in filter.finish() }
        let processed = restoreTransients(tail)
        guard !transients.isEmpty else { return processed }
        return zip(processed, transients).map { $0 + $1.finish() }
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

    private func restoreTransients(_ channels: [[Float]]) -> [[Float]] {
        guard !transients.isEmpty else { return channels }
        return zip(channels, transients).map { $1.process($0) }
    }
}
