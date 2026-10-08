import SwiftData
import SwiftUI

struct TrackDetailView: View {
    @Bindable var track: Track

    @Environment(TrackProcessor.self) private var processor
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var player = ABPlayer()
    @State private var originalSpectrogram: UIImage?
    @State private var restoredSpectrogram: UIImage?
    @State private var palette = ArtworkPalette.fallback
    @State private var split = 0.5
    @State private var showingSettings = false
    @State private var confirmingDeletion = false

    private var restoration: TrackProcessor.RestorationState? { processor.restorations[track.id] }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                if let failure = track.failureMessage {
                    ContentUnavailableView("Lecture impossible", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else {
                    if let analysis = track.analysis {
                        VerdictCard(analysis: analysis, restoredAnalysis: track.restoredAnalysis)
                    }
                    spectrumSection
                    actions
                }
            }
            .padding()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .background { LivingBackground(colors: palette, level: player.level) }
        .safeAreaInset(edge: .bottom) {
            if track.analysis != nil {
                PlayerDeck(player: player)
                    .frame(maxWidth: 720)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .navigationTitle(track.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingSettings) {
            RestoreSettingsView(settings: track.settings, analysis: track.analysis) { settings in
                track.settings = settings
                processor.restore(track)
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Supprimer « \(track.title) » ?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                player.stop()
                processor.delete(track, from: modelContext)
                dismiss()
            }
        } message: {
            Text("L'original importé et la version restaurée seront effacés.")
        }
        .task(id: track.artworkData) {
            palette = await ArtworkPalette.colors(from: track.artworkData)
        }
        .task(id: MediaKey(analyzed: track.analysisData != nil, restoredAt: track.restoredAt)) {
            loadMedia()
        }
        .onDisappear { player.stop() }
        .sensoryFeedback(.success, trigger: track.restoredAt)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 14) {
            ArtworkView(data: track.artworkData, cornerRadius: 24)
                .frame(maxWidth: 200)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 10)

            VStack(spacing: 4) {
                Text(track.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(track.artist ?? "Artiste inconnu")
                    .font(.body)
                    .foregroundStyle(.secondary)
                if let analysis = track.analysis {
                    Text("\(analysis.formatSummary) · \(analysis.duration.playbackTime)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.top, 8)
    }

    private var spectrumSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Spectre")
                    .font(.headline)
                Spacer()
                if track.isRestored, restoration == nil {
                    Text("Glissez pour comparer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            SpectrogramRevealView(
                original: originalSpectrogram,
                restored: restoredSpectrogram,
                preview: restoration?.preview?.cgImage,
                progress: restoration?.fraction,
                cutoff: track.analysis?.cutoffFrequency,
                playhead: player.duration > 0 && (player.isPlaying || player.currentTime > 0)
                    ? player.currentTime / player.duration : nil,
                split: $split)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let restoration {
            VStack(spacing: 12) {
                ProgressView(value: restoration.fraction) {
                    Label("Reconstruction des aigus…", systemImage: "wand.and.sparkles")
                        .symbolEffect(.pulse)
                } currentValueLabel: {
                    Text(restoration.fraction.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                }
                Button("Annuler", role: .cancel) { processor.cancelRestoration(track) }
                    .buttonStyle(.glass)
            }
            .padding(20)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
        } else if track.analysis != nil {
            GlassEffectContainer {
                if let restoredURL = track.restoredURL {
                    HStack(spacing: 12) {
                        ShareLink(item: restoredURL) {
                            Label("Exporter", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)

                        Button("Refaire", systemImage: "slider.horizontal.3") { showingSettings = true }
                            .buttonStyle(.glass)
                    }
                    .controlSize(.large)
                } else {
                    VStack(spacing: 12) {
                        Button {
                            processor.restore(track)
                        } label: {
                            Label("Restaurer en qualité CD", systemImage: "wand.and.sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)

                        Button("Réglages de restauration", systemImage: "slider.horizontal.3") { showingSettings = true }
                            .buttonStyle(.glass)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu("Plus", systemImage: "ellipsis") {
                Button("Réglages de restauration", systemImage: "slider.horizontal.3") { showingSettings = true }
                    .disabled(track.analysis == nil || restoration != nil)
                ShareLink(item: track.originalURL) {
                    Label("Partager l'original", systemImage: "doc.on.doc")
                }
                Divider()
                Button("Supprimer", systemImage: "trash", role: .destructive) { confirmingDeletion = true }
            }
        }
    }

    // MARK: - Loading

    private struct MediaKey: Hashable {
        var analyzed: Bool
        var restoredAt: Date?
    }

    private func loadMedia() {
        originalSpectrogram = UIImage(contentsOfFile: track.originalSpectrogramURL.path(percentEncoded: false))
        restoredSpectrogram = track.isRestored ? UIImage(contentsOfFile: track.restoredSpectrogramURL.path(percentEncoded: false)) : nil
        guard track.analysis != nil else { return }
        let wasPlaying = player.isPlaying
        let position = player.currentTime
        try? player.load(original: track.originalURL, restored: track.restoredURL)
        if track.isRestored { player.source = .restored }
        player.seek(to: position)
        if wasPlaying { player.play() }
    }
}

/// Square artwork, or a tinted placeholder.
struct ArtworkView: View {
    var data: Data?
    var cornerRadius: CGFloat

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.accentColor.gradient)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 200))
                            .minimumScaleFactor(0.1)
                            .padding(24)
                            .foregroundStyle(.white.opacity(0.85))
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }
}
