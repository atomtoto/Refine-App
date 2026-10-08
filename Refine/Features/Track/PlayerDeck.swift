import SwiftUI

/// Floating transport: play/pause, position, and the instant A/B switch.
struct PlayerDeck: View {
    @Bindable var player: ABPlayer
    @State private var scrubbing: TimeInterval?

    var body: some View {
        VStack(spacing: 12) {
            if player.hasRestored {
                Picker("Écoute", selection: $player.source) {
                    Text("Original").tag(ABPlayer.Source.original)
                    Text("Restauré").tag(ABPlayer.Source.restored)
                }
                .pickerStyle(.segmented)
                .sensoryFeedback(.selection, trigger: player.source)
            }

            HStack(spacing: 14) {
                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .font(.title2)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Lecture")

                VStack(spacing: 2) {
                    Slider(
                        value: Binding(
                            get: { scrubbing ?? player.currentTime },
                            set: { scrubbing = $0 }),
                        in: 0...max(player.duration, 0.1)
                    ) { editing in
                        if !editing, let target = scrubbing {
                            player.seek(to: target)
                            scrubbing = nil
                        }
                    }
                    .accessibilityLabel("Position")

                    HStack {
                        Text((scrubbing ?? player.currentTime).playbackTime)
                        Spacer()
                        Text("-" + (player.duration - (scrubbing ?? player.currentTime)).playbackTime)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
            }

            if player.isBluetoothOutput {
                Label("Écoute Bluetooth : le casque recompresse le son. Comparez de préférence en filaire.", systemImage: "headphones")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
    }
}
