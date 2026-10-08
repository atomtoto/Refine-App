import SwiftUI

/// The spectrogram is the hero of the track screen: the encoder's cut-off reads as a hard ceiling,
/// the restoration repaints the band above it, and a divider reveals before and after on the same picture.
struct SpectrogramRevealView: View {
    var original: UIImage?
    var restored: UIImage?
    /// Restored spectrogram painted so far while a restoration runs.
    var preview: CGImage?
    var progress: Double?
    var cutoff: Double?
    /// Playhead position, 0…1.
    var playhead: Double?
    @Binding var split: Double

    private let nyquist = AudioReader.targetSampleRate / 2
    private let gridFrequencies: [Double] = [5_000, 10_000, 15_000, 20_000]

    private var canCompare: Bool { original != nil && restored != nil && progress == nil }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Color.black

                if let original {
                    spectrogram(Image(uiImage: original))
                }
                if let progress, let preview {
                    spectrogram(Image(decorative: preview, scale: 1))
                    scanLine(at: progress, height: size.height)
                        .offset(x: size.width * progress)
                } else if canCompare, let restored {
                    spectrogram(Image(uiImage: restored))
                        .mask(alignment: .leading) {
                            Rectangle()
                                .frame(width: size.width * (1 - split))
                                .offset(x: size.width * split)
                        }
                }

                frequencyGrid(size: size)

                if let cutoff, cutoff < CutoffDetector.fullBandFrequency {
                    cutoffMarker(cutoff, size: size)
                }

                if let playhead {
                    Capsule()
                        .fill(.cyan)
                        .frame(width: 2)
                        .shadow(color: .cyan, radius: 4)
                        .offset(x: size.width * playhead - 1)
                        .allowsHitTesting(false)
                }

                if canCompare {
                    compareLabels
                    divider(height: size.height)
                        .offset(x: size.width * split - 22)
                }

                if original == nil {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard canCompare else { return }
                        split = min(max(value.location.x / size.width, 0), 1)
                    },
                isEnabled: canCompare)
        }
        .aspectRatio(1.9, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spectrogramme")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            guard canCompare else { return }
            switch direction {
            case .increment: split = min(split + 0.1, 1)
            case .decrement: split = max(split - 0.1, 0)
            @unknown default: break
            }
        }
    }

    private func spectrogram(_ image: Image) -> some View {
        image
            .resizable()
            .interpolation(.medium)
            .allowsHitTesting(false)
    }

    private func y(for frequency: Double, height: CGFloat) -> CGFloat {
        height * (1 - frequency / nyquist)
    }

    private func frequencyGrid(size: CGSize) -> some View {
        ForEach(gridFrequencies, id: \.self) { frequency in
            let y = y(for: frequency, height: size.height)
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 0.5)
                .offset(y: y)
            Text("\(Int(frequency / 1000)) k")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .padding(.leading, 6)
                .offset(y: y - 14)
        }
        .allowsHitTesting(false)
    }

    private func cutoffMarker(_ cutoff: Double, size: CGSize) -> some View {
        let y = y(for: cutoff, height: size.height)
        let showsLostBand = restored == nil && progress == nil
        return ZStack(alignment: .topTrailing) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))

            Label("Coupure \(cutoff.kilohertz)", systemImage: "scissors")
                .font(.caption2.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
                .padding(.trailing, 8)
                .offset(y: y + 6)

            if showsLostBand, y > 28 {
                Text("Aigus perdus")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: size.width, height: y)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func scanLine(at progress: Double, height: CGFloat) -> some View {
        Rectangle()
            .fill(.white)
            .frame(width: 2, height: height)
            .shadow(color: .white.opacity(0.8), radius: 6)
            .allowsHitTesting(false)
    }

    private var compareLabels: some View {
        HStack {
            Text("Original")
            Spacer()
            Text("Restauré")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
        .allowsHitTesting(false)
    }

    private func divider(height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(.white)
                .frame(width: 2, height: height)
            Image(systemName: "chevron.left.chevron.right")
                .font(.caption.weight(.bold))
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .frame(width: 44)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let cutoff { parts.append("Coupure à \(cutoff.kilohertz)") }
        if let progress { parts.append("Restauration \(Int(progress * 100)) %") }
        if canCompare { parts.append("Comparaison : \(Int((1 - split) * 100)) % restauré") }
        return parts.joined(separator: ", ")
    }
}
