import SwiftUI

enum Theme {
    static let cyan = Color(red: 0.10, green: 0.83, blue: 0.94)
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.28)
    static let green = Color(red: 0.62, green: 1.0, blue: 0.69)
    static let red = Color(red: 1.0, green: 0.32, blue: 0.32)
    static let deep = Color(red: 0.008, green: 0.043, blue: 0.063)
    static let panel = Color(red: 0.012, green: 0.10, blue: 0.14).opacity(0.75)
    static let mono = Font.system(size: 12, design: .monospaced)

    static func tint(for phase: Phase) -> Color {
        switch phase {
        case .awaitingApproval: return amber
        case .failed: return red
        case .done: return green
        default: return cyan
        }
    }
}

/// Glowing bordered panel with a small amber caption, the HUD's basic building block.
struct GlowPanel<Content: View>: View {
    let title: String
    var tint: Color = Theme.cyan
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Theme.amber)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel)
        .overlay(Rectangle().stroke(tint.opacity(0.65), lineWidth: 1))
        .shadow(color: tint.opacity(0.25), radius: 8)
    }
}

/// Spinning arc reactor. Spins faster and pulses harder while the agent is working.
struct ReactorView: View {
    var active: Bool
    var tint: Color = Theme.cyan
    var size: CGFloat = 90

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let speed = active ? 1.0 : 0.25
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [4, 6]))
                    .rotationEffect(.degrees(t * 60 * speed))
                Circle()
                    .inset(by: size * 0.12)
                    .trim(from: 0, to: 0.75)
                    .stroke(tint.opacity(0.75), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-t * 95 * speed))
                Circle()
                    .inset(by: size * 0.28)
                    .stroke(tint.opacity(0.6), lineWidth: 1)
                Circle()
                    .fill(RadialGradient(colors: [.white, tint, tint.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: size * 0.2))
                    .frame(width: size * 0.34, height: size * 0.34)
                    .scaleEffect(1 + 0.1 * sin(t * (active ? 6 : 2)))
            }
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(0.8), radius: 8)
        }
    }
}

/// Dark gradient, faint grid and a slow scanline behind everything.
struct Backdrop: View {
    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(red: 0.02, green: 0.13, blue: 0.18), Theme.deep],
                           center: .center, startRadius: 0, endRadius: 700)
            Canvas { ctx, size in
                var path = Path()
                var x: CGFloat = 0
                while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += 40 }
                var y: CGFloat = 0
                while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += 40 }
                ctx.stroke(path, with: .color(Theme.cyan.opacity(0.05)), lineWidth: 0.5)
            }
            TimelineView(.animation) { timeline in
                GeometryReader { geo in
                    let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4
                    Rectangle()
                        .fill(LinearGradient(colors: [.clear, Theme.cyan.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom))
                        .frame(height: 60)
                        .offset(y: (geo.size.height + 60) * t - 60)
                }
            }
            .allowsHitTesting(false)
        }
    }
}
