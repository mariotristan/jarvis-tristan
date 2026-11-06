import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

struct SettingsOverlay: View {
    @EnvironmentObject var session: Session
    @State private var confirmingYolo = false
    @State private var newPIN = ""
    @State private var repeatPIN = ""
    @State private var changingPIN = false
    @State private var kidsMessage: String?
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
    @AppStorage("ollama.model") private var ollamaModel = ""
    @State private var ollamaInstalled: [String]?
    @AppStorage("music.focus") private var focusPlaylist = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).onTapGesture { session.closeSettings() }
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("CONFIGURATION")
                            .font(.system(size: 11, design: .monospaced)).tracking(3)
                            .foregroundStyle(Theme.amber)
                        approvalSection
                        kidsSection
                        themeSection
                        orbSection
                        generalSection
                        voiceSection
                        musicSection
                        RemoteSettings(remote: session.remote)
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
                    hudButton("CLOSE", tint: Theme.cyan) { session.closeSettings() }
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
            }
            .frame(width: 600)
            .frame(maxHeight: 620)
            .background(Theme.deep, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cyan, lineWidth: 1.5))
            .shadow(color: Theme.cyan.opacity(0.4), radius: 18)
        }
        .onDisappear { stopRecording() }
        .onAppear {
            loginEnabled = SMAppService.mainApp.status == .enabled
            azureKeyStored = !NoKeychain.enabled && KeychainStore.get(AzureConfig.keychainAccount)?.isEmpty == false
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
                            .background(on ? mode.tint.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: Theme.corner))
                            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(mode.tint.opacity(on ? 1 : 0.4), lineWidth: 1))
                            .foregroundStyle(mode.tint.opacity(on ? 1 : 0.7))
                            .shadow(color: on ? mode.tint.opacity(0.6) : .clear, radius: 6)
                    }
                    .buttonStyle(.hud)
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
                .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.red, lineWidth: 1))
            }
        }
    }

    private var kidsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("KIDS SAFE MODE")
            toggleButton("KIDS SAFE MODE", isOn: kidsBinding)
            HStack(spacing: 8) {
                ForEach(ParentAuth.allCases) { method in
                    chip(method.rawValue, on: session.parentAuth == method) { chooseAuth(method) }
                }
            }
            if session.parentAuth == .pin {
                if !ParentPIN.isSet || changingPIN {
                    HStack(spacing: 8) {
                        SecureField("New PIN (4+ digits)", text: $newPIN).textFieldStyle(.roundedBorder).frame(maxWidth: 170)
                        SecureField("Repeat PIN", text: $repeatPIN).textFieldStyle(.roundedBorder).frame(maxWidth: 170)
                        hudButton("SAVE PIN", tint: Theme.green, action: savePIN)
                    }
                } else {
                    hudButton("CHANGE PIN", tint: Theme.amber) { changingPIN = true }
                }
            }
            if let kidsMessage {
                Text(kidsMessage).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.red)
            }
            Text("While on, opening Settings needs a parent, and YOLO and AUTO are switched off. A parent unlocks with a PIN or with Touch ID / the Mac password, and it locks again when Settings close or after 5 minutes. Remote devices cannot change the mode.")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var orbSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("ORB WHILE WAITING")
            HStack(spacing: 10) {
                Text("SIZE").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.7))
                Slider(value: $session.orbScale, in: 0.6...1.6)
                    .disabled(session.orbFillsScreen)
                Text(session.orbFillsScreen ? "FILL" : "\(Int(session.orbScale * 100))%")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.cyan).frame(width: 40)
            }
            HStack(spacing: 8) {
                ForEach(OrbEffects.allCases) { level in
                    chip("EFFECTS \(level.rawValue)", on: session.orbEffects == level) { session.orbEffects = level }
                }
            }
            toggleButton("ORB FILLS THE WHOLE SCREEN", isOn: $session.orbFillsScreen)
        }
    }

    private var kidsBinding: Binding<Bool> {
        Binding(get: { session.kidsMode }, set: { on in
            kidsMessage = nil
            if on {
                if session.parentAuth == .pin, !ParentPIN.isSet { kidsMessage = "Set a PIN below first."; changingPIN = true; return }
                session.kidsMode = true
            } else {
                session.kidsMode = false
                session.parentUnlocked = false
            }
        })
    }

    private func chooseAuth(_ method: ParentAuth) {
        kidsMessage = nil
        session.parentAuth = method
        if method == .pin, !ParentPIN.isSet { changingPIN = true }
        if method == .system, session.kidsMode { session.parentAuth = .system }
    }

    private func savePIN() {
        guard newPIN == repeatPIN else { kidsMessage = "The PINs do not match."; return }
        guard ParentPIN.valid(newPIN) else { kidsMessage = "Use at least 4 digits."; return }
        guard ParentPIN.set(newPIN) else { kidsMessage = "Could not store the PIN in the Keychain."; return }
        newPIN = ""; repeatPIN = ""; changingPIN = false; kidsMessage = nil
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(on ? Theme.cyan.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: Theme.corner))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cyan.opacity(on ? 1 : 0.4), lineWidth: 1))
                .foregroundStyle(Theme.cyan.opacity(on ? 1 : 0.6))
        }
        .buttonStyle(.hud)
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("THEME")
            themeChip(id: ThemeStore.autoKey, name: "Match system", swatch: [ThemeStore.all[0], ThemeStore.palette(for: "light")!])
            ForEach(ThemeStore.groups, id: \.self) { group in
                Text(group.uppercased())
                    .font(.system(size: 9, design: .monospaced)).tracking(2)
                    .foregroundStyle(Theme.cyan.opacity(0.5))
                let items = ThemeStore.all.filter { $0.group == group }
                ForEach(Array(stride(from: 0, to: items.count, by: 3)), id: \.self) { start in
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { offset in
                            if start + offset < items.count {
                                themeChip(id: items[start + offset].id, name: items[start + offset].name, swatch: [items[start + offset]])
                            } else {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            }
                        }
                    }
                }
            }
        }
    }

    /// One theme button, shown in that theme's own colors so you can see it before choosing it.
    private func themeChip(id: String, name: String, swatch: [ThemePalette]) -> some View {
        let on = session.themeChoice == id
        let first = swatch[0]
        return Button { session.themeChoice = id } label: {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(swatch) { palette in
                        Circle().fill(palette.primary.color).frame(width: 9, height: 9)
                        Circle().fill(palette.accent.color).frame(width: 9, height: 9)
                    }
                }
                Text(name)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(first.primary.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7).padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(first.deep.color, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(on ? Theme.cyan : Theme.cyan.opacity(0.25), lineWidth: on ? 2 : 1))
        }
        .buttonStyle(.hud)
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
                            .background(on ? Theme.cyan.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: Theme.corner))
                            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cyan.opacity(on ? 1 : 0.4), lineWidth: 1))
                            .foregroundStyle(Theme.cyan.opacity(on ? 1 : 0.6))
                    }
                    .buttonStyle(.hud)
                }
                Button { session.recordingShortcut ? stopRecording() : startRecording() } label: {
                    Text(session.recordingShortcut ? "PRESS KEYS…" : "RECORD")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.vertical, 6).padding(.horizontal, 10)
                        .background(session.recordingShortcut ? Theme.amber.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: Theme.corner))
                        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.amber, lineWidth: 1))
                        .foregroundStyle(Theme.amber)
                }
                .buttonStyle(.hud)
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
                        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cyan.opacity(0.4), lineWidth: 1))
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

            caption("OLLAMA  (local models, nothing leaves this Mac)")
            field("Model (blank = first installed)", text: $ollamaModel, placeholder: "e.g. llama3.1 or qwen2.5-coder")
            HStack {
                Text(ollamaStatusText)
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))
                Spacer()
                hudButton("REFRESH", tint: Theme.cyan) { Task { ollamaInstalled = await OllamaStatus.installedModels() } }
            }
            ForEach(ollamaInstalled ?? [], id: \.self) { name in
                let chosen = OllamaStatus.resolveModel(chosen: ollamaModel, installed: [name]) == name && !ollamaModel.isEmpty
                Button { ollamaModel = name } label: {
                    Text("\(chosen ? "●" : "○")  \(name)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(chosen ? Theme.green : Theme.cyan.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.hud)
            }
            Text("Not installed yet? Run scripts/setup-ollama.sh [model] in a terminal.")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.4))
                .task { ollamaInstalled = await OllamaStatus.installedModels() }
        }
    }

    private var ollamaStatusText: String {
        guard let models = ollamaInstalled else { return "Ollama is not running. Start it with `ollama serve`." }
        return models.isEmpty ? "No models installed. Run `ollama pull llama3.1`." : "Installed (click to choose):"
    }

    @ViewBuilder
    private var rulesSection: some View {
        if !session.allowRules.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    caption("ALWAYS-ALLOWED (ASK MODE)")
                    Spacer()
                    Button("CLEAR ALL") { session.allowRules = [] }
                        .buttonStyle(.hud)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.red)
                }
                ForEach(session.allowRules) { rule in
                    HStack {
                        Text(rule.label)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.green)
                        Spacer()
                        Button { session.allowRules.removeAll { $0 == rule } } label: { Text("✕").foregroundStyle(Theme.red) }
                            .buttonStyle(.hud)
                    }
                }
            }
            .padding(10)
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cyan.opacity(0.4), lineWidth: 1))
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
                .background(isOn.wrappedValue ? Theme.cyan.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: Theme.corner))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cyan.opacity(isOn.wrappedValue ? 1 : 0.4), lineWidth: 1))
                .foregroundStyle(Theme.cyan.opacity(isOn.wrappedValue ? 1 : 0.6))
        }
        .buttonStyle(.hud)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.cyan)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cyan.opacity(0.4), lineWidth: 1))
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
                            .buttonStyle(.hud)
                            .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.red)
                    }
                }
                if !session.records.isEmpty {
                    HStack(spacing: 8) {
                        TextField("Search tasks, summaries, providers…", text: $query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.cyan)
                            .padding(6)
                            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cyan.opacity(0.4), lineWidth: 1))
                        ForEach(HistoryFilter.allCases) { option in
                            let on = filter == option
                            Button { filter = option } label: {
                                Text(option.rawValue)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .padding(.vertical, 7).padding(.horizontal, 8)
                                    .background(on ? Theme.cyan.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: Theme.corner))
                                    .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cyan.opacity(on ? 1 : 0.4), lineWidth: 1))
                                    .foregroundStyle(Theme.cyan.opacity(on ? 1 : 0.6))
                            }
                            .buttonStyle(.hud)
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
            .background(Theme.deep, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cyan, lineWidth: 1.5))
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
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cyan.opacity(0.25), lineWidth: 1))
    }
}

/// Pairing and status for the iPhone/iPad app.
struct RemoteSettings: View {
    @ObservedObject var remote: RemoteServer
    @EnvironmentObject var session: Session
    @State private var confirmingRegenerate = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("REMOTE CONTROL  (iPhone and iPad app)")
                .font(.system(size: 10, design: .monospaced)).tracking(2).foregroundStyle(Theme.cyan.opacity(0.7))
            Button { session.remoteOn.toggle() } label: {
                Text("REMOTE CONTROL  \(session.remoteOn ? "ON" : "OFF")")
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(session.remoteOn ? Theme.cyan.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: Theme.corner))
                    .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cyan.opacity(session.remoteOn ? 1 : 0.4), lineWidth: 1))
                    .foregroundStyle(Theme.cyan.opacity(session.remoteOn ? 1 : 0.6))
            }
            .buttonStyle(.hud)

            Text("Off by default. When on, a paired iPhone or iPad on your network can start missions, approve actions and control Spotify. It cannot enable YOLO, and tasks are refused while the Mac is in YOLO mode. Connections are encrypted and need the pairing secret below.")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            if let problem = remote.problem {
                Text(problem).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.amber)
            }
            if session.remoteOn, remote.running, let link = remote.pairingLink {
                HStack(alignment: .top, spacing: 14) {
                    if let image = QRCode.image(for: link.url.absoluteString, points: 150) {
                        Image(nsImage: image).interpolation(.none)
                            .padding(6).background(Color.white)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scan this with the Tristan app, or copy the link and open it on the phone.")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(link.host):\(link.port)")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.amber)
                        HStack(spacing: 8) {
                            hudButton(copied ? "COPIED" : "COPY LINK", tint: Theme.cyan) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
                                copied = true
                            }
                            if confirmingRegenerate {
                                hudButton("CONFIRM", tint: Theme.red) { remote.regenerateSecret(); confirmingRegenerate = false; copied = false }
                                hudButton("CANCEL", tint: Theme.cyan) { confirmingRegenerate = false }
                            } else {
                                hudButton("NEW SECRET", tint: Theme.amber) { confirmingRegenerate = true }
                            }
                        }
                        if confirmingRegenerate {
                            Text("This disconnects every paired device. They must pair again.")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.red)
                        }
                    }
                }
                Text(remote.devices.isEmpty ? "No device connected." : "Connected: \(remote.devices.joined(separator: ", "))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(remote.devices.isEmpty ? Theme.cyan.opacity(0.5) : Theme.green)
            }
        }
    }
}
