import Foundation

struct RestorationSettings: Codable, Hashable, Sendable {
    enum Preset: String, Codable, CaseIterable, Identifiable, Sendable {
        case subtle, balanced, intense

        var id: Self { self }

        var title: String {
            switch self {
            case .subtle: "Subtil"
            case .balanced: "Équilibré"
            case .intense: "Intense"
            }
        }

        var intensity: Double {
            switch self {
            case .subtle: 0.35
            case .balanced: 0.65
            case .intense: 0.95
            }
        }
    }

    enum ExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
        case alac, aac, wav

        var id: Self { self }

        var title: String {
            switch self {
            case .alac: "ALAC (Apple Lossless)"
            case .aac: "AAC 256 kbps"
            case .wav: "WAV"
            }
        }

        /// What the file is, as shown next to the export.
        var summary: String {
            switch self {
            case .alac, .wav: "16 bits · 44,1 kHz"
            case .aac: "AAC 256 kbps · 44,1 kHz"
            }
        }

        var codec: AudioCodec {
            switch self {
            case .alac: .alac
            case .aac: .aac
            case .wav: .pcm
            }
        }

        var fileExtension: String {
            switch self {
            case .alac, .aac: "m4a"
            case .wav: "wav"
            }
        }
    }

    var preset: Preset = .balanced
    /// How strongly the reconstructed content is mixed in, 0.1…1.
    var intensity: Double = Preset.balanced.intensity
    var extendBandwidth = true
    var fillSpectralHoles = true
    var declip = true
    var exportFormat: ExportFormat = .alac
}
