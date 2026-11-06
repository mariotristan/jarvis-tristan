import SwiftUI
import AppKit
import AVFoundation
import Combine


struct LogEntry: Identifiable {
    enum Kind { case info, step, warn, ok }
    let id = UUID()
    let time = Date()
    let text: String
    let kind: Kind
}

/// The hub: shared settings and services (sound, voice, music, remote, history) plus the open sessions.
/// The properties for a single mission (`log`, `code`, `phase`, `pending`, `provider`, `workingDirectory`, ...) forward
/// to the active session, so the HUD, the remote server and the tests keep talking to "the current session".
@MainActor
final class Session: ObservableObject {
    static let maxSessions = 8

    @Published private(set) var sessions: [MissionSession] = []
    @Published private(set) var activeID = UUID()
    /// What the notch and the reactor show: the most urgent thing happening in any session.
    @Published private(set) var overallPhase: Phase = .idle
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
    @Published var renderMarkdown = true {
        didSet { UserDefaults.standard.set(renderMarkdown, forKey: "renderMarkdown") }
    }
    /// The chosen look: a palette key from ThemeStore, or "auto" to follow the system appearance.
    @Published var themeChoice = ThemeStore.defaultKey {
        didSet { UserDefaults.standard.set(themeChoice, forKey: "theme"); applyTheme() }
    }
    /// The palette in use right now. The HUD rebuilds when this changes.
    @Published private(set) var themeID = ThemeStore.defaultKey

    func applyTheme() {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
        let palette = ThemeStore.resolve(themeChoice, systemIsDark: dark)
        ThemeStore.palette = palette
        if themeID != palette.id { themeID = palette.id }
    }
    /// How big the orb is while it waits (a multiplier), what it does, and whether it takes over the whole window.
    @Published var orbScale: Double = 1.0 {
        didSet { UserDefaults.standard.set(orbScale, forKey: "orbScale") }
    }
    @Published var orbEffects: OrbEffects = .full {
        didSet { UserDefaults.standard.set(orbEffects.rawValue, forKey: "orbEffects") }
    }
    @Published var orbFillsScreen = true {
        didSet { UserDefaults.standard.set(orbFillsScreen, forKey: "orbFill") }
    }
    /// Kids safe mode: Settings, YOLO and AUTO need a parent (a PIN or the Mac's own login).
    @Published var kidsMode = false {
        didSet {
            UserDefaults.standard.set(kidsMode, forKey: "kidsMode")
            fx.kidsVoice = kidsMode
            if kidsMode, approvalMode != .ask, !busy { approvalMode = .ask }
        }
    }
    @Published var parentAuth: ParentAuth = .pin {
        didSet { UserDefaults.standard.set(parentAuth.rawValue, forKey: "parentAuth") }
    }
    @Published var parentUnlocked = false
    @Published var parentPrompt: ParentPrompt?
    @Published var parentPINFailed = false
    var relock: Task<Void, Never>?
    /// True while Tristan is working, speaking or has only just finished: the microphone stays shut so it cannot
    /// hear itself or start a second command.
    @Published private(set) var micBusy = false {
        didSet { if micBusy != oldValue { refreshWake() } }
    }
    private var speaking = false
    private var micGrace: Task<Void, Never>?
    /// Full-screen mode. Set by the HUD button or ⌃⌘F; the window itself is resized by the AppDelegate.
    @Published var fullScreen = false
    @Published var fullScreenTopInset: CGFloat = 0
    @Published var showSettings = false
    @Published var showHistory = false
    @Published var listening = false {
        didSet { refreshWake(); music.setDuck("mic", active: listening) }
    }
    @Published var records: [MissionRecord] = []

    /// How a provider is created. Tests and tools replace this to run sessions against stand-ins.
    var providerFactory: (ProviderKind, ApprovalMode) -> AgentProvider? = { kind, mode in kind.makeProvider(mode: mode) }
    /// Whether a local model can answer right now. Kids mode asks before sending anything anywhere. Tests replace this.
    var localModelReady: @Sendable () async -> Bool = { await OllamaStatus.ready() }
    /// Starts the local Ollama server when it is off. Tests replace this.
    var startLocalModel: @Sendable () async -> LocalModelLauncher.Outcome = { await LocalModelLauncher.start() }
    /// True while the Mac has no internet. Missions on a cloud provider then run on Ollama instead.
    @Published var offline = false
    private let network = NetworkMonitor()

    func startNetworkMonitor() {
        network.onChange = { [weak self] online in self?.offline = !online }
        network.start()
    }

    private let voice = VoiceInput()
    private let wake = WakeListener()
    let fx = SoundFX()
    let music: SpotifyController
    let remote = RemoteServer()
    private let history: HistoryStore?
    private let defaults: UserDefaults
    private var observers: [UUID: AnyCancellable] = [:]
    private var updateScheduled = false

    private struct SavedTab: Codable { var provider: String; var folder: String; var memory: ConversationMemory? }

    /// `history: nil` keeps everything in memory: nothing is saved or restored, including the open sessions (tests,
    /// headless runs, screenshots).
    init(history: HistoryStore? = HistoryStore.standard, music: SpotifyController? = nil, defaults: UserDefaults = .standard) {
        self.history = history
        self.defaults = defaults
        self.music = music ?? SpotifyController()
        let standard = UserDefaults.standard
        if standard.object(forKey: "renderMarkdown") != nil { renderMarkdown = standard.bool(forKey: "renderMarkdown") }
        if standard.object(forKey: "soundsOn") != nil { soundsOn = standard.bool(forKey: "soundsOn") }
        if standard.object(forKey: "voiceOn") != nil { voiceOn = standard.bool(forKey: "voiceOn") }
        if standard.object(forKey: "notificationsOn") != nil { notificationsOn = standard.bool(forKey: "notificationsOn") }
        if let saved = standard.string(forKey: "theme") { themeChoice = saved }
        applyTheme()
        if standard.object(forKey: "orbScale") != nil { orbScale = min(max(standard.double(forKey: "orbScale"), 0.6), 1.6) }
        if let saved = standard.string(forKey: "orbEffects"), let value = OrbEffects(rawValue: saved) { orbEffects = value }
        if standard.object(forKey: "orbFill") != nil { orbFillsScreen = standard.bool(forKey: "orbFill") }
        if let saved = standard.string(forKey: "parentAuth"), let value = ParentAuth(rawValue: saved) { parentAuth = value }
        kidsMode = standard.bool(forKey: "kidsMode")
        fx.soundsOn = soundsOn
        fx.voiceOn = voiceOn
        fx.kidsVoice = kidsMode
        fx.onSpeaking = { [weak self] speaking in
            self?.music.setDuck("speech", active: speaking)
            self?.speaking = speaking
            self?.refreshMic()
        }
        if standard.object(forKey: "duckMusic") != nil { duckMusic = standard.bool(forKey: "duckMusic") }
        self.music.duckingEnabled = duckMusic
        Notifier.shared.enabled = notificationsOn
        if let saved = standard.string(forKey: "approvalMode"), let mode = ApprovalMode(rawValue: saved) { approvalMode = mode }
        if kidsMode, approvalMode != .ask { approvalMode = .ask }
        if let data = standard.data(forKey: "shortcut"), let saved = try? JSONDecoder().decode(Shortcut.self, from: data) {
            hotkey = saved
        } else if let legacy = standard.string(forKey: "hotkey"), let preset = HotkeyPreset(rawValue: legacy) {
            hotkey = preset.shortcut      // settings saved by an earlier version
        }
        if let data = standard.data(forKey: "allowRules"), let rules = try? JSONDecoder().decode([ApprovalRule].self, from: data) {
            allowRules = rules
        }
        records = history?.load() ?? []
        restoreSessions()

        wake.onStarted = { [weak self] in self?.wakeStarted() }
        wake.onUpdate = { [weak self] in self?.draft = $0 }
        wake.onSubmit = { [weak self] in self?.wakeSubmit($0) }
        wake.onCancel = { [weak self] in self?.wakeCancelled() }
        wake.onError = { [weak self] message in
            self?.wakeOn = false
            self?.active.note(message, .warn)
        }
        if standard.bool(forKey: "wakeOn") { wakeOn = true }
        if standard.bool(forKey: "musicOn") { musicOn = true }
        remote.attach(to: self)
        if standard.bool(forKey: "remoteOn") { remoteOn = true }
    }

    // MARK: the active session (what the HUD and the remote show)

    var active: MissionSession { sessions.first { $0.id == activeID } ?? sessions[0] }

    var phase: Phase { get { active.phase } set { active.phase = newValue } }
    var log: [LogEntry] { get { active.log } set { active.log = newValue } }
    var code: String { get { active.code } set { active.code = newValue } }
    var status: String { get { active.status } set { active.status = newValue } }
    var pending: ApprovalRequest? { get { active.pending } set { active.pending = newValue } }
    var provider: ProviderKind { get { active.provider } set { active.provider = newValue } }
    var workingDirectory: URL { get { active.workingDirectory } set { active.workingDirectory = newValue } }
    var draft: String { get { active.draft } set { active.draft = newValue } }
    var missionID: String { active.missionID }
    var busy: Bool { active.busy }

    // MARK: managing sessions

    /// The session that needs an answer from the operator: the active one if it is waiting, else any other.
    var attention: MissionSession? {
        active.phase == .awaitingApproval ? active : sessions.first { $0.phase == .awaitingApproval }
    }

    /// Sessions other than the active one that are waiting for approval.
    var backgroundApprovals: [MissionSession] {
        sessions.filter { $0.phase == .awaitingApproval && $0.id != activeID }
    }

    func label(for session: MissionSession) -> String {
        "Session \((sessions.firstIndex { $0.id == session.id } ?? 0) + 1)"
    }

    /// Opens another session (a copy of the current provider and folder unless told otherwise) and switches to it.
    @discardableResult
    func newSession(provider: ProviderKind? = nil, folder: URL? = nil, select: Bool = true) -> MissionSession? {
        guard sessions.count < Self.maxSessions else { return nil }
        let created = MissionSession(provider: provider ?? active.provider, workingDirectory: folder ?? active.workingDirectory)
        adopt(created)
        if select { activeID = created.id }
        sessionsChanged()
        return created
    }

    func select(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }), id != activeID else { return }
        activeID = id
        sessionsChanged()
    }

    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        select(sessions[index].id)
    }

    /// Closes a session, aborting it if it is running. The last session is replaced by a fresh one.
    func close(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let closing = sessions[index]
        closing.cancel()
        observers[id] = nil
        sessions.remove(at: index)
        if sessions.isEmpty {
            let fresh = MissionSession(provider: closing.provider, workingDirectory: closing.workingDirectory)
            adopt(fresh)
            activeID = fresh.id
        } else if activeID == id {
            activeID = sessions[min(index, sessions.count - 1)].id
        }
        sessionsChanged()
    }

    private func adopt(_ session: MissionSession) {
        session.hub = self
        sessions.append(session)
        observers[session.id] = session.objectWillChange.sink { [weak self] _ in self?.sessionChanged() }
    }

    /// Forwards a change in any session to whoever is watching the hub, and schedules the follow-up work once.
    private func sessionChanged() {
        objectWillChange.send()
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { @MainActor [weak self] in
            self?.updateScheduled = false
            self?.sessionsChanged()
        }
    }

    /// A session finished a mission or forgot its past: save the open sessions so the memory survives a restart.
    func memoryChanged() { saveSessions() }

    private func sessionsChanged() {
        let phases = sessions.map(\.phase)
        let overall: Phase = phases.contains(.awaitingApproval) ? .awaitingApproval : phases.contains(.working) ? .working : active.phase
        if overall != overallPhase { overallPhase = overall }
        refreshMic()
        refreshWake()
        saveSessions()
    }

    private func restoreSessions() {
        var restored: [MissionSession] = []
        var activeIndex = 0
        if history != nil, let data = defaults.data(forKey: "sessionTabs"), let tabs = try? JSONDecoder().decode([SavedTab].self, from: data) {
            restored = tabs.prefix(Self.maxSessions).map { tab in
                let exists = FileManager.default.fileExists(atPath: tab.folder)
                return MissionSession(provider: ProviderKind(rawValue: tab.provider) ?? .demo,
                                      workingDirectory: exists ? URL(fileURLWithPath: tab.folder) : FileManager.default.homeDirectoryForCurrentUser,
                                      memory: tab.memory ?? ConversationMemory())
            }
            activeIndex = min(defaults.integer(forKey: "activeTab"), max(restored.count - 1, 0))
        }
        if restored.isEmpty {
            // First launch, or settings saved before there were several sessions.
            let kind = defaults.string(forKey: "provider").flatMap(ProviderKind.init(rawValue:)) ?? .demo
            let folder = defaults.string(forKey: "workingDirectory").flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
                ?? FileManager.default.homeDirectoryForCurrentUser
            restored = [MissionSession(provider: kind, workingDirectory: folder)]
        }
        for session in restored { adopt(session) }
        activeID = restored[activeIndex].id
    }

    /// The open sessions come back (idle) after a restart. Only the real app saves them.
    private func saveSessions() {
        guard history != nil else { return }
        let tabs = sessions.map { SavedTab(provider: $0.provider.rawValue, folder: $0.workingDirectory.path, memory: $0.memory) }
        defaults.set(try? JSONEncoder().encode(tabs), forKey: "sessionTabs")
        defaults.set(sessions.firstIndex { $0.id == activeID } ?? 0, forKey: "activeTab")
    }

    /// Labels of the other sessions that are running in the same folder.
    func sessionsBusy(in folder: URL, besides session: MissionSession) -> [String] {
        sessions.filter { $0.id != session.id && $0.busy && $0.workingDirectory.path == folder.path }.map { label(for: $0) }
    }

    // MARK: working with the active session

    private static let quitPhrases: Set<String> = [
        "quit", "exit", "close", "quit tristan", "exit tristan", "close tristan", "shut down", "shut down tristan", "goodbye tristan",
    ]

    func submit(_ prompt: String, viaVoice: Bool = false) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // "quit" / "close tristan" (typed or spoken) closes the app, even from full screen.
        if Self.quitPhrases.contains(prompt.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            draft = ""
            NSApp.terminate(nil)
            return
        }
        // Short music commands ("next song") never start a mission, and work even while one is running.
        if musicOn, let command = MusicCommand.parse(prompt) {
            runMusic(command, viaVoice: viaVoice)
            return
        }
        active.submit(prompt, viaVoice: viaVoice)
        refreshMic()
    }

    /// Said (when voice feedback is on) and written to the log once when the app opens.
    func greet(at date: Date = Date()) {
        let line = Greeting.line(at: date)
        active.note(line)
        fx.say(line)
    }

    func cancel() { active.cancel() }

    func resolve(_ approved: Bool, always: Bool = false) { active.resolve(approved, always: always) }

    /// Answers whichever session is waiting (the active one first). The notch uses this.
    func resolveAttention(_ approved: Bool, always: Bool = false) { attention?.resolve(approved, always: always) }

    /// Mission-log line for something a remote device did ("iPhone connected").
    func noteRemote(_ text: String) { active.note("📱 \(text)") }

    // MARK: what sessions report back (sound, notifications, history)

    private var several: Bool { sessions.count > 1 }

    private func spoken(_ line: String, for session: MissionSession) -> String {
        several ? "\(label(for: session)). \(line)" : line
    }

    func missionStarted(_ session: MissionSession) {
        fx.play(.missionStart)
        fx.say(spoken((kidsMode ? SoundFX.kidsStartLines : SoundFX.startLines).randomElement()!, for: session), interrupt: false)
    }

    func approvalNeeded(_ session: MissionSession, _ request: ApprovalRequest) {
        fx.play(.approvalNeeded)
        Notifier.shared.post(title: several ? "\(label(for: session)) needs your approval" : "Tristan needs your approval",
                             body: "\(request.summary) \(request.detail)")
        if !session.announcedApproval {
            session.announcedApproval = true
            fx.say(spoken((kidsMode ? SoundFX.kidsApprovalLines : SoundFX.approvalLines).randomElement()!, for: session), interrupt: false)
        }
    }

    func approvalAnswered(_ approved: Bool) {
        fx.play(approved ? .approved : .denied)
    }

    func missionEnded(_ session: MissionSession, success: Bool, summary: String) {
        fx.play(success ? .missionComplete : .missionFailed)
        let prefix = several ? "\(label(for: session)): " : ""
        Notifier.shared.post(title: prefix + (success ? "Mission complete" : "Mission failed"), body: summary)
        if success {
            // Tasks given by voice get the result read back; others get a short confirmation.
            let line = session.spokenReply ? String(summary.prefix(240)) : spoken((kidsMode ? SoundFX.kidsDoneLines : SoundFX.doneLines).randomElement()!, for: session)
            fx.say(line, interrupt: false)
        } else {
            fx.say(spoken((kidsMode ? SoundFX.kidsFailLines : SoundFX.failLines).randomElement()!, for: session), interrupt: false)
        }
    }

    func record(_ session: MissionSession, status: String, summary: String) {
        guard session.markRecorded() else { return }
        records.insert(MissionRecord(task: session.currentTask, provider: session.provider.rawValue, mode: approvalMode.rawValue, status: status,
                                     summary: String(summary.prefix(240)), folder: session.workingDirectory.path), at: 0)
        if records.count > 100 { records.removeLast(records.count - 100) }
        history?.save(records)
    }

    // MARK: music

    private func runMusic(_ command: MusicCommand, viaVoice: Bool) {
        draft = ""
        Task { [weak self] in
            guard let self else { return }
            let reply = await self.music.perform(command)
            self.active.note("♪ \(reply)")
            if viaVoice { self.fx.say(reply) }
        }
    }

    // MARK: voice

    /// Push-to-talk: transcript streams into `draft`; releasing sends it as a task.
    func startListening() {
        guard !listening else { return }
        guard !micBusy, !busy else {
            if !busy { status = "TRISTAN IS RESPONDING" }
            return
        }
        listening = true
        draft = ""
        if !busy { status = "LISTENING" }
        fx.stopSpeaking()
        fx.play(.listenStart)
        voice.start(onText: { [weak self] in self?.draft = $0 }, onError: { [weak self] message in
            guard let self else { return }
            self.listening = false
            self.status = "STANDING BY"
            self.active.note(message, .warn)
        })
    }

    func stopListening(send: Bool = true) {
        guard listening else { return }
        listening = false
        voice.stop()
        fx.play(.listenStop)
        // The microphone stays shut from here until Tristan has answered.
        micGrace?.cancel()
        micGrace = nil
        micBusy = true
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
            self.refreshMic()
        }
    }

    /// Keeps `micBusy` true while any session works or Tristan speaks, and for a moment after, which covers the gap
    /// between a mission ending and its spoken answer starting.
    private func refreshMic() {
        if sessions.contains(where: \.busy) || speaking {
            micGrace?.cancel()
            micGrace = nil
            if !micBusy { micBusy = true }
        } else if micBusy, micGrace == nil, !listening {
            micGrace = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled, let self else { return }
                self.micGrace = nil
                self.micBusy = false
                self.refreshWake()
            }
        }
    }

    /// The wake listener only runs while the feature is on and nothing else needs the microphone.
    private func refreshWake() {
        wake.setRunning(wakeOn && !micBusy && !active.busy && !listening)
    }

    private func wakeStarted() {
        music.setDuck("mic", active: true)
        status = "LISTENING"
        draft = ""
        fx.stopSpeaking()
        fx.play(.listenStart)
    }

    private func wakeSubmit(_ text: String) {
        micGrace?.cancel()
        micGrace = nil
        micBusy = true
        music.setDuck("mic", active: false)
        fx.play(.listenStop)
        draft = ""
        submit(text, viaVoice: true)
        refreshMic()
    }

    private func wakeCancelled() {
        music.setDuck("mic", active: false)
        draft = ""
        if phase == .idle { status = "STANDING BY" }
    }

    // MARK: history

    /// Puts a past mission's task in the box. If the current session is busy it opens a new one rather than waiting.
    func rerun(_ record: MissionRecord) {
        let folder = FileManager.default.fileExists(atPath: record.folder) ? URL(fileURLWithPath: record.folder) : nil
        let kind = ProviderKind(rawValue: record.provider)
        var target = active
        if active.busy, let fresh = newSession(provider: kind, folder: folder) { target = fresh }
        else {
            if let kind { target.provider = kind }
            if let folder { target.workingDirectory = folder }
        }
        target.draft = record.task
        showHistory = false
    }

    func clearHistory() {
        records = []
        history?.save([])
    }

    // MARK: folders

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = workingDirectory
        if panel.runModal() == .OK, let url = panel.url { workingDirectory = url }
    }
}
