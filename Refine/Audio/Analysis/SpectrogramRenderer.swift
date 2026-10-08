import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An immutable `CGImage` handed across concurrency domains.
struct SpectrogramImage: @unchecked Sendable {
    let cgImage: CGImage
}

enum SpectrogramRenderer {
    static let floorDecibels: Float = -115
    static let ceilingDecibels: Float = -25

    /// Deep indigo → violet → magenta → amber → cream, the app's signature palette.
    private static let stops: [(position: Float, color: SIMD3<Float>)] = [
        (0.00, [0.03, 0.02, 0.09]),
        (0.22, [0.17, 0.06, 0.38]),
        (0.45, [0.52, 0.11, 0.58]),
        (0.65, [0.89, 0.28, 0.45]),
        (0.83, [0.99, 0.60, 0.27]),
        (1.00, [1.00, 0.95, 0.74]),
    ]

    static func color(at value: Float) -> SIMD3<Float> {
        let t = min(max(value, 0), 1)
        for (lower, upper) in zip(stops, stops.dropFirst()) where t <= upper.position {
            let local = (t - lower.position) / (upper.position - lower.position)
            return lower.color + (upper.color - lower.color) * local
        }
        return stops[stops.count - 1].color
    }

    /// Renders power columns (relative to full scale, low frequency first). `nil` columns are transparent.
    static func image(columns: [[Float]?], rows: Int) -> CGImage? {
        let width = columns.count
        guard width > 0, rows > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * rows * 4)
        let range = ceilingDecibels - floorDecibels

        for (x, column) in columns.enumerated() {
            guard let column else { continue }
            for row in 0..<rows {
                let decibels = 10 * log10(max(column[row], 1e-20))
                let rgb = color(at: (decibels - floorDecibels) / range)
                let y = rows - 1 - row
                let index = (y * width + x) * 4
                pixels[index] = UInt8(rgb.x * 255)
                pixels[index + 1] = UInt8(rgb.y * 255)
                pixels[index + 2] = UInt8(rgb.z * 255)
                pixels[index + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
