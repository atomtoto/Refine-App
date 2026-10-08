import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Tags read from the file itself.
struct TrackMetadata: Sendable {
    var title: String?
    var artist: String?
    /// Artwork downsampled for display.
    var artwork: Data?
    var thumbnail: Data?
    /// Declared bitrate, in kbps.
    var bitrate: Int?

    @concurrent
    static func load(from url: URL) async -> TrackMetadata {
        let asset = AVURLAsset(url: url)
        var metadata = TrackMetadata()
        if let items = try? await asset.load(.commonMetadata) {
            metadata.title = await string(for: .commonIdentifierTitle, in: items)
            metadata.artist = await string(for: .commonIdentifierArtist, in: items)
            if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first,
               let data = try? await item.load(.dataValue) {
                metadata.artwork = downsampled(data, maxPixelSize: 900)
                metadata.thumbnail = downsampled(data, maxPixelSize: 180)
            }
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let rate = try? await track.load(.estimatedDataRate), rate > 0 {
            metadata.bitrate = Int((rate / 1000).rounded())
        }
        return metadata
    }

    private static func string(for identifier: AVMetadataIdentifier, in items: [AVMetadataItem]) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first,
              let value = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func downsampled(_ data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
