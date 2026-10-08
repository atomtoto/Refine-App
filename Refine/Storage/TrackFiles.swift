import Foundation

/// On-disk layout: `Application Support/Tracks/<id>/` holds the original, the restored file and the spectrograms.
enum TrackFiles {
    static let originalSpectrogramName = "spectrum-original.png"
    static let restoredSpectrogramName = "spectrum-restored.png"

    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Tracks", directoryHint: .isDirectory)
    }

    static func directory(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// Copies an imported file into the track's folder and returns the stored file name.
    static func importFile(at source: URL, id: UUID) throws -> String {
        let directory = directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "audio" : source.pathExtension.lowercased()
        let name = "original.\(ext)"
        try FileManager.default.copyItem(at: source, to: directory.appending(path: name))
        return name
    }

    static func removeFiles(for id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    /// A file name safe for sharing, e.g. "Artist – Title (Refine).m4a".
    static func exportName(title: String, artist: String?, fileExtension: String) -> String {
        let base = [artist, title].compactMap { $0 }.joined(separator: " – ")
        let safe = base.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return "\(safe.prefix(120)) (Refine).\(fileExtension)"
    }
}
