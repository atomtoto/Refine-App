import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Query(sort: \Track.importedAt, order: .reverse) private var tracks: [Track]
    @Environment(TrackProcessor.self) private var processor
    @Environment(\.modelContext) private var modelContext

    @State private var selection: Track?
    @State private var searchText = ""
    @State private var importing = false
    @State private var showingSettings = false

    private static let importableTypes: [UTType] = [.mp3, .audio, .mpeg4Audio, .wav, .aiff]
        + [UTType("org.xiph.flac")].compactMap { $0 }

    private var filteredTracks: [Track] {
        guard !searchText.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedStandardContains(searchText) || ($0.artist?.localizedStandardContains(searchText) ?? false)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(filteredTracks) { track in
                    NavigationLink(value: track) {
                        TrackRow(track: track)
                    }
                    .swipeActions {
                        Button("Supprimer", systemImage: "trash", role: .destructive) { delete(track) }
                    }
                    .contextMenu {
                        if let restoredURL = track.restoredURL {
                            ShareLink(item: restoredURL) {
                                Label("Partager la version restaurée", systemImage: "square.and.arrow.up")
                            }
                        }
                        ShareLink(item: track.originalURL) {
                            Label("Partager l'original", systemImage: "doc.on.doc")
                        }
                        Divider()
                        Button("Supprimer", systemImage: "trash", role: .destructive) { delete(track) }
                    }
                }
            }
            .navigationTitle("Refine")
            .searchable(text: $searchText, prompt: "Titre ou artiste")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Réglages", systemImage: "gearshape") { showingSettings = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Importer", systemImage: "plus") { importing = true }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .overlay {
                if tracks.isEmpty {
                    emptyState
                } else if filteredTracks.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        } detail: {
            if let selection {
                NavigationStack {
                    TrackDetailView(track: selection)
                        .id(selection.id)
                }
            } else {
                ContentUnavailableView(
                    "Aucun morceau sélectionné",
                    systemImage: "waveform",
                    description: Text("Choisissez un morceau pour voir son spectre."))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importableTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .onOpenURL { importFiles([$0]) }
        .task { processor.resumeInterruptedWork(tracks) }
        .alert(
            "Oups",
            isPresented: Binding(get: { processor.lastError != nil }, set: { if !$0 { processor.lastError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(processor.lastError ?? "")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Redonnez de l'air à vos MP3", systemImage: "waveform.badge.magnifyingglass")
        } description: {
            Text("Importez un fichier : Refine révèle ce que la compression a coupé, puis reconstruit les aigus et l'exporte en qualité CD.")
        } actions: {
            Button("Importer un fichier", systemImage: "plus") { importing = true }
                .buttonStyle(.glassProminent)
        }
    }

    private func importFiles(_ urls: [URL]) {
        let imported = processor.importFiles(urls, into: modelContext)
        if imported.count == 1 { selection = imported.first }
    }

    private func delete(_ track: Track) {
        if selection == track { selection = nil }
        processor.delete(track, from: modelContext)
    }
}
