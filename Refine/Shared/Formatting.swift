import Foundation

extension Double {
    /// "16,1 kHz"
    var kilohertz: String {
        "\((self / 1000).formatted(.number.precision(.fractionLength(1)))) kHz"
    }

    /// "3:42"
    var playbackTime: String {
        Duration.seconds(max(self, 0)).formatted(.time(pattern: .minuteSecond))
    }
}

extension AudioAnalysis {
    /// "MP3 · 128 kbps · 44,1 kHz"
    var formatSummary: String {
        var parts = [codec.displayName]
        if let declaredBitrate, !codec.isLossless { parts.append("\(declaredBitrate) kbps") }
        parts.append(sourceSampleRate.kilohertz)
        return parts.joined(separator: " · ")
    }
}

extension AudioAnalysis.Verdict {
    var title: String {
        switch self {
        case .authenticLossless: "Lossless authentique"
        case .fakeLossless: "Faux lossless"
        case .transparentLossy: "Compression légère"
        case .lossy: "Aigus perdus"
        }
    }

    var systemImage: String {
        switch self {
        case .authenticLossless: "checkmark.seal.fill"
        case .fakeLossless: "exclamationmark.triangle.fill"
        case .transparentLossy: "checkmark.circle.fill"
        case .lossy: "waveform.badge.exclamationmark"
        }
    }
}
