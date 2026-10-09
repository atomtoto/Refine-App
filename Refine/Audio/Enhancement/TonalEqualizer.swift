import Foundation

/// « Équilibre tonal » — corrects a dull, boomy or muddy balance with three broad moves: a tilt above 1 kHz,
/// a bass shelf around 100 Hz and a cut around 250 Hz.
///
/// Only the part of a deviation beyond `TonalProfile`'s tolerances is corrected (all of it for the tilt, 70 % for
/// the low end), so a mix keeps its character and a good master is left as is. Fixed per file: it behaves like a
/// mastering equaliser.
struct TonalEqualizer {
    static let maximumCorrection: Double = 6
    static let maximumTilt: Double = 2

    /// dB per octave above 1 kHz.
    let tilt: Double
    /// dB, shelf below ≈100 Hz.
    let bass: Double
    /// dB, never positive, around 250 Hz.
    let mud: Double

    static func make(profile: TonalProfile, amount: Double) -> TonalEqualizer? {
        func excess(_ value: Double, tolerance: Double) -> Double {
            value.sign == .minus ? min(value + tolerance, 0) : max(value - tolerance, 0)
        }
        let tilt = min(max(-excess(profile.tilt, tolerance: TonalProfile.tiltTolerance), -maximumTilt), maximumTilt)
        let bass = min(max(-0.7 * excess(profile.bass, tolerance: TonalProfile.bassTolerance), -5), 4)
        let mud = max(-0.7 * max(profile.mud - TonalProfile.mudTolerance, 0), -4)
        let equalizer = TonalEqualizer(tilt: tilt * amount, bass: bass * amount, mud: mud * amount)
        return abs(equalizer.tilt) < 0.1 && abs(equalizer.bass) < 0.3 && abs(equalizer.mud) < 0.3 ? nil : equalizer
    }

    /// Correction at `frequency`, in dB.
    func gain(at frequency: Double) -> Double {
        let f = max(frequency, 1)
        let tiltPart = tilt * max(log2(f / 1_000), 0)
        // Below 30 Hz there's mostly rumble: the shelf fades out rather than boosting it.
        let subsonic = pow(f / 30, 4) / (1 + pow(f / 30, 4))
        let bassPart = bass / (1 + pow(f / 100, 2)) * (bass > 0 ? subsonic : 1)
        let mudPart = mud * exp(-0.5 * pow(log2(f / 250) / 0.6, 2))
        return min(max(tiltPart + bassPart + mudPart, -Self.maximumCorrection), Self.maximumCorrection)
    }

    /// What the correction changes, for the track screen.
    var notes: [String] {
        var notes: [String] = []
        let presence = gain(at: 4_000)
        if abs(presence) >= 0.5 {
            notes.append(presence > 0
                ? "Clarté rendue : +\(presence.decibels) de présence"
                : "Aigus adoucis de \((-presence).decibels)")
        }
        if abs(bass) >= 0.5 {
            notes.append(bass > 0 ? "Grave renforcé de \(bass.decibels)" : "Grave allégé de \((-bass).decibels)")
        }
        if mud <= -0.5 {
            notes.append("Bas-médium désengorgé de \((-mud).decibels)")
        }
        return notes
    }
}
