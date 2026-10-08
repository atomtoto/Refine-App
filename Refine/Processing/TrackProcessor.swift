import Foundation
import Observation
import SwiftData

/// Owns long-running work (analysis, restoration) so it survives navigation, and publishes its progress.
@MainActor
@Observable
final class TrackProcessor {
    struct RestorationState {
        var fraction: Double
        var preview: SpectrogramImage?
    }

    private(set) var analyzing: Set<UUID> = []
    private(set) var restorations: [UUID: RestorationState] = [:]
    var lastError: String?

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let engine: any RestorationEngine = DSPRestorationEngine()

    // MARK: - Import

    @discardableResult
    func importFiles(_ urls: [URL], into context: ModelContext) -> [Track] {
        var imported: [Track] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let id = UUID()
            do {
                let fileName = try TrackFiles.importFile(at: url, id: id)
                let track = Track(id: id, title: url.deletingPathExtension().lastPathComponent, originalFileName: fileName)
                context.insert(track)
                imported.append(track)
                analyze(track)
            } catch {
                TrackFiles.removeFiles(for: id)
                lastError = "Impossible d'importer « \(url.lastPathComponent) » : \(error.localizedDescription)"
            }
        }
        return imported
    }

    // MARK: - Analysis

    func analyze(_ track: Track) {
        let id = track.id
        let url = track.originalURL
        let spectrogramURL = track.originalSpectrogramURL
        analyzing.insert(id)
        track.failureMessage = nil
        tasks[id] = Task {
            defer {
                analyzing.remove(id)
                tasks[id] = nil
            }
            async let metadata = TrackMetadata.load(from: url)
            do {
                let output = try await AudioAnalyzer.analyze(url: url)
                let tags = await metadata
                if let title = tags.title { track.title = title }
                track.artist = tags.artist
                track.artworkData = tags.artwork
                track.thumbnailData = tags.thumbnail
                var analysis = output.analysis
                analysis.declaredBitrate = tags.bitrate
                try output.spectrogramPNG?.write(to: spectrogramURL)
                track.analysis = analysis
            } catch is CancellationError {
            } catch {
                _ = await metadata
                track.failureMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Restoration

    func isRestoring(_ track: Track) -> Bool { restorations[track.id] != nil }

    func restore(_ track: Track) {
        guard let analysis = track.analysis, restorations[track.id] == nil else { return }
        let id = track.id
        let settings = track.settings
        let finalName = TrackFiles.exportName(
            title: track.title, artist: track.artist, fileExtension: settings.exportFormat.fileExtension)
        let workingURL = track.directory.appending(path: "restoring.\(settings.exportFormat.fileExtension)")
        let job = RestorationJob(source: track.originalURL, destination: workingURL, analysis: analysis, settings: settings)
        let spectrogramURL = track.restoredSpectrogramURL
        try? FileManager.default.removeItem(at: workingURL)

        restorations[id] = RestorationState(fraction: 0)
        tasks[id] = Task {
            defer {
                restorations[id] = nil
                tasks[id] = nil
            }
            do {
                for try await event in engine.restore(job) {
                    switch event {
                    case .progress(let fraction, let preview):
                        restorations[id] = RestorationState(fraction: fraction, preview: preview)
                    case .finished(let output):
                        if let previous = track.restoredURL { try? FileManager.default.removeItem(at: previous) }
                        let finalURL = track.directory.appending(path: finalName)
                        try? FileManager.default.removeItem(at: finalURL)
                        try FileManager.default.moveItem(at: workingURL, to: finalURL)
                        try output.spectrogramPNG?.write(to: spectrogramURL)
                        track.restoredFileName = finalName
                        track.restoredAnalysis = output.analysis
                        track.restoredAt = .now
                    }
                }
                try Task.checkCancellation()
            } catch {
                try? FileManager.default.removeItem(at: workingURL)
                if !(error is CancellationError) {
                    lastError = "La restauration a échoué : \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelRestoration(_ track: Track) {
        tasks[track.id]?.cancel()
    }

    // MARK: - Deletion

    func delete(_ track: Track, from context: ModelContext) {
        tasks[track.id]?.cancel()
        TrackFiles.removeFiles(for: track.id)
        context.delete(track)
    }
}
