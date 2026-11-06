import SwiftUI

struct HUDView: View {
    @EnvironmentObject var session: Session
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 12) {
                topBar
                HStack(spacing: 12) {
                    missionLog.frame(width: 270)
                    codeStream
                }
                commandBar
            }
            .padding(18)
            if let request = session.pending { ApprovalOverlay(request: request) }
        }
        .frame(minWidth: 900, minHeight: 560)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.cyan.opacity(0.5), lineWidth: 1))
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in focused = true }
        .onExitCommand { NSApp.keyWindow?.orderOut(nil) }
    }

    private var topBar: some View {
        HStack {
            Text("T.R.I.S.T.A.N.")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .tracking(6)
                .foregroundStyle(Theme.cyan)
                .shadow(color: Theme.cyan, radius: 6)
            Spacer()
            ReactorView(active: session.phase == .working, tint: Theme.tint(for: session.phase), size: 84)
            Spacer()
            Text(session.status)
                .font(.system(size: 12, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Theme.tint(for: session.phase))
                .frame(minWidth: 200, alignment: .trailing)
        }
        .frame(height: 90)
    }

    private var missionLog: some View {
        GlowPanel(title: "MISSION LOG") {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(session.log) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(entry.time, format: .dateTime.hour().minute().second())
                                    .foregroundStyle(Theme.cyan.opacity(0.5))
                                Text(entry.text).foregroundStyle(color(for: entry.kind))
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.log.count) { _, _ in
                    if let last = session.log.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }

    private var codeStream: some View {
        GlowPanel(title: "CODE STREAM", tint: Theme.green) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.code.isEmpty ? "Awaiting orders, sir." : session.code)
                            .font(Theme.mono)
                            .foregroundStyle(session.code.isEmpty ? Theme.cyan.opacity(0.5) : Theme.green)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .onChange(of: session.code) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var commandBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("▸").foregroundStyle(Theme.amber)
                TextField("Give Tristan a task…", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Theme.cyan)
                    .focused($focused)
                    .onSubmit(send)
                if session.busy {
                    hudButton("ABORT", tint: Theme.red) { session.cancel() }
                } else {
                    hudButton("EXECUTE", tint: Theme.cyan, action: send)
                }
            }
            .padding(10)
            .background(Theme.panel)
            .overlay(Rectangle().stroke(Theme.cyan.opacity(0.7), lineWidth: 1))

            HStack(spacing: 8) {
                ForEach(ProviderKind.allCases) { kind in
                    let on = session.provider == kind
                    Button { session.provider = kind } label: {
                        Text(kind.rawValue)
                            .font(.system(size: 10, design: .monospaced))
                            .tracking(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(on ? Theme.cyan.opacity(0.25) : .clear)
                            .overlay(Rectangle().stroke(Theme.cyan.opacity(on ? 1 : 0.4), lineWidth: 1))
                            .foregroundStyle(Theme.cyan.opacity(on ? 1 : 0.7))
                    }
                    .buttonStyle(.plain)
                }
                Button { session.chooseFolder() } label: {
                    Text("📁 \(session.workingDirectory.lastPathComponent)")
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.vertical, 5).padding(.horizontal, 10)
                        .overlay(Rectangle().stroke(Theme.amber.opacity(0.7), lineWidth: 1))
                        .foregroundStyle(Theme.amber)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func send() {
        session.submit(input)
        if !input.isEmpty { input = "" }
    }

    private func color(for kind: LogEntry.Kind) -> Color {
        switch kind {
        case .info: return Theme.cyan
        case .step: return Theme.cyan.opacity(0.85)
        case .warn: return Theme.amber
        case .ok: return Theme.green
        }
    }
}

func hudButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .tracking(2)
            .padding(.vertical, 6).padding(.horizontal, 14)
            .background(tint.opacity(0.2))
            .overlay(Rectangle().stroke(tint, lineWidth: 1))
            .foregroundStyle(tint)
            .shadow(color: tint.opacity(0.6), radius: 4)
    }
    .buttonStyle(.plain)
}

struct ApprovalOverlay: View {
    @EnvironmentObject var session: Session
    let request: ApprovalRequest

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(alignment: .leading, spacing: 14) {
                Text("AUTHORIZATION REQUIRED")
                    .font(.system(size: 11, design: .monospaced)).tracking(3)
                    .foregroundStyle(Theme.amber)
                Text(request.summary)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.cyan)
                Text(request.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.cyan.opacity(0.7))
                HStack(spacing: 12) {
                    hudButton("DENY", tint: Theme.red) { session.resolve(false) }
                    hudButton("APPROVE", tint: Theme.green) { session.resolve(true) }
                }
            }
            .padding(24)
            .frame(width: 460)
            .background(Theme.deep)
            .overlay(Rectangle().stroke(Theme.amber, lineWidth: 1.5))
            .shadow(color: Theme.amber.opacity(0.5), radius: 18)
        }
    }
}
