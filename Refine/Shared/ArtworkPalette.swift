import CoreImage
import SwiftUI

/// Colours for the living background, sampled from the artwork's four quadrants.
enum ArtworkPalette {
    /// The spectrogram's own palette.
    static let fallback: [Color] = [
        Color(red: 0.36, green: 0.16, blue: 0.78),
        Color(red: 0.75, green: 0.20, blue: 0.62),
        Color(red: 0.98, green: 0.47, blue: 0.33),
        Color(red: 0.20, green: 0.32, blue: 0.85),
    ]

    /// Shades around the label of the vinyl shown for tracks without artwork.
    static func vinyl(hue: Double) -> [Color] {
        [0, 0.07, -0.07, 0.14].map { shift in
            Color(hue: (hue + shift + 1).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.85)
        }
    }

    /// `nil` when there is no readable artwork.
    @concurrent
    static func colors(from artwork: Data?) async -> [Color]? {
        guard let artwork, let image = CIImage(data: artwork) else { return nil }
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let extent = image.extent
        let half = CGSize(width: extent.width / 2, height: extent.height / 2)
        let quadrants = [
            CGRect(origin: CGPoint(x: extent.minX, y: extent.midY), size: half),
            CGRect(origin: CGPoint(x: extent.midX, y: extent.midY), size: half),
            CGRect(origin: CGPoint(x: extent.midX, y: extent.minY), size: half),
            CGRect(origin: CGPoint(x: extent.minX, y: extent.minY), size: half),
        ]
        let colors = quadrants.compactMap { rect -> Color? in
            guard let average = CIFilter(
                name: "CIAreaAverage",
                parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: rect)])?.outputImage
            else { return nil }
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(
                average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8, colorSpace: nil)
            return vivid(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
        }
        return colors.count == 4 ? colors : nil
    }

    /// Lifts dull averages so the mesh reads as colour rather than grey.
    private static func vivid(red: Double, green: Double, blue: Double) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        UIColor(red: red, green: green, blue: blue, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return Color(
            hue: hue,
            saturation: min(max(saturation * 1.3, 0.4), 0.9),
            brightness: min(max(brightness, 0.5), 0.92))
    }
}
