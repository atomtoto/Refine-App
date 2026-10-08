import Foundation
import SwiftData

@Model
final class Track {
    @Attribute(.unique) var id: UUID
    var title: String
    var artist: String?
    @Attribute(.externalStorage) var artworkData: Data?
    var thumbnailData: Data?
    var originalFileName: String
    var restoredFileName: String?
    var importedAt: Date
    var restoredAt: Date?
    /// Display name of the engine that produced the restored file.
    var restoredEngine: String?
    var failureMessage: String?
    var analysisData: Data?
    var restoredAnalysisData: Data?
    var settingsData: Data?

    init(id: UUID = UUID(), title: String, originalFileName: String) {
        self.id = id
        self.title = title
        self.originalFileName = originalFileName
        self.importedAt = .now
    }
}

extension Track {
    var analysis: AudioAnalysis? {
        get { analysisData.flatMap { try? JSONDecoder().decode(AudioAnalysis.self, from: $0) } }
        set { analysisData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var restoredAnalysis: AudioAnalysis? {
        get { restoredAnalysisData.flatMap { try? JSONDecoder().decode(AudioAnalysis.self, from: $0) } }
        set { restoredAnalysisData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var settings: RestorationSettings {
        get { settingsData.flatMap { try? JSONDecoder().decode(RestorationSettings.self, from: $0) } ?? RestorationSettings() }
        set { settingsData = try? JSONEncoder().encode(newValue) }
    }

    var directory: URL { TrackFiles.directory(for: id) }
    var originalURL: URL { directory.appending(path: originalFileName) }
    var restoredURL: URL? { restoredFileName.map { directory.appending(path: $0) } }
    var originalSpectrogramURL: URL { directory.appending(path: TrackFiles.originalSpectrogramName) }
    var restoredSpectrogramURL: URL { directory.appending(path: TrackFiles.restoredSpectrogramName) }
    var isRestored: Bool { restoredFileName != nil }
}
