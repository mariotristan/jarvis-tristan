import SwiftUI
#if canImport(TristanCore)
import TristanCore
#endif

enum Theme {
    /// Corner radius for buttons, fields and panels.
    static let corner: CGFloat = 10
    // The colors come from the chosen palette (see ThemeStore); the names are the HUD's original roles.
    static var cyan: Color { ThemeStore.palette.primary.color }
    static var amber: Color { ThemeStore.palette.accent.color }
    static var green: Color { ThemeStore.palette.good.color }
    static var red: Color { ThemeStore.palette.bad.color }
    static var deep: Color { ThemeStore.palette.deep.color }
    static var glow: Color { ThemeStore.palette.glow.color }
    static var panel: Color { ThemeStore.palette.panel.color.opacity(0.75) }
    /// Body text of the code stream.
    static var prose: Color { ThemeStore.palette.prose.color }
    /// Wash behind code cards and inline code: darkens a dark theme, tints a light one.
    static var codeWash: Color { ThemeStore.palette.dark ? Color.black.opacity(0.28) : Color.black.opacity(0.06) }
    static var inlineCode: Color { ThemeStore.palette.dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07) }
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
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(tint.opacity(0.65), lineWidth: 1))
        .shadow(color: tint.opacity(0.25), radius: 8)
    }
}

/// How much extra the orb does while it is busy.
enum OrbEffects: String, CaseIterable, Identifiable {
    case off = "OFF", subtle = "SUBTLE", full = "FULL"
    var id: String { rawValue }
}

/// The six colors of the pride flag, brightened to read on the dark Pride theme. Only the Pride theme uses them: the
/// reactor's rings become a color wheel and the backdrop gets a faint wash.
enum Rainbow {
    static let colors: [Color] = [Hex(0xFF5B5B).color, Hex(0xFF9A3D).color, Hex(0xFFE14D).color,
                                  Hex(0x4DDE7A).color, Hex(0x4DA3FF).color, Hex(0xB07CFF).color]

    /// A rainbow around the circle while the Pride theme is on, otherwise the given style.
    static func style(or normal: Color) -> AnyShapeStyle {
        ThemeStore.isPride ? AnyShapeStyle(AngularGradient(colors: colors + [colors[0]], center: .center)) : AnyShapeStyle(normal)
    }
}

/// Spinning arc reactor. Spins faster and pulses harder while the agent is working, and with effects on it also sends
/// out pulse rings, a breathing halo and orbiting sparks.
struct ReactorView: View {
    var active: Bool
    var tint: Color = Theme.cyan
    var size: CGFloat = 90
    /// Seconds between frames; nil redraws at the display's rate. Small spots such as the notch use a slower one.
    var minimumInterval: Double?
    var effects: OrbEffects = .off

    var body: some View {
        TimelineView(.animation(minimumInterval: minimumInterval)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let speed = active ? 1.0 : 0.25
            let fancy = active && effects != .off
            ZStack {
                if fancy {
                    // Halo that breathes behind everything.
                    Circle()
                        .fill(RadialGradient(colors: [tint.opacity(0.35), tint.opacity(0)], center: .center,
                                             startRadius: size * 0.15, endRadius: size * 0.5))
                        .frame(width: size, height: size)
                        .scaleEffect(1 + 0.08 * sin(t * 2.2))
                    // Rings that expand and fade, one after another.
                    ForEach(0..<(effects == .full ? 4 : 2), id: \.self) { i in
                        let phase = (t * 0.45 + Double(i) / (effects == .full ? 4 : 2)).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(tint.opacity((1 - phase) * 0.55), lineWidth: 2)
                            .frame(width: size * (0.4 + 0.6 * phase), height: size * (0.4 + 0.6 * phase))
                    }
                }
                Circle()
                    .stroke(Rainbow.style(or: tint.opacity(0.9)), style: StrokeStyle(lineWidth: 2, dash: [4, 6]))
                    .rotationEffect(.degrees(t * 60 * speed))
                Circle()
                    .inset(by: size * 0.12)
                    .trim(from: 0, to: 0.75)
                    .stroke(Rainbow.style(or: tint.opacity(0.75)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-t * 95 * speed))
                if fancy, effects == .full {
                    Circle()
                        .inset(by: size * 0.2)
                        .trim(from: 0.1, to: 0.35)
                        .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(t * 140))
                    // Sparks on three orbits.
                    ForEach(0..<9, id: \.self) { i in
                        let orbit = 0.22 + 0.1 * Double(i % 3)
                        let angle = t * (0.9 + 0.35 * Double(i % 3)) * (i % 2 == 0 ? 1 : -1) + Double(i) * 0.7
                        Circle()
                            .fill(i % 3 == 0 ? Color.white : tint)
                            .frame(width: size * 0.035, height: size * 0.035)
                            .shadow(color: tint, radius: 4)
                            .offset(x: CGFloat(cos(angle) * orbit) * size * 1.2, y: CGFloat(sin(angle) * orbit) * size * 1.2)
                    }
                }
                Circle()
                    .inset(by: size * 0.28)
                    .stroke(tint.opacity(0.6), lineWidth: 1)
                Circle()
                    .fill(RadialGradient(colors: [.white, tint, tint.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: size * 0.2))
                    .frame(width: size * 0.34, height: size * 0.34)
                    .scaleEffect(1 + (fancy ? 0.18 : 0.1) * sin(t * (active ? 6 : 2)))
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
            RadialGradient(colors: [Theme.glow, Theme.deep],
                           center: .center, startRadius: 0, endRadius: 700)
            if ThemeStore.isPride {
                LinearGradient(colors: Rainbow.colors.map { $0.opacity(0.10) }, startPoint: .top, endPoint: .bottom)
            }
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

/// Like `.plain`, but the whole label box is clickable, not only the pixels that are drawn (the text). Without it a
/// button whose label is padded or transparent only reacts when the pointer is exactly on the text.
struct HUDButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

extension ButtonStyle where Self == HUDButtonStyle {
    static var hud: HUDButtonStyle { HUDButtonStyle() }
}

func hudButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .tracking(2)
            .padding(.vertical, 6).padding(.horizontal, 14)
            .background(tint.opacity(0.2), in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(tint, lineWidth: 1))
            .foregroundStyle(tint)
            .shadow(color: tint.opacity(0.6), radius: 4)
    }
    .buttonStyle(.hud)
}

extension ApprovalMode {
    var tint: Color {
        switch self {
        case .ask: return Theme.green
        case .auto: return Theme.amber
        case .yolo: return Theme.red
        }
    }
}
