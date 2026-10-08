import CoreML
import Foundation

enum ApolloError: LocalizedError {
    case modelMissing
    case unexpectedOutput

    var errorDescription: String? {
        switch self {
        case .modelMissing: "Le modèle Apollo n'est pas inclus dans cette version de l'app."
        case .unexpectedOutput: "Le modèle Apollo a renvoyé un résultat inattendu."
        }
    }
}

/// Apollo (Kai Li & Yi Luo, CC BY-SA 4.0), converted to Core ML by `Tools/ConvertApollo`.
///
/// The bundled network covers everything between Apollo's feature extraction and its iSTFT. This adapter
/// computes those features in float32 — per band: real and imaginary parts normalised by the band's power,
/// plus the log of that power — so the model's float16 layers never see the raw, large spectral powers.
///
/// Contract: input `features` `[964, frames]`, outputs `real` and `imag` `[442, frames]`.
final class ApolloModel: SpectralModel {
    static let resourceName = "RefineApollo"
    static let sampleRate: Double = 44_100
    static let frameSize = 882
    static let hop = 441

    static var compiledURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: "mlmodelc")
    }

    static var isBundled: Bool { compiledURL != nil }

    let frameCount: Int
    let binCount: Int
    private let model: MLModel
    private let bandWidths: [Int]
    private let epsilon: Float
    private let featureRows: Int

    init(computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        guard let url = Self.compiledURL else { throw ApolloError.modelMissing }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: configuration)

        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        bandWidths = metadata["band_widths"]?.split(separator: ",").compactMap { Int($0) }
            ?? Array(repeating: 5, count: 79) + [47]
        epsilon = metadata["eps"].flatMap(Float.init) ?? Float.ulpOfOne
        binCount = bandWidths.reduce(0, +)
        featureRows = bandWidths.reduce(0) { $0 + 2 * $1 + 1 }
        let shape = model.modelDescription.inputDescriptionsByName["features"]?.multiArrayConstraint?.shape
        frameCount = shape?.last?.intValue ?? 256
    }

    func transform(real: inout [Float], imag: inout [Float]) throws {
        let input = try MLMultiArray(shape: [NSNumber(value: featureRows), NSNumber(value: frameCount)], dataType: .float32)
        fillFeatures(input, real: real, imag: imag)
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["features": input]))
        guard let restoredReal = output.featureValue(for: "real")?.multiArrayValue,
              let restoredImag = output.featureValue(for: "imag")?.multiArrayValue
        else { throw ApolloError.unexpectedOutput }
        real = try Self.matrix(from: restoredReal, rows: binCount, columns: frameCount)
        imag = try Self.matrix(from: restoredImag, rows: binCount, columns: frameCount)
    }

    /// Writes `[real/p, imag/p, log p]` for each band, row-major `[featureRows × frameCount]`.
    private func fillFeatures(_ array: MLMultiArray, real: [Float], imag: [Float]) {
        let frames = frameCount
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { features, strides in
            let rowStride = strides[0]
            var bin = 0
            var row = 0
            for width in bandWidths {
                for t in 0..<frames {
                    var power: Float = 0
                    for k in bin..<(bin + width) {
                        let index = k * frames + t
                        power += real[index] * real[index] + imag[index] * imag[index]
                    }
                    let magnitude = (power + epsilon).squareRoot()
                    for offset in 0..<width {
                        let index = (bin + offset) * frames + t
                        features[(row + offset) * rowStride + t] = real[index] / magnitude
                        features[(row + width + offset) * rowStride + t] = imag[index] / magnitude
                    }
                    features[(row + 2 * width) * rowStride + t] = log(magnitude)
                }
                bin += width
                row += 2 * width + 1
            }
        }
    }

    /// Copies a `[rows, columns]` output into a dense row-major array, whatever its strides or precision.
    private static func matrix(from array: MLMultiArray, rows: Int, columns: Int) throws -> [Float] {
        guard array.count == rows * columns, array.shape.count == 2 else { throw ApolloError.unexpectedOutput }
        let rowStride = array.strides[0].intValue
        let columnStride = array.strides[1].intValue
        var result = [Float](repeating: 0, count: rows * columns)
        switch array.dataType {
        case .float32:
            array.withUnsafeBufferPointer(ofType: Float.self) { source in
                for r in 0..<rows {
                    for c in 0..<columns { result[r * columns + c] = source[r * rowStride + c * columnStride] }
                }
            }
        case .float16:
            array.withUnsafeBufferPointer(ofType: Float16.self) { source in
                for r in 0..<rows {
                    for c in 0..<columns { result[r * columns + c] = Float(source[r * rowStride + c * columnStride]) }
                }
            }
        default:
            for r in 0..<rows {
                for c in 0..<columns { result[r * columns + c] = array[[r, c] as [NSNumber]].floatValue }
            }
        }
        return result
    }
}

extension RestorationSettings.ComputeUnits {
    var coreML: MLComputeUnits {
        switch self {
        case .gpu: .cpuAndGPU
        case .cpu: .cpuOnly
        }
    }
}
