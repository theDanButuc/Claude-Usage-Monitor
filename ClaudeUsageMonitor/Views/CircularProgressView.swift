import SwiftUI

struct CircularProgressView: View {
    let progress: Double       // 0.0 – 1.0
    let messagesUsed: Int
    let messagesLimit: Int
    var lineWidth: CGFloat = 14

    private var displayPercentage: Int { Int(progress * 100) }

    // Gradient starts at -90° (top/12 o'clock) — matches ProgressArc start angle exactly.
    // No rotationEffect needed, so there is no double-rotation offset.
    private let trackGradient = AngularGradient(
        stops: [
            .init(color: .green,  location: 0.00),
            .init(color: .yellow, location: 0.50),
            .init(color: .orange, location: 0.70),
            .init(color: .red,    location: 0.85),
            .init(color: .red,    location: 1.00),
        ],
        center: .center,
        startAngle: .degrees(-90),
        endAngle:   .degrees(270)
    )

    var body: some View {
        ZStack {
            // Background track
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)

            // Coloured progress arc — custom Shape so startAngle is -90° by
            // construction; no rotationEffect means the gradient angles align.
            ProgressArc(progress: progress)
                .stroke(
                    trackGradient,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .animation(.spring(response: 0.7, dampingFraction: 0.8), value: progress)

            // Green dot at arc origin (12 o'clock).
            // The AngularGradient wraps at -90°/270° so the round start cap
            // would show half-green / half-red. This dot covers that artefact.
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                Circle()
                    .fill(Color.green)
                    .frame(width: lineWidth, height: lineWidth)
                    .position(x: geo.size.width / 2,
                              y: (geo.size.height - side) / 2)
            }
            .opacity(progress > 0.01 ? 1 : 0)

            // Central labels
            VStack(spacing: 4) {
                Text("\(displayPercentage)%")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(percentageColor)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.4), value: displayPercentage)

                if messagesLimit > 0 {
                    Text("\(messagesUsed) of \(messagesLimit)")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No data")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var percentageColor: Color {
        switch progress {
        case 0.8...: return .red
        case 0.5...: return .orange
        default:     return .green
        }
    }
}

// MARK: - Arc Shape

/// Draws a clockwise arc from -90° (12 o'clock) to the given progress fraction.
/// Using a custom Shape avoids the need for `.rotationEffect` which would also
/// rotate the AngularGradient and misalign its colours.
private struct ProgressArc: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        return Path { p in
            p.addArc(
                center:     center,
                radius:     radius,
                startAngle: .degrees(-90),
                endAngle:   .degrees(-90 + 360 * max(0.005, progress)),
                clockwise:  false
            )
        }
    }
}
