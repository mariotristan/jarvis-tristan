import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

struct SettingsOverlay: View {
    @EnvironmentObject var session: Session
    @State private var confirmingYolo = false
    @State private var loginEnabled = false
    @State private var loginMessage: String?
    @State private var recordMonitor: Any?
    @State private var recordError: String?
    @State private var azureKey = ""
    @State private var azureKeyStored = false
    @AppStorage("bedrock.model") private var bedrockModel = ""
    @AppStorage("bedrock.region") private var bedrockRegion = ""
    @AppStorage("bedrock.profile") private var bedrockProfile = ""
    @AppStorage("azure.endpoint") private var azureEndpoint = ""
    @AppStorage("azure.deployment") private var azureDeployment = ""
    @AppStorage("azure.apiVersion") private var azureAPIVersion = ""
    @AppStorage("copilot.model") private var copilotModel = ""
    @AppStorage("music.focus") private var focusPlaylist = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).onTapGesture { session.showSettings = false }
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("CONFIGURATION")
                            .font(.system(size: 11, design: .monospaced)).tracking(3)
                            .foregroundStyle(Theme.amber)
                        approvalSection
                        generalSection
                        voiceSection
                        musicSection
                        providerSections
                        rulesSection
                    }
                    .padding(24)
                }
                HStack {
                    if session.busy {
                        Text("Mode is locked while a mission is running.")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.cyan.opacity(0.5))
                    }
                    Spacer()
                    hudButton("CLOSE", tint: Theme.cyan) { session.showSettings = false }
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
            }
            .frame(width: 600)
            .frame(maxHeight: 620)
            .background(Theme.deep)
            .overlay(Rectangle().stroke(Theme.cyan, lineWidth: 1.5))
            .shadow(color: Theme.cyan.opacity(0.4), radius: 18)
        }
        .onDisappear { stopRecording() }
        .onAppear {
            loginEnabled = SMAppService.mainApp.status == .enabled
            azureKeyStored = KeychainStore.get(AzureConfig.keychainAccount)?.isEmpty == false
        }
    }

    // MARK: sections

    private var approvalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("APPROVAL MODE")
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
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("GENERAL")
            HStack(spacing: 8) {
                toggleButton("SOUND FX", isOn: $session.soundsOn)
                toggleButton("VOICE FEEDBACK", isOn: $session.voiceOn)
                toggleButton("NOTIFICATIONS", isOn: $session.notificationsOn)
            }
            if Bundle.main.bundleURL.pathExtension == "app" {
                toggleButton("LAUNCH AT LOGIN", isOn: Binding(get: { loginEnabled }, set: { setLaunchAtLogin($0) }))
                if let loginMessage {
                    Text(loginMessage).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.amber)
                }
            }
            HStack(spacing: 8) {
                Text("SHORTCUT")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))
                ForEach(HotkeyPreset.allCases) { preset in
                    let on = session.hotkey == preset.shortcut
                    Button { session.hotkey = preset.shortcut } label: {
                        Text(preset.rawValue)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(on ? Theme.cyan.opacity(0.2) : .clear)
                            .overlay(Rectangle().stroke(Theme.cyan.opacity(on ? 1 : 0.4), lineWidth: 1))
                            .foregroundStyle(Theme.cyan.opacity(on ? 1 : 0.6))
                    }
                    .buttonStyle(.plain)
                }
                Button { session.recordingShortcut ? stopRecording() : startRecording() } label: {
                    Text(session.recordingShortcut ? "PRESS KEYS…" : "RECORD")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.vertical, 6).padding(.horizontal, 10)
                        .background(session.recordingShortcut ? Theme.amber.opacity(0.25) : .clear)
                        .overlay(Rectangle().stroke(Theme.amber, lineWidth: 1))
                        .foregroundStyle(Theme.amber)
                }
                .buttonStyle(.plain)
            }
            Text("Shows the HUD: \(session.hotkey.display). Hold \(session.hotkey.talk.display) to talk. Esc cancels recording.")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))
            if let problem = recordError ?? session.shortcutProblem {
                Text(problem).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.amber)
            }
            HStack {
                Text("DEFAULT FOLDER")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))
                Text(session.workingDirectory.path)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.amber)
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                hudButton("CHANGE", tint: Theme.amber) { session.chooseFolder() }
            }
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("VOICE")
            toggleButton("WAKE WORD  (say \"Hey Tristan\")", isOn: $session.wakeOn)
            Text("Always-on listening, off by default. Uses on-device recognition only, so audio never leaves your Mac. Pauses while a mission runs.")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var musicSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("MUSIC  (Spotify desktop app)")
            HStack(spacing: 8) {
                toggleButton("SPOTIFY PLAYER", isOn: $session.musicOn)
                toggleButton("LOWER MUSIC WHEN I TALK", isOn: $session.duckMusic)
            }
            field("Focus playlist (Spotify link or URI)", text: $focusPlaylist, placeholder: "https://open.spotify.com/playlist/…")
            if !focusPlaylist.isEmpty {
                Text(SpotifyURI.normalize(focusPlaylist).map { "✓ \($0)" } ?? "Not a valid Spotify link")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(SpotifyURI.normalize(focusPlaylist) == nil ? Theme.red : Theme.green)
            }
            Text("Say or type \"play music\", \"pause\", \"next song\", \"volume 40\" or \"play my focus playlist\". macOS asks once to let Tristan control Spotify.")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var providerSections: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption("AWS BEDROCK  (uses the AWS CLI and your usual login)")
            field("Model id", text: $bedrockModel, placeholder: BedrockConfig.defaultModel)
            HStack(spacing: 6) {
                field("Region", text: $bedrockRegion, placeholder: "us-east-1")
                field("AWS profile (optional)", text: $bedrockProfile, placeholder: "default")
            }

            caption("AZURE OPENAI")
            field("Endpoint", text: $azureEndpoint, placeholder: "https://my-resource.openai.azure.com")
            HStack(spacing: 6) {
                field("Deployment name", text: $azureDeployment, placeholder: "gpt-4o")
                field("API version", text: $azureAPIVersion, placeholder: AzureConfig.defaultAPIVersion)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("API key  \(azureKeyStored ? "(stored in your Keychain)" : "(blank = use `az login`)")")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))
                HStack(spacing: 6) {
                    SecureField(azureKeyStored ? "••••••••••••" : "Paste a key to store it in the Keychain", text: $azureKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.cyan)
                        .padding(6)
                        .overlay(Rectangle().stroke(Theme.cyan.opacity(0.4), lineWidth: 1))
                    hudButton("SAVE", tint: Theme.green) {
                        if !azureKey.isEmpty { KeychainStore.set(azureKey, account: AzureConfig.keychainAccount) }
                        azureKey = ""
                        azureKeyStored = KeychainStore.get(AzureConfig.keychainAccount)?.isEmpty == false
                    }
                    if azureKeyStored {
                        hudButton("REMOVE", tint: Theme.red) {
                            KeychainStore.set("", account: AzureConfig.keychainAccount)
                            azureKeyStored = false
                        }
                    }
                }
            }

            caption("GITHUB COPILOT  (uses the Copilot CLI and its login)")
            field("Model (optional)", text: $copilotModel, placeholder: "CLI default, e.g. claude-sonnet-4.5 or gpt-5")
        }
    }

    @ViewBuilder
    private var rulesSection: some View {
        if !session.allowRules.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    caption("ALWAYS-ALLOWED (ASK MODE)")
                    Spacer()
                    Button("CLEAR ALL") { session.allowRules = [] }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.red)
                }
                ForEach(session.allowRules) { rule in
                    HStack {
                        Text(rule.label)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.green)
                        Spacer()
                        Button { session.allowRules.removeAll { $0 == rule } } label: { Text("✕").foregroundStyle(Theme.red) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(10)
            .overlay(Rectangle().stroke(Theme.cyan.opacity(0.4), lineWidth: 1))
        }
    }

    // MARK: pieces

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10, design: .monospaced)).tracking(2).foregroundStyle(Theme.cyan.opacity(0.7))
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

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginMessage = nil
        } catch {
            loginMessage = "Could not change Launch at login: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled
        if status == .requiresApproval { loginMessage = "Approve Tristan in System Settings > General > Login Items." }
    }

    private func startRecording() {
        recordError = nil
        session.recordingShortcut = true
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stopRecording(); return nil }
            let shortcut = Shortcut.make(keyCode: Int(event.keyCode), flags: event.modifierFlags,
                                         characters: event.charactersIgnoringModifiers)
            if let problem = shortcut.validationError {
                recordError = problem
            } else {
                session.hotkey = shortcut
                stopRecording()
            }
            return nil      // swallow the key press either way
        }
    }

    private func stopRecording() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
        if session.recordingShortcut { session.recordingShortcut = false }
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

struct HistoryOverlay: View {
    @EnvironmentObject var session: Session
    @State private var query = ""
    @State private var filter: HistoryFilter = .all

    private var shown: [MissionRecord] { session.records.filtered(query: query, status: filter) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).onTapGesture { session.showHistory = false }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("MISSION HISTORY")
                        .font(.system(size: 11, design: .monospaced)).tracking(3).foregroundStyle(Theme.amber)
                    Spacer()
                    if !session.records.isEmpty {
                        Button("CLEAR") { session.clearHistory() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.red)
                    }
                }
                if !session.records.isEmpty {
                    HStack(spacing: 8) {
                        TextField("Search tasks, summaries, providers…", text: $query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.cyan)
                            .padding(6)
                            .overlay(Rectangle().stroke(Theme.cyan.opacity(0.4), lineWidth: 1))
                        ForEach(HistoryFilter.allCases) { option in
                            let on = filter == option
                            Button { filter = option } label: {
                                Text(option.rawValue)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .padding(.vertical, 7).padding(.horizontal, 8)
                                    .background(on ? Theme.cyan.opacity(0.2) : .clear)
                                    .overlay(Rectangle().stroke(Theme.cyan.opacity(on ? 1 : 0.4), lineWidth: 1))
                                    .foregroundStyle(Theme.cyan.opacity(on ? 1 : 0.6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if session.records.isEmpty {
                    Text("No missions yet.")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))
                } else if shown.isEmpty {
                    Text("Nothing matches.")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(shown) { record in row(record) }
                        }
                    }
                }
                HStack {
                    Text("Only the task and a short summary are saved, never code or file contents.")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.4))
                    Spacer()
                    hudButton("CLOSE", tint: Theme.cyan) { session.showHistory = false }
                }
            }
            .padding(24)
            .frame(width: 640, height: 460)
            .background(Theme.deep)
            .overlay(Rectangle().stroke(Theme.cyan, lineWidth: 1.5))
            .shadow(color: Theme.cyan.opacity(0.4), radius: 18)
        }
    }

    private func row(_ record: MissionRecord) -> some View {
        let tint: Color = record.status == "done" ? Theme.green : record.status == "failed" ? Theme.red : Theme.amber
        return HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.task)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.cyan)
                    .lineLimit(2)
                Text(record.summary)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.6))
                    .lineLimit(2)
                Text("\(record.date.formatted(date: .abbreviated, time: .shortened))  ·  \(record.provider)  ·  \(record.mode)  ·  \((record.folder as NSString).lastPathComponent)")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.4))
            }
            Spacer()
            hudButton("RE-RUN", tint: Theme.cyan) { session.rerun(record) }
                .disabled(session.busy)
        }
        .padding(8)
        .overlay(Rectangle().stroke(Theme.cyan.opacity(0.25), lineWidth: 1))
    }
}
