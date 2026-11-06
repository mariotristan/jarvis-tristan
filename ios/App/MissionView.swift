import SwiftUI

struct MissionView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var client: RemoteClient
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var dictation = Dictation()
    @State private var draft = ""
    @State private var tab = MissionView.initialTab
    @FocusState private var typing: Bool

    /// Debug launch argument `-tristanTab code` opens the code tab, for screenshots.
    private static var initialTab: Int {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("code") ? 1 : 0
        #else
        return 0
        #endif
    }

    private var phase: Phase { client.snapshot?.phase ?? .idle }
    private var busy: Bool { phase == .working || phase == .awaitingApproval }
    private var connected: Bool { client.state == .connected }

    var body: some View {
        ZStack {
            VStack(spacing: 10) {
                header
                banner
                panels
                if client.snapshot?.musicOn == true { MusicBar(playing: client.snapshot?.nowPlaying) { client.music($0) } }
                controls
                inputBar
            }
            .padding(.horizontal, 14).padding(.bottom, 8)

            if let request = client.approval {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    ApprovalCard(request: request) { client.respond($0) }
                        .padding(14).frame(maxWidth: 560)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: client.approval?.id)
        .onChange(of: client.snapshot?.phase) { _, new in haptic(for: new) }
        .onChange(of: client.approval) { _, new in
            if new != nil { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            #if DEBUG
            model.automate()
            #endif
        }
        .onChange(of: client.state) { _, _ in
            #if DEBUG
            model.automate()
            #endif
        }
        .onChange(of: client.snapshot) { _, _ in
            #if DEBUG
            model.automate()
            #endif
        }
        .onChange(of: dictation.text) { _, new in if dictation.listening { draft = new } }
    }

    // MARK: pieces

    private var header: some View {
        VStack(spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("T.R.I.S.T.A.N.")
                        .font(.system(size: 16, weight: .bold, design: .monospaced)).tracking(2)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(Theme.cyan).shadow(color: Theme.cyan, radius: 5)
                    HStack(spacing: 6) {
                        Circle().fill(connected ? Theme.green : (client.state == .connecting ? Theme.amber : Theme.red)).frame(width: 7, height: 7)
                        Text(client.snapshot?.macName ?? model.pairing?.name ?? "Mac")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.7)).lineLimit(1)
                    }
                }
                Spacer()
                ReactorView(active: phase == .working, tint: Theme.tint(for: phase), size: sizeClass == .regular ? 84 : 64)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        iconButton("clock.arrow.circlepath") { model.showHistory = true }
                        iconButton("gearshape") { model.showSettings = true }
                    }
                    Text(client.snapshot?.status ?? "OFFLINE")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.tint(for: phase))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if let mode = client.snapshot?.mode {
                        Text("MODE \(mode)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.5)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .overlay(Rectangle().stroke(modeTint(mode), lineWidth: 1)).foregroundStyle(modeTint(mode))
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var banner: some View {
        switch client.state {
        case .connected:
            if let message = client.notice {
                notice(message, Theme.amber)
            }
        case .connecting:
            notice(client.notice ?? "Connecting to your Mac…", Theme.amber)
        case .disconnected:
            HStack { notice("Not connected.", Theme.red); hudButton("CONNECT", tint: Theme.cyan) { model.connect() } }
        case .failed(let message):
            VStack(spacing: 8) {
                notice(message, Theme.red)
                HStack {
                    hudButton("RETRY", tint: Theme.cyan) { model.connect() }
                    hudButton("PAIR AGAIN", tint: Theme.amber) { model.unpair() }
                }
            }
        }
    }

    private func notice(_ text: String, _ tint: Color) -> some View {
        Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8).overlay(Rectangle().stroke(tint.opacity(0.5), lineWidth: 1))
            .onTapGesture { client.clearNotice() }
    }

    @ViewBuilder private var panels: some View {
        if sizeClass == .regular {
            HStack(spacing: 10) {
                LogPanel(lines: client.log).frame(width: 300)
                CodePanel(code: client.code)
            }
        } else {
            VStack(spacing: 8) {
                Picker("", selection: $tab) {
                    Text("LOG").tag(0)
                    Text("CODE").tag(1)
                }
                .pickerStyle(.segmented)
                if tab == 0 { LogPanel(lines: client.log) } else { CodePanel(code: client.code) }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(client.snapshot?.providers ?? [], id: \.self) { name in
                        let on = client.snapshot?.provider == name
                        Button { client.setProvider(name) } label: {
                            Text(name).font(.system(size: 10, weight: .bold, design: .monospaced))
                                .padding(.vertical, 7).padding(.horizontal, 10)
                                .background(on ? Theme.cyan.opacity(0.25) : .clear)
                                .overlay(Rectangle().stroke(Theme.cyan.opacity(on ? 1 : 0.4), lineWidth: 1))
                                .foregroundStyle(Theme.cyan.opacity(on ? 1 : 0.7))
                        }
                        .buttonStyle(.plain).disabled(busy || !connected)
                    }
                }
            }
            Menu {
                ForEach(client.snapshot?.folders ?? []) { folder in
                    Button(folder.name) { client.setFolder(folder.path) }
                }
                Divider()
                Button("ASK mode") { client.setMode("ASK") }
                Button("AUTO mode") { client.setMode("AUTO") }
            } label: {
                Text("📁 \(((client.snapshot?.folder ?? "") as NSString).lastPathComponent)")
                    .font(.system(size: 10, design: .monospaced)).lineLimit(1)
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .overlay(Rectangle().stroke(Theme.amber.opacity(0.7), lineWidth: 1)).foregroundStyle(Theme.amber)
            }
            .disabled(busy || !connected)
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if let problem = dictation.problem {
                Text(problem).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.amber)
            }
            HStack(spacing: 10) {
                Text("▸").foregroundStyle(Theme.amber)
                TextField(dictation.listening ? "Listening…" : "Give Tristan a task…", text: $draft, axis: .vertical)
                    .lineLimit(1...3).focused($typing)
                    .font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.cyan)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.send).onSubmit(send)
                Button { typing = false; dictation.toggle() } label: {
                    Image(systemName: dictation.listening ? "waveform.circle.fill" : "mic.circle")
                        .font(.system(size: 26)).foregroundStyle(dictation.listening ? Theme.red : Theme.cyan)
                }
                .buttonStyle(.plain)
                if busy {
                    hudButton("ABORT", tint: Theme.red) { client.cancel() }
                } else {
                    hudButton("GO", tint: Theme.cyan, action: send).disabled(!connected || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(10).background(Theme.panel).overlay(Rectangle().stroke(Theme.cyan.opacity(0.7), lineWidth: 1))
        }
    }

    // MARK: actions

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connected, !text.isEmpty, !busy else { return }
        dictation.stop()
        client.submit(text)
        draft = ""
        typing = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Theme.amber).frame(width: 34, height: 30)
        }
        .buttonStyle(.plain)
    }

    private func modeTint(_ mode: String) -> Color { ApprovalMode(rawValue: mode)?.tint ?? Theme.cyan }

    private func haptic(for phase: Phase?) {
        switch phase {
        case .done: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .failed: UINotificationFeedbackGenerator().notificationOccurred(.error)
        default: break
        }
    }
}
