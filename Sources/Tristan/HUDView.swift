import SwiftUI

struct HUDView: View {
    @EnvironmentObject var session: Session
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 12) {
                topBar
                if session.musicOn { MusicStrip(music: session.music) }
                HStack(spacing: 12) {
                    missionLog.frame(width: 270)
                    codeStream
                }
                commandBar
            }
            .padding(18)
            if let request = session.pending { ApprovalOverlay(request: request) }
            if session.showSettings { SettingsOverlay() }
            if session.showHistory { HistoryOverlay() }
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
            VStack(alignment: .leading, spacing: 4) {
                Text("T.R.I.S.T.A.N.")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .tracking(6)
                    .foregroundStyle(Theme.cyan)
                    .shadow(color: Theme.cyan, radius: 6)
                Text("TACTICAL REASONING INTERFACE FOR\nSUPERVISING TASKS, AGENTS & NETWORKS")
                    .font(.system(size: 8, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Theme.cyan.opacity(0.55))
            }
            Spacer()
            ReactorView(active: session.phase == .working || session.listening, tint: Theme.tint(for: session.phase), size: 84)
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(session.status)
                    .font(.system(size: 12, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Theme.tint(for: session.phase))
                Text("MODE \(session.approvalMode.rawValue)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .padding(.vertical, 2).padding(.horizontal, 6)
                    .overlay(Rectangle().stroke(session.approvalMode.tint, lineWidth: 1))
                    .foregroundStyle(session.approvalMode.tint)
            }
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
                TextField(session.listening ? "Listening…" : "Give Tristan a task…", text: $session.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Theme.cyan)
                    .focused($focused)
                    .onSubmit(send)
                Button { session.showHistory.toggle() } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.amber)
                }
                .buttonStyle(.plain)
                .help("Mission history")
                Button { session.showSettings.toggle() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.amber)
                }
                .buttonStyle(.plain)
                .help("Configuration")
                Button { session.listening ? session.stopListening() : session.startListening() } label: {
                    Image(systemName: session.listening ? "waveform.circle.fill" : "mic.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(session.listening ? Theme.red : Theme.cyan)
                        .shadow(color: session.listening ? Theme.red : .clear, radius: 6)
                }
                .buttonStyle(.plain)
                .help("Click to talk, or hold ⌥⇧Space")
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
        guard !session.busy else { return }
        let text = session.draft
        session.submit(text)
        if session.busy { session.draft = "" }
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
                    if request.rule != nil {
                        hudButton("ALWAYS ALLOW", tint: Theme.cyan) { session.resolve(true, always: true) }
                    }
                }
                if let rule = request.rule {
                    Text("ALWAYS ALLOW remembers: \(rule.label). Remove it any time in Configuration.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.cyan.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(width: 520)
            .background(Theme.deep)
            .overlay(Rectangle().stroke(Theme.amber, lineWidth: 1.5))
            .shadow(color: Theme.amber.opacity(0.5), radius: 18)
        }
    }
}

/// Now-playing strip: track, transport controls and volume for the Spotify desktop app.
struct MusicStrip: View {
    @ObservedObject var music: SpotifyController
    @State private var volume = 50.0
    @State private var editingVolume = false

    var body: some View {
        HStack(spacing: 12) {
            Text("♪").foregroundStyle(Theme.amber)
            if let playing = music.nowPlaying {
                Text("\(playing.track)  —  \(playing.artist)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.cyan).lineLimit(1)
                Spacer(minLength: 8)
                control("backward.fill") { Task { _ = await music.perform(.previous) } }
                control(playing.isPlaying ? "pause.fill" : "play.fill") { Task { await music.togglePlayPause() } }
                control("forward.fill") { Task { _ = await music.perform(.next) } }
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 10)).foregroundStyle(Theme.cyan.opacity(0.6))
                Slider(value: $volume, in: 0...100) { editing in
                    editingVolume = editing
                    if !editing { Task { await music.setVolume(Int(volume)) } }
                }
                .frame(width: 110).tint(Theme.cyan)
                .onChange(of: playing.volume) { _, new in if !editingVolume { volume = Double(new) } }
                .onAppear { volume = Double(playing.volume) }
            } else {
                Text(message)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(music.lastError == nil ? Theme.cyan.opacity(0.6) : Theme.amber)
                    .lineLimit(1)
                Spacer()
                if !music.spotifyRunning {
                    hudButton("PLAY FOCUS", tint: Theme.amber) { Task { _ = await music.perform(.focusPlaylist) } }
                    hudButton("OPEN", tint: Theme.cyan) { Task { _ = await music.perform(.play) } }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.panel)
        .overlay(Rectangle().stroke(Theme.amber.opacity(0.4), lineWidth: 1))
    }

    private var message: String {
        if let error = music.lastError { return error }
        return music.spotifyRunning ? "Nothing playing in Spotify" : "Spotify is not running"
    }

    private func control(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.cyan).frame(width: 24, height: 20)
        }
        .buttonStyle(.plain)
    }
}
