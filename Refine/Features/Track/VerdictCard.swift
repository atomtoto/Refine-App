import SwiftUI

struct VerdictCard: View {
    var analysis: AudioAnalysis
    var restoredAnalysis: AudioAnalysis?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(analysis.verdict.title, systemImage: analysis.verdict.systemImage)
                        .font(.headline)
                        .foregroundStyle(tint)
                        .symbolRenderingMode(.hierarchical)
                    Text(explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Gauge(value: analysis.fidelity) {
                    Text("kHz")
                } currentValueLabel: {
                    Text((analysis.cutoffFrequency / 1000).formatted(.number.precision(.fractionLength(0))))
                }
                .gaugeStyle(.accessoryCircular)
                .tint(Gradient(colors: [.red, .orange, .yellow, .green]))
                .accessibilityLabel("Bande passante intacte")
                .accessibilityValue("\(Int(analysis.fidelity * 100)) %")
            }

            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Fact(title: "Format", value: analysis.codec.displayName)
                    Fact(title: "Débit", value: analysis.declaredBitrate.map { "\($0) kbps" } ?? "—")
                }
                GridRow {
                    Fact(title: "Coupure", value: analysis.cutoffFrequency.kilohertz)
                    Fact(
                        title: analysis.isClipped ? "Saturation" : "Source estimée",
                        value: analysis.isClipped
                            ? "Détectée" : analysis.estimatedBitrate.map { "≈ \($0) kbps" } ?? "Sans perte")
                }
            }

            if let restoredAnalysis {
                Divider()
                Label {
                    Text("Après Refine : spectre étendu jusqu'à \(restoredAnalysis.cutoffFrequency.kilohertz), en 16 bits · 44,1 kHz.")
                } icon: {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                }
                .font(.subheadline)
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var tint: Color {
        switch analysis.verdict {
        case .authenticLossless: .green
        case .transparentLossy: .teal
        case .fakeLossless: .orange
        case .lossy: .pink
        }
    }

    private var explanation: String {
        let cutoff = analysis.cutoffFrequency.kilohertz
        let source = analysis.estimatedBitrate.map { "≈ \($0) kbps" } ?? "compressée"
        switch analysis.verdict {
        case .authenticLossless:
            return "Le spectre s'étend jusqu'à \(cutoff) : ce fichier n'a jamais été compressé avec perte."
        case .fakeLossless:
            return "Malgré son format sans perte, tout est coupé au-dessus de \(cutoff) : c'est une source \(source) convertie."
        case .transparentLossy:
            return "La coupure à \(cutoff) est presque inaudible. La restauration aura un effet subtil."
        case .lossy:
            return "La compression a supprimé tout ce qui dépasse \(cutoff) (source \(source)). Refine peut reconstruire ces aigus."
        }
    }
}

private struct Fact: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
