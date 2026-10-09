import AudioToolbox
import Foundation

/// The codec a file was encoded with, as reported by Core Audio.
enum AudioCodec: String, Codable, Sendable {
    case mp3, aac, alac, flac, pcm, other

    init(formatID: AudioFormatID) {
        switch formatID {
        case kAudioFormatMPEGLayer3: self = .mp3
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD:
            self = .aac
        case kAudioFormatAppleLossless: self = .alac
        case kAudioFormatFLAC: self = .flac
        case kAudioFormatLinearPCM: self = .pcm
        default: self = .other
        }
    }

    var displayName: String {
        switch self {
        case .mp3: "MP3"
        case .aac: "AAC"
        case .alac: "ALAC"
        case .flac: "FLAC"
        case .pcm: "PCM"
        case .other: "Audio"
        }
    }

    /// Whether the *container* claims to be lossless. The spectrum may say otherwise.
    var isLossless: Bool {
        switch self {
        case .alac, .flac, .pcm: true
        case .mp3, .aac, .other: false
        }
    }
}

/// What Refine learned from a file's spectrum.
struct AudioAnalysis: Codable, Hashable, Sendable {
    enum Verdict: String, Codable, Sendable {
        /// Lossless container with a full-band spectrum.
        case authenticLossless
        /// Lossless container, but the spectrum shows a lossy encoder's low-pass.
        case fakeLossless
        /// Lossy file whose low-pass sits high enough to be nearly transparent.
        case transparentLossy
        /// Lossy file with an audible loss of high frequencies.
        case lossy
    }

    var codec: AudioCodec
    var sourceSampleRate: Double
    var channelCount: Int
    var duration: TimeInterval
    /// Bitrate declared by the file, in kbps.
    var declaredBitrate: Int?
    /// Highest frequency that still carries real content, in Hz.
    var cutoffFrequency: Double
    /// Spectral tilt of the octave below the cutoff, in dB per octave.
    var spectralSlope: Double
    /// Fraction of samples sitting in clipped plateaus.
    var clippingRatio: Double
    var peak: Double
    var verdict: Verdict
    /// Bitrate of the lossy source this spectrum most likely came from, in kbps.
    var estimatedBitrate: Int?
    /// Stereo width and where it collapses. Absent from analyses made before it existed.
    var stereo: StereoProfile?
    /// Loudness, true peak and punch. Absent from analyses made before it existed.
    var loudness: LoudnessProfile?
    /// Tonal balance against modern masters. Absent from analyses made before it existed.
    var tonal: TonalProfile?

    /// 0…1 score of how much of the CD band is intact.
    var fidelity: Double {
        min(max((cutoffFrequency - 11_000) / (CutoffDetector.fullBandFrequency - 11_000), 0), 1)
    }

    var isClipped: Bool { clippingRatio > 1e-5 }

    /// Whether bandwidth extension has anything to reconstruct.
    var hasMissingHighs: Bool { cutoffFrequency < CutoffDetector.transparentFrequency }

    static func verdict(cutoff: Double, codec: AudioCodec) -> Verdict {
        let fullBand = cutoff >= CutoffDetector.fullBandFrequency
        if codec.isLossless { return fullBand ? .authenticLossless : .fakeLossless }
        return cutoff >= CutoffDetector.transparentFrequency ? .transparentLossy : .lossy
    }

    /// Typical LAME low-pass frequencies per bitrate.
    static func estimatedBitrate(forCutoff cutoff: Double) -> Int? {
        switch cutoff {
        case ..<11_500: 64
        case ..<15_500: 96
        case ..<17_300: 128
        case ..<18_000: 160
        case ..<19_000: 192
        case ..<19_900: 256
        case ..<CutoffDetector.fullBandFrequency: 320
        default: nil
        }
    }
}
