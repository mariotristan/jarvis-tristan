import SwiftUI

struct LogPanel: View {
    let lines: [RemoteLogLine]

    var body: some View {
        GlowPanel(title: "MISSION LOG") {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if lines.isEmpty {
                            Text("No mission yet.").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))
                        }
                        ForEach(lines) { line in
                            Text(line.text)
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(color(line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                }
                .onChange(of: lines.count) { _, _ in
                    if let last = lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }

    private func color(_ kind: String) -> Color {
        switch kind {
        case "warn": return Theme.amber
        case "ok": return Theme.green
        case "step": return Theme.cyan.opacity(0.85)
        default: return Theme.cyan
        }
    }
}

struct CodePanel: View {
    let code: String
    @AppStorage("renderMarkdown") private var rendered = true

    var body: some View {
        GlowPanel(title: "CODE STREAM", tint: Theme.green) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Long lines wrap: sideways scrolling is awkward on a phone and was clipping the left edge.
                        RenderedStream(text: code, rendered: rendered)
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .onChange(of: code) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { rendered.toggle() } label: {
                Text(rendered ? "RENDERED" : "RAW")
                    .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1)
                    .padding(.vertical, 3).padding(.horizontal, 7)
                    .overlay(Rectangle().stroke(Theme.cyan.opacity(0.6), lineWidth: 1))
                    .foregroundStyle(Theme.cyan)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }
}

struct ApprovalCard: View {
    let request: RemoteApproval
    let respond: (ApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AUTHORIZATION REQUIRED")
                .font(.system(size: 11, design: .monospaced)).tracking(3).foregroundStyle(Theme.amber)
            Text(request.summary)
                .font(.system(size: 18, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.cyan)
            ScrollView {
                Text(request.detail)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(maxHeight: 110)
            HStack(spacing: 10) {
                big("DENY", Theme.red, .deny)
                big("APPROVE", Theme.green, .allow)
            }
            if request.canAlwaysAllow { big("ALWAYS ALLOW THIS", Theme.cyan, .always) }
        }
        .padding(18)
        .background(Theme.deep)
        .overlay(Rectangle().stroke(Theme.amber, lineWidth: 1.5))
        .shadow(color: Theme.amber.opacity(0.5), radius: 18)
    }

    private func big(_ title: String, _ tint: Color, _ decision: ApprovalDecision) -> some View {
        Button {
            UINotificationFeedbackGenerator().notificationOccurred(decision == .deny ? .error : .success)
            respond(decision)
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .monospaced)).tracking(2)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(tint.opacity(0.2)).overlay(Rectangle().stroke(tint, lineWidth: 1))
                .foregroundStyle(tint).shadow(color: tint.opacity(0.5), radius: 4)
        }
        .buttonStyle(.plain)
    }
}

struct MusicBar: View {
    let playing: RemoteNowPlaying?
    let send: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("♪").foregroundStyle(Theme.amber)
            Text(playing.map { "\($0.track) — \($0.artist)" } ?? "Nothing playing")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.cyan).lineLimit(1)
            Spacer(minLength: 4)
            button("backward.fill", "previous")
            button(playing?.playing == true ? "pause.fill" : "play.fill", playing?.playing == true ? "pause" : "play")
            button("forward.fill", "next")
            button("speaker.minus.fill", "volumeDown")
            button("speaker.plus.fill", "volumeUp")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.panel).overlay(Rectangle().stroke(Theme.amber.opacity(0.4), lineWidth: 1))
    }

    private func button(_ symbol: String, _ command: String) -> some View {
        Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); send(command) } label: {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.cyan).frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
    }
}
