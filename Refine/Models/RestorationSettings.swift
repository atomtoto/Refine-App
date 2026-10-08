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

    enum Engine: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Hand-written signal processing: instant, light, conservative.
        case signal
        /// Apollo neural network, trained to undo MP3 compression.
        case apollo

        var id: Self { self }

        var title: String {
            switch self {
            case .signal: DSPRestorationEngine.name
            case .apollo: ApolloRestorationEngine.name
            }
        }

        var isAvailable: Bool {
            switch self {
            case .signal: true
            case .apollo: ApolloModel.isBundled
            }
        }
    }

    /// Which processors Core ML may use for neural engines. The Neural Engine is left out on purpose: it only
    /// computes in float16, which loses too much precision on Apollo's residual sums, and compiling this model for
    /// it takes minutes on first load.
    enum ComputeUnits: String, Codable, CaseIterable, Identifiable, Sendable {
        case gpu, cpu

        var id: Self { self }

        var title: String {
            switch self {
            case .gpu: "GPU (rapide)"
            case .cpu: "Processeur"
            }
        }
    }

    var engine: Engine = ApolloModel.isBundled ? .apollo : .signal
    var computeUnits: ComputeUnits = .gpu
    var preset: Preset = .balanced
    /// How strongly the reconstructed content is mixed in, 0.1…1.
    var intensity: Double = Preset.balanced.intensity
    var extendBandwidth = true
    var fillSpectralHoles = true
    var declip = true
    var exportFormat: ExportFormat = .alac

    init() {}
}

extension RestorationSettings {
    private enum CodingKeys: String, CodingKey {
        case engine, computeUnits, preset, intensity, extendBandwidth, fillSpectralHoles, declip, exportFormat
    }

    /// Missing or unknown keys fall back to defaults, so settings saved by older versions still load.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let defaults = RestorationSettings()
        engine = value(.engine, defaults.engine)
        computeUnits = value(.computeUnits, defaults.computeUnits)
        preset = value(.preset, defaults.preset)
        intensity = value(.intensity, defaults.intensity)
        extendBandwidth = value(.extendBandwidth, defaults.extendBandwidth)
        fillSpectralHoles = value(.fillSpectralHoles, defaults.fillSpectralHoles)
        declip = value(.declip, defaults.declip)
        exportFormat = value(.exportFormat, defaults.exportFormat)
        if !engine.isAvailable { engine = .signal }
    }
}
