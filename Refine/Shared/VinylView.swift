import SwiftUI

/// The track as a record: its cover printed on the label or, without one, a label colour drawn from the track so
/// each track keeps its own. It turns at 33⅓ rpm while the track plays, under a reflection that stays put like
/// light on a real disc.
struct VinylView: View {
    var hue: Double
    var artwork: UIImage?
    var spinning = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var restingAngle = 0.0
    @State private var spinStart: Date?

    private static let degreesPerSecond = 360 * (100.0 / 3) / 60

    var body: some View {
        TimelineView(.animation(paused: spinStart == nil)) { context in
            disc
                .rotationEffect(.degrees(angle(at: context.date)))
        }
        .overlay { reflection }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: spinning && !reduceMotion, initial: true) { _, turning in
            let now = Date.now
            if turning {
                spinStart = now
            } else if spinStart != nil {
                restingAngle = angle(at: now)
                spinStart = nil
            }
        }
    }

    private func angle(at date: Date) -> Double {
        let elapsed = spinStart.map { date.timeIntervalSince($0) } ?? 0
        return (restingAngle + elapsed * Self.degreesPerSecond).truncatingRemainder(dividingBy: 360)
    }


    private var disc: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            func circle(_ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            }

            context.fill(circle(radius), with: .radialGradient(
                Gradient(colors: [Color(white: 0.16), Color(white: 0.05)]),
                center: center, startRadius: radius * 0.3, endRadius: radius))

            // A printed cover gets a bigger label so it stays recognisable at list size.
            let label = radius * (artwork == nil ? 0.34 : 0.44)

            // Grooves, with the wider gaps between songs.
            let grooves = Int(min(max(radius / 2.2, 10), 60))
            let innerGroove = label / radius + 0.06
            for index in 0..<grooves {
                let position = Double(index) / Double(grooves - 1)
                let opacity = index.isMultiple(of: 2) ? 0.07 : 0.035
                context.stroke(
                    circle(radius * (innerGroove + (0.96 - innerGroove) * position)),
                    with: .color(.white.opacity(opacity)), lineWidth: 0.5)
            }
            for gap in [0.55, 0.71, 0.85] {
                context.stroke(circle(radius * gap), with: .color(.black.opacity(0.6)), lineWidth: max(1, radius * 0.012))
            }
            context.stroke(circle(radius - 0.5), with: .color(.white.opacity(0.15)), lineWidth: 1)

            if let artwork {
                // The cover fills the label like a square sleeve cropped to a disc; its own picture shows the turn.
                var printed = context
                printed.clip(to: circle(label))
                let scale = 2 * label / min(artwork.size.width, artwork.size.height)
                let cover = CGSize(width: artwork.size.width * scale, height: artwork.size.height * scale)
                printed.draw(Image(uiImage: artwork), in: CGRect(
                    x: center.x - cover.width / 2, y: center.y - cover.height / 2, width: cover.width, height: cover.height))
                context.stroke(circle(label), with: .color(.black.opacity(0.35)), lineWidth: max(0.5, label * 0.025))
            } else {
                // Label, with printed lines that make the turn visible.
                context.fill(circle(label), with: .linearGradient(
                    Gradient(colors: Self.labelColors(hue: hue)),
                    startPoint: CGPoint(x: center.x - label, y: center.y - label),
                    endPoint: CGPoint(x: center.x + label, y: center.y + label)))
                context.stroke(circle(label * 0.93), with: .color(.white.opacity(0.25)), lineWidth: max(0.5, label * 0.02))
                var title = Path()
                title.addArc(center: center, radius: label * 0.68, startAngle: .degrees(205), endAngle: .degrees(335), clockwise: false)
                context.stroke(title, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: max(1, label * 0.07), lineCap: .round))
                for (offset, width) in [(0.42, 0.5), (0.56, 0.32)] {
                    var line = Path()
                    line.move(to: CGPoint(x: center.x - label * width, y: center.y + label * offset))
                    line.addLine(to: CGPoint(x: center.x + label * width, y: center.y + label * offset))
                    context.stroke(line, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: max(0.5, label * 0.04), lineCap: .round))
                }
            }

            context.fill(circle(max(1.5, radius * 0.035)), with: .color(Color(white: 0.03)))
        }
    }

    private var reflection: some View {
        Circle()
            .fill(AngularGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.14), location: 0.1),
                    .init(color: .clear, location: 0.22),
                    .init(color: .clear, location: 0.5),
                    .init(color: .white.opacity(0.09), location: 0.6),
                    .init(color: .clear, location: 0.72),
                    .init(color: .clear, location: 1),
                ],
                center: .center, angle: .degrees(-20)))
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }
}

extension VinylView {
    /// The label's gradient for tracks without a cover, also used by the restoration Live Activity.
    static func labelColors(hue: Double) -> [Color] {
        [
            Color(hue: hue, saturation: 0.55, brightness: 1),
            Color(hue: (hue + 0.05).truncatingRemainder(dividingBy: 1), saturation: 0.85, brightness: 0.72),
        ]
    }

    /// A hue drawn from the track's identifier: random from one track to the next, stable for each.
    static func hue(for id: UUID) -> Double {
        let bytes = id.uuid
        return Double(UInt16(bytes.0) << 8 | UInt16(bytes.1)) / 65_536
    }
}

#Preview {
    let cover = ImageRenderer(content: LinearGradient(
        colors: [.orange, .pink, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        .frame(width: 300, height: 300)).uiImage
    HStack {
        VinylView(hue: 0.08, spinning: true)
        VinylView(hue: 0.08, artwork: cover, spinning: true)
        VinylView(hue: 0.55, artwork: cover)
            .frame(width: 56)
    }
    .padding()
}
