import SwiftUI

/// A slowly drifting mesh gradient tinted by the artwork, which breathes with the music while it plays.
struct LivingBackground: View {
    var colors: [Color]
    /// Playback level, 0…1.
    var level: Float

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3, points: points(at: time), colors: meshColors)
        }
        .opacity(colorScheme == .dark ? 0.55 : 0.4)
        .background(.background)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var meshColors: [Color] {
        let palette = colors.count >= 4 ? colors : ArtworkPalette.fallback
        let calm = Color(uiColor: .systemBackground)
        return [
            palette[0], palette[1], palette[2],
            palette[3], calm, palette[0],
            palette[2], palette[3], palette[1],
        ]
    }

    private func points(at time: TimeInterval) -> [SIMD2<Float>] {
        let amplitude = 0.07 + 0.1 * Double(level)
        func drift(_ speed: Double, _ phase: Double) -> Float {
            Float(sin(time * speed + phase) * amplitude)
        }
        return [
            [0, 0], [0.5 + drift(0.31, 0), 0], [1, 0],
            [0, 0.5 + drift(0.27, 1)], [0.5 + drift(0.43, 2), 0.5 + drift(0.37, 3)], [1, 0.5 + drift(0.33, 4)],
            [0, 1], [0.5 + drift(0.29, 5), 1], [1, 1],
        ]
    }
}

#Preview {
    LivingBackground(colors: ArtworkPalette.fallback, level: 0.3)
}
