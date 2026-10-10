import SwiftUI

struct TrackRow: View {
    var track: Track

    @Environment(TrackProcessor.self) private var processor

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(data: track.thumbnailData, seed: track.id)
                .frame(width: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(track.artist ?? "Artiste inconnu")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                status
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var status: some View {
        if let restoration = processor.restorations[track.id] {
            ProgressView(value: restoration.fraction) {
                Text("Restauration…")
            }
            .progressViewStyle(.linear)
        } else if processor.analyzing.contains(track.id) {
            Label("Analyse du spectre…", systemImage: "waveform")
                .symbolEffect(.variableColor.iterative)
                .foregroundStyle(.secondary)
        } else if track.failureMessage != nil {
            Label("Illisible", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        } else if let analysis = track.analysis {
            HStack(spacing: 10) {
                Label(analysis.verdict.title, systemImage: analysis.verdict.systemImage)
                    .foregroundStyle(analysis.hasMissingHighs ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                if track.isRestored {
                    Label("Restauré", systemImage: "sparkles")
                        .foregroundStyle(.tint)
                }
            }
            .labelStyle(.titleAndIcon)
        }
    }
}
