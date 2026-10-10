import ActivityKit
import SwiftUI
import WidgetKit

/// Restoration progress on the Lock Screen and in the Dynamic Island: the track's vinyl, and a spectrum whose bars
/// light up from the lows to the rebuilt highs as the work advances.
struct RestorationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestorationActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, phase: context.displayedPhase, state: context.state)
                .activityBackgroundTint(.refineNight.opacity(0.9))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let phase = context.displayedPhase
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityVinyl(colors: context.attributes.colors, fraction: context.state.fraction)
                        .frame(width: 52, height: 52)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ProgressBadge(phase: phase, fraction: context.state.fraction)
                        .font(.title2.weight(.semibold))
                        .frame(maxHeight: .infinity)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    TrackTitle(attributes: context.attributes)
                        .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        SpectrumProgress(phase: phase, fraction: context.state.fraction)
                            .frame(height: 30)
                        StatusLabel(attributes: context.attributes, phase: phase, stage: context.state.stage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                ActivityVinyl(colors: context.attributes.colors, fraction: context.state.fraction)
                    .frame(width: 22, height: 22)
            } compactTrailing: {
                ProgressBadge(phase: phase, fraction: context.state.fraction)
                    .font(.caption.weight(.semibold))
            } minimal: {
                switch phase {
                case .restoring:
                    ProgressView(value: context.state.fraction)
                        .progressViewStyle(.circular)
                        .tint(.refineAmber)
                default:
                    ProgressBadge(phase: phase, fraction: context.state.fraction)
                }
            }
            .keylineTint(context.attributes.colors.first ?? .refineAmber)
        }
    }
}

private extension ActivityViewContext<RestorationActivityAttributes> {
    /// A restoration whose updates stopped (iOS suspended or closed the app) reads as paused rather than stuck.
    var displayedPhase: RestorationActivityAttributes.ContentState.Phase {
        state.phase == .restoring && isStale ? .paused : state.phase
    }
}

private extension RestorationActivityAttributes {
    var colors: [Color] { labelColors.map(Color.init) }
}

private extension Color {
    static let refineNight = Color(red: 0.07, green: 0.03, blue: 0.16)
    static let refineAmber = Color(red: 1.0, green: 0.64, blue: 0.30)
    /// The spectrogram palette, from the loud lows to the quiet highs.
    static let spectrum = [refineAmber, Color(red: 0.95, green: 0.33, blue: 0.42), Color(red: 0.70, green: 0.17, blue: 0.62), Color(red: 0.42, green: 0.19, blue: 0.82)]
}

// MARK: - Lock Screen

private struct LockScreenView: View {
    var attributes: RestorationActivityAttributes
    var phase: RestorationActivityAttributes.ContentState.Phase
    var state: RestorationActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ActivityVinyl(colors: attributes.colors, fraction: state.fraction)
                    .frame(width: 48, height: 48)
                TrackTitle(attributes: attributes)
                Spacer(minLength: 8)
                ProgressBadge(phase: phase, fraction: state.fraction)
                    .font(.title2.weight(.semibold))
            }
            SpectrumProgress(phase: phase, fraction: state.fraction)
                .frame(height: 34)
            StatusLabel(attributes: attributes, phase: phase, stage: state.stage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Pieces

private struct TrackTitle: View {
    var attributes: RestorationActivityAttributes

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(attributes.title)
                .font(.headline)
            Text(attributes.artist ?? "Artiste inconnu")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProgressBadge: View {
    var phase: RestorationActivityAttributes.ContentState.Phase
    var fraction: Double

    var body: some View {
        switch phase {
        case .restoring:
            Text(fraction, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText(value: fraction))
        case .paused:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("En pause")
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.refineAmber)
                .accessibilityLabel("Terminé")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityLabel("Échec")
        }
    }
}

private struct StatusLabel: View {
    var attributes: RestorationActivityAttributes
    var phase: RestorationActivityAttributes.ContentState.Phase
    var stage: RestorationActivityAttributes.ContentState.Stage

    var body: some View {
        switch (phase, stage, attributes.engine) {
        case (.restoring, .engine, .apollo):
            Label("Restauration par l'IA Apollo", systemImage: "brain")
        case (.restoring, .engine, .signal):
            Label("Reconstruction des aigus", systemImage: "wand.and.sparkles")
        case (.restoring, .finishing, _):
            Label("Finitions : équilibre, attaques, volume", systemImage: "slider.horizontal.3")
        case (.paused, _, _):
            Label("En pause · rouvrez Refine pour continuer", systemImage: "pause.circle")
        case (.finished, _, _):
            Label("Restauré · prêt à écouter", systemImage: "sparkles")
        case (.failed, _, _):
            Label("La restauration a échoué", systemImage: "exclamationmark.triangle")
        }
    }
}

/// The track's record, its label in the cover's colours. The print on the label turns as the work advances.
private struct ActivityVinyl: View {
    var colors: [Color]
    var fraction: Double

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .fill(EllipticalGradient(
                        colors: [Color(white: 0.18), Color(white: 0.04)], startRadiusFraction: 0.15, endRadiusFraction: 0.5))
                ForEach([0.6, 0.72, 0.84], id: \.self) { groove in
                    Circle()
                        .stroke(.white.opacity(0.09), lineWidth: max(0.5, size * 0.012))
                        .frame(width: size * groove, height: size * groove)
                }
                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 0.5)
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle()
                        .trim(from: 0.58, to: 0.9)
                        .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: max(1, size * 0.035), lineCap: .round))
                        .padding(size * 0.08)
                }
                .frame(width: size * 0.44, height: size * 0.44)
                .rotationEffect(.degrees(fraction * 1_080))
                Circle()
                    .fill(Color(white: 0.03))
                    .frame(width: max(2, size * 0.07), height: max(2, size * 0.07))
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// A spectrum of the track rebuilt from left to right: the lows first, the restored highs last.
private struct SpectrumProgress: View {
    var phase: RestorationActivityAttributes.ContentState.Phase
    var fraction: Double

    /// Bar heights shaped like a music spectrum: strong lows, then a slow slope towards the highs.
    private static let levels: [Double] = [
        0.52, 0.8, 0.96, 1, 0.86, 0.93, 0.78, 0.84, 0.7, 0.76, 0.64, 0.69, 0.58, 0.62, 0.53,
        0.57, 0.49, 0.52, 0.45, 0.47, 0.41, 0.44, 0.38, 0.4, 0.35, 0.37, 0.32, 0.33, 0.29, 0.27,
    ]

    /// How much of each bar is lit: whole bars behind the progress, a partial one at the front.
    private func light(_ index: Int) -> Double {
        let progress = phase == .finished ? 1 : fraction
        return min(max(progress * Double(Self.levels.count) - Double(index), 0), 1)
    }

    private var litStyle: AnyShapeStyle {
        switch phase {
        case .restoring, .finished:
            AnyShapeStyle(LinearGradient(colors: Color.spectrum, startPoint: .bottom, endPoint: .top))
        case .paused:
            AnyShapeStyle(.white.opacity(0.5))
        case .failed:
            AnyShapeStyle(.yellow.opacity(0.6))
        }
    }

    private func bars(lit: Bool) -> some View {
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Self.levels.indices, id: \.self) { index in
                    Capsule()
                        .fill(.white)
                        .opacity(lit ? light(index) : 1)
                        .frame(height: max(4, proxy.size.height * Self.levels[index]))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    var body: some View {
        // One gradient across the whole field, so a bar's colour follows its height like on a spectrogram.
        ZStack {
            bars(lit: false)
                .opacity(0.16)
            Rectangle()
                .fill(litStyle)
                .mask { bars(lit: true) }
        }
        .accessibilityElement()
        .accessibilityLabel("Progression")
        .accessibilityValue(Text(phase == .finished ? 1 : fraction, format: .percent.precision(.fractionLength(0))))
    }
}

// MARK: - Previews

private extension RestorationActivityAttributes {
    static let preview = RestorationActivityAttributes(
        title: "Golden Hour", artist: "Les Synthes", engine: .apollo,
        labelColors: [Color(red: 0.98, green: 0.6, blue: 0.3), Color(red: 0.2, green: 0.45, blue: 0.55)]
            .map { $0.resolve(in: EnvironmentValues()) })
}

#Preview("Écran verrouillé", as: .content, using: RestorationActivityAttributes.preview) {
    RestorationLiveActivity()
} contentStates: {
    RestorationActivityAttributes.ContentState(phase: .restoring, fraction: 0.42, stage: .engine)
    RestorationActivityAttributes.ContentState(phase: .restoring, fraction: 0.91, stage: .finishing)
    RestorationActivityAttributes.ContentState(phase: .paused, fraction: 0.6, stage: .engine)
    RestorationActivityAttributes.ContentState(phase: .finished, fraction: 1, stage: .finishing)
}

#Preview("Île dynamique", as: .dynamicIsland(.expanded), using: RestorationActivityAttributes.preview) {
    RestorationLiveActivity()
} contentStates: {
    RestorationActivityAttributes.ContentState(phase: .restoring, fraction: 0.42, stage: .engine)
}
