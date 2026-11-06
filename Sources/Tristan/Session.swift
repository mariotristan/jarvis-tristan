import SwiftUI
import AppKit
import AVFoundation


struct LogEntry: Identifiable {
    enum Kind { case info, step, warn, ok }
    let id = UUID()
    let time = Date()
    let text: String
    let kind: Kind
}

@MainActor
final class Session: ObservableObject {
    @Published var phase: Phase = .idle {
        didSet { refreshWake() }
    }
    @Published var log: [LogEntry] = []
    @Published var code = ""
    @Published var status = "STANDING BY"
    @Published var pending: ApprovalRequest?
    @Published var approvalMode: ApprovalMode = .ask {
        didSet { UserDefaults.standard.set(approvalMode.rawValue, forKey: "approvalMode") }
    }
    @Published var allowRules: [ApprovalRule] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(allowRules), forKey: "allowRules") }
    }
    @Published var soundsOn = true {
        didSet { fx.soundsOn = soundsOn; UserDefaults.standard.set(soundsOn, forKey: "soundsOn") }
    }
    @Published var voiceOn = true {
        didSet { fx.voiceOn = voiceOn; UserDefaults.standard.set(voiceOn, forKey: "voiceOn") }
    }
    @Published var notificationsOn = true {
        didSet { Notifier.shared.enabled = notificationsOn; UserDefaults.standard.set(notificationsOn, forKey: "notificationsOn") }
    }
    @Published var wakeOn = false {
        didSet { UserDefaults.standard.set(wakeOn, forKey: "wakeOn"); refreshWake() }
    }
    @Published var hotkey: Shortcut = .default {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(hotkey), forKey: "shortcut") }
    }
    /// True while the settings panel is capturing a new shortcut (the global ones are paused meanwhile).
    @Published var recordingShortcut = false
    @Published var shortcutProblem: String?
    @Published var musicOn = false {
        didSet { music.enabled = musicOn; UserDefaults.standard.set(musicOn, forKey: "musicOn") }
    }
    @Published var duckMusic = true {
        didSet { music.duckingEnabled = duckMusic; UserDefaults.standard.set(duckMusic, forKey: "duckMusic") }
    }
    @Published var remoteOn = false {
        didSet {
            UserDefaults.standard.set(remoteOn, forKey: "remoteOn")
            if remoteOn { remote.start() } else { remote.stop() }
        }
    }
    /// Changes at the start of every mission, so a connected phone knows when to clear its log.
    @Published private(set) var missionID = UUID().uuidString
    @Published var showSettings = false
    @Published var showHistory = false
    @Published var draft = ""
    @Published var listening = false {
        didSet { refreshWake(); music.setDuck("mic", active: listening) }
    }
    @Published var provider: ProviderKind = .demo {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "provider") }
    }
    @Published var workingDirectory = FileManager.default.homeDirectoryForCurrentUser {
        didSet { UserDefaults.standard.set(workingDirectory.path, forKey: "workingDirectory") }
    }
    @Published var records: [MissionRecord] = []

    private var approval: CheckedContinuation<Bool, Never>?
    private var runner: Task<Void, Never>?
    private let voice = VoiceInput()
    private let wake = WakeListener()
    private let fx = SoundFX()
    let music: SpotifyController
    let remote = RemoteServer()
    private let history: HistoryStore?
    private var announcedApproval = false
    private var spokenReply = false
    private var currentTask = ""
    private var recorded = false

    /// `history: nil` keeps everything in memory (tests, headless runs, screenshots).
    init(history: HistoryStore? = HistoryStore.standard, music: SpotifyController? = nil) {
        self.history = history
        self.music = music ?? SpotifyController()
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "soundsOn") != nil { soundsOn = defaults.bool(forKey: "soundsOn") }
        if defaults.object(forKey: "voiceOn") != nil { voiceOn = defaults.bool(forKey: "voiceOn") }
        if defaults.object(forKey: "notificationsOn") != nil { notificationsOn = defaults.bool(forKey: "notificationsOn") }
        fx.soundsOn = soundsOn
        fx.voiceOn = voiceOn
        fx.onSpeaking = { [weak self] speaking in self?.music.setDuck("speech", active: speaking) }
        if defaults.object(forKey: "duckMusic") != nil { duckMusic = defaults.bool(forKey: "duckMusic") }
        self.music.duckingEnabled = duckMusic
        Notifier.shared.enabled = notificationsOn
        if let saved = defaults.string(forKey: "approvalMode"), let mode = ApprovalMode(rawValue: saved) { approvalMode = mode }
        if let saved = defaults.string(forKey: "provider"), let kind = ProviderKind(rawValue: saved) { provider = kind }
        if let data = defaults.data(forKey: "shortcut"), let saved = try? JSONDecoder().decode(Shortcut.self, from: data) {
            hotkey = saved
        } else if let legacy = defaults.string(forKey: "hotkey"), let preset = HotkeyPreset(rawValue: legacy) {
            hotkey = preset.shortcut      // settings saved by an earlier version
        }
        if let path = defaults.string(forKey: "workingDirectory"), FileManager.default.fileExists(atPath: path) {
            workingDirectory = URL(fileURLWithPath: path)
        }
        if let data = defaults.data(forKey: "allowRules"), let rules = try? JSONDecoder().decode([ApprovalRule].self, from: data) {
            allowRules = rules
        }
        records = history?.load() ?? []

        wake.onStarted = { [weak self] in self?.wakeStarted() }
        wake.onUpdate = { [weak self] in self?.draft = $0 }
        wake.onSubmit = { [weak self] in self?.wakeSubmit($0) }
        wake.onCancel = { [weak self] in self?.wakeCancelled() }
        wake.onError = { [weak self] message in
            self?.wakeOn = false
            self?.add(message, .warn)
        }
        if defaults.bool(forKey: "wakeOn") { wakeOn = true }
        if defaults.bool(forKey: "musicOn") { musicOn = true }
        remote.attach(to: self)
        if defaults.bool(forKey: "remoteOn") { remoteOn = true }
    }

    var busy: Bool { phase == .working || phase == .awaitingApproval }

    func submit(_ prompt: String, viaVoice: Bool = false) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Short music commands ("next song") never start a mission, and work even while one is running.
        if musicOn, let command = MusicCommand.parse(prompt) {
            runMusic(command, viaVoice: viaVoice)
            return
        }
        guard !prompt.isEmpty else { return }
        guard !busy else {
            if viaVoice { add("A mission is running. Abort it or wait before giving another task.", .warn) }
            return
        }
        spokenReply = viaVoice
        missionID = UUID().uuidString
        log = []
        code = ""
        currentTask = prompt
        recorded = false
        guard let impl = provider.makeProvider(mode: approvalMode) else {
            phase = .failed
            status = "OFFLINE"
            add("\(provider.rawValue) is not wired up yet", .warn)
            return
        }
        phase = .working
        status = "INITIALIZING"
        announcedApproval = false
        add("Task: \(prompt)", .info)
        fx.play(.missionStart)
        fx.say(SoundFX.startLines.randomElement()!)
        let dir = workingDirectory
        runner = Task { [weak self] in
            let stream = impl.run(task: prompt, workingDirectory: dir) { [weak self] req in
                await self?.ask(req) ?? false
            }
            for await event in stream { self?.handle(event) }
            self?.streamEnded()
        }
    }

    func cancel() {
        runner?.cancel()
        resolve(false)
        if busy {
            phase = .failed; status = "ABORTED"; add("Aborted by operator", .warn)
            record(status: "aborted", summary: "Aborted by operator")
        }
    }

    func resolve(_ approved: Bool, always: Bool = false) {
        guard let cont = approval else { return }
        if approved, always, let rule = pending?.rule, !allowRules.contains(rule) {
            allowRules.append(rule)
            add("Always allowed: \(rule.label)", .ok)
        }
        approval = nil
        pending = nil
        phase = .working
        add(approved ? "Authorization granted" : "Authorization denied", approved ? .ok : .warn)
        fx.play(approved ? .approved : .denied)
        cont.resume(returning: approved)
    }

    // MARK: music

    private func runMusic(_ command: MusicCommand, viaVoice: Bool) {
        draft = ""
        Task { [weak self] in
            guard let self else { return }
            let reply = await self.music.perform(command)
            self.add("♪ \(reply)", .info)
            if viaVoice { self.fx.say(reply) }
        }
    }

    // MARK: voice

    /// Push-to-talk: transcript streams into `draft`; releasing sends it as a task.
    func startListening() {
        guard !listening else { return }
        listening = true
        draft = ""
        if !busy { status = "LISTENING" }
        fx.stopSpeaking()
        fx.play(.listenStart)
        voice.start(onText: { [weak self] in self?.draft = $0 }, onError: { [weak self] message in
            guard let self else { return }
            self.listening = false
            self.status = "STANDING BY"
            self.add(message, .warn)
        })
    }

    func stopListening(send: Bool = true) {
        guard listening else { return }
        listening = false
        voice.stop()
        fx.play(.listenStop)
        Task { [weak self] in
            // Give the recognizer a moment to deliver the final words.
            try? await Task.sleep(for: .milliseconds(700))
            guard let self else { return }
            let text = self.draft
            if send, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                self.draft = ""
                self.submit(text, viaVoice: true)
            } else if self.phase == .idle {
                self.status = "STANDING BY"
            }
        }
    }

    /// The wake listener only runs while the feature is on and nothing else needs the microphone.
    private func refreshWake() {
        wake.setRunning(wakeOn && !busy && !listening)
    }

    private func wakeStarted() {
        music.setDuck("mic", active: true)
        status = "LISTENING"
        draft = ""
        fx.stopSpeaking()
        fx.play(.listenStart)
    }

    private func wakeSubmit(_ text: String) {
        music.setDuck("mic", active: false)
        fx.play(.listenStop)
        draft = ""
        submit(text, viaVoice: true)
    }

    private func wakeCancelled() {
        music.setDuck("mic", active: false)
        draft = ""
        if phase == .idle { status = "STANDING BY" }
    }

    // MARK: history

    func rerun(_ record: MissionRecord) {
        guard !busy else { return }
        if let kind = ProviderKind(rawValue: record.provider) { provider = kind }
        if FileManager.default.fileExists(atPath: record.folder) { workingDirectory = URL(fileURLWithPath: record.folder) }
        draft = record.task
        showHistory = false
    }

    func clearHistory() {
        records = []
        history?.save([])
    }

    private func record(status: String, summary: String) {
        guard !recorded, !currentTask.isEmpty else { return }
        recorded = true
        records.insert(MissionRecord(task: currentTask, provider: provider.rawValue, mode: approvalMode.rawValue, status: status,
                                     summary: String(summary.prefix(240)), folder: workingDirectory.path), at: 0)
        if records.count > 100 { records.removeLast(records.count - 100) }
        history?.save(records)
    }

    // MARK: folders

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = workingDirectory
        if panel.runModal() == .OK, let url = panel.url { workingDirectory = url }
    }

    // MARK: agent events

    private func ask(_ request: ApprovalRequest) async -> Bool {
        if let rule = request.rule, allowRules.contains(rule) {
            add("Auto-allowed by rule: \(rule.label)", .ok)
            return true
        }
        pending = request
        phase = .awaitingApproval
        status = "AWAITING AUTHORIZATION"
        add(request.summary, .warn)
        fx.play(.approvalNeeded)
        Notifier.shared.post(title: "Tristan needs your approval", body: "\(request.summary) \(request.detail)")
        if !announcedApproval {
            announcedApproval = true
            fx.say(SoundFX.approvalLines.randomElement()!)
        }
        return await withCheckedContinuation { approval = $0 }
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .status(let s): if phase != .awaitingApproval { status = s }
        case .log(let s): add(s, .step)
        case .code(let s): code += s
        case .done(let s):
            phase = .done; status = "MISSION COMPLETE"; add(s, .ok)
            record(status: "done", summary: s)
            fx.play(.missionComplete)
            Notifier.shared.post(title: "Mission complete", body: s)
            // Tasks given by voice get the result read back; others get a short confirmation.
            if spokenReply { fx.say(String(s.prefix(240))) } else { fx.say(SoundFX.doneLines.randomElement()!) }
        case .failed(let s):
            phase = .failed; status = "MISSION FAILED"; add(s, .warn)
            record(status: "failed", summary: s)
            fx.play(.missionFailed)
            Notifier.shared.post(title: "Mission failed", body: s)
            fx.say(SoundFX.failLines.randomElement()!)
        }
    }

    private func streamEnded() {
        if busy {
            phase = .done; status = "MISSION COMPLETE"
            record(status: "done", summary: "Complete")
        }
    }

    /// Mission-log line for something a remote device did ("iPhone connected").
    func noteRemote(_ text: String) {
        add("📱 \(text)", .info)
    }

    private func add(_ text: String, _ kind: LogEntry.Kind) {
        log.append(LogEntry(text: text, kind: kind))
    }
}
