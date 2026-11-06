import SwiftUI

struct HUDView: View {
    @EnvironmentObject var session: Session
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
            if session.showSettings { SettingsOverlay() }
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

extension ApprovalMode {
    var tint: Color {
        switch self {
        case .ask: return Theme.green
        case .auto: return Theme.amber
        case .yolo: return Theme.red
        }
    }
}

struct SettingsOverlay: View {
    @EnvironmentObject var session: Session
    @State private var confirmingYolo = false
    @AppStorage("bedrock.model") private var bedrockModel = ""
    @AppStorage("bedrock.region") private var bedrockRegion = ""
    @AppStorage("bedrock.profile") private var bedrockProfile = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).onTapGesture { session.showSettings = false }
            VStack(alignment: .leading, spacing: 16) {
                Text("CONFIGURATION")
                    .font(.system(size: 11, design: .monospaced)).tracking(3)
                    .foregroundStyle(Theme.amber)
                Text("APPROVAL MODE")
                    .font(.system(size: 10, design: .monospaced)).tracking(2)
                    .foregroundStyle(Theme.cyan.opacity(0.7))
                HStack(spacing: 8) {
                    ForEach(ApprovalMode.allCases) { mode in
                        let on = session.approvalMode == mode
                        Button { choose(mode) } label: {
                            Text(mode.rawValue)
                                .font(.system(size: 12, weight: .bold, design: .monospaced)).tracking(2)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(on ? mode.tint.opacity(0.25) : .clear)
                                .overlay(Rectangle().stroke(mode.tint.opacity(on ? 1 : 0.4), lineWidth: 1))
                                .foregroundStyle(mode.tint.opacity(on ? 1 : 0.7))
                                .shadow(color: on ? mode.tint.opacity(0.6) : .clear, radius: 6)
                        }
                        .buttonStyle(.plain)
                        .disabled(session.busy)
                    }
                }
                Text(session.approvalMode.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(session.approvalMode.tint)
                    .fixedSize(horizontal: false, vertical: true)

                if confirmingYolo {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("YOLO means the agent can delete files and run any command in the working folder, with no questions asked. Only use it in a folder you can afford to lose.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.red)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            hudButton("CANCEL", tint: Theme.cyan) { confirmingYolo = false }
                            hudButton("ENABLE YOLO", tint: Theme.red) {
                                session.approvalMode = .yolo
                                confirmingYolo = false
                            }
                        }
                    }
                    .padding(12)
                    .overlay(Rectangle().stroke(Theme.red, lineWidth: 1))
                }
                Text("SOUND")
                    .font(.system(size: 10, design: .monospaced)).tracking(2)
                    .foregroundStyle(Theme.cyan.opacity(0.7))
                HStack(spacing: 8) {
                    toggleButton("SOUND FX", isOn: $session.soundsOn)
                    toggleButton("VOICE FEEDBACK", isOn: $session.voiceOn)
                }

                Text("AWS BEDROCK  (uses the AWS CLI and your usual login)")
                    .font(.system(size: 10, design: .monospaced)).tracking(2)
                    .foregroundStyle(Theme.cyan.opacity(0.7))
                VStack(spacing: 6) {
                    field("Model id", text: $bedrockModel, placeholder: BedrockConfig.defaultModel)
                    HStack(spacing: 6) {
                        field("Region", text: $bedrockRegion, placeholder: "us-east-1")
                        field("AWS profile (optional)", text: $bedrockProfile, placeholder: "default")
                    }
                }

                if !session.allowRules.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("ALWAYS-ALLOWED (ASK MODE)")
                                .font(.system(size: 10, design: .monospaced)).tracking(2)
                                .foregroundStyle(Theme.cyan.opacity(0.7))
                            Spacer()
                            Button("CLEAR ALL") { session.allowRules = [] }
                                .buttonStyle(.plain)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.red)
                        }
                        ForEach(session.allowRules) { rule in
                            HStack {
                                Text(rule.label)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.green)
                                Spacer()
                                Button { session.allowRules.removeAll { $0 == rule } } label: {
                                    Text("✕").foregroundStyle(Theme.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(10)
                    .overlay(Rectangle().stroke(Theme.cyan.opacity(0.4), lineWidth: 1))
                }
                if session.busy {
                    Text("Mode is locked while a mission is running.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.cyan.opacity(0.5))
                }
                HStack {
                    Spacer()
                    hudButton("CLOSE", tint: Theme.cyan) { session.showSettings = false }
                }
            }
            .padding(24)
            .frame(width: 560)
            .background(Theme.deep)
            .overlay(Rectangle().stroke(Theme.cyan, lineWidth: 1.5))
            .shadow(color: Theme.cyan.opacity(0.4), radius: 18)
        }
    }

    private func toggleButton(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text("\(title)  \(isOn.wrappedValue ? "ON" : "OFF")")
                .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(isOn.wrappedValue ? Theme.cyan.opacity(0.2) : .clear)
                .overlay(Rectangle().stroke(Theme.cyan.opacity(isOn.wrappedValue ? 1 : 0.4), lineWidth: 1))
                .foregroundStyle(Theme.cyan.opacity(isOn.wrappedValue ? 1 : 0.6))
        }
        .buttonStyle(.plain)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.cyan)
                .padding(6)
                .overlay(Rectangle().stroke(Theme.cyan.opacity(0.4), lineWidth: 1))
        }
    }

    private func choose(_ mode: ApprovalMode) {
        if mode == .yolo, session.approvalMode != .yolo {
            confirmingYolo = true
        } else {
            confirmingYolo = false
            session.approvalMode = mode
        }
    }
}
