import SwiftUI
import AppKit
import AVFoundation

enum Phase { case idle, working, awaitingApproval, done, failed }

struct LogEntry: Identifiable {
    enum Kind { case info, step, warn, ok }
    let id = UUID()
    let time = Date()
    let text: String
    let kind: Kind
}

@MainActor
final class Session: ObservableObject {
    @Published var phase: Phase = .idle
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
    @Published var showSettings = false
    @Published var draft = ""
    @Published var listening = false
    @Published var provider: ProviderKind = .demo
    @Published var workingDirectory = FileManager.default.homeDirectoryForCurrentUser

    private var approval: CheckedContinuation<Bool, Never>?
    private var runner: Task<Void, Never>?
    private let voice = VoiceInput()
    private let speaker = AVSpeechSynthesizer()
    private var spokenReply = false

    init() {
        if let saved = UserDefaults.standard.string(forKey: "approvalMode"), let mode = ApprovalMode(rawValue: saved) {
            approvalMode = mode
        }
        if let data = UserDefaults.standard.data(forKey: "allowRules"),
           let rules = try? JSONDecoder().decode([ApprovalRule].self, from: data) {
            allowRules = rules
        }
    }

    var busy: Bool { phase == .working || phase == .awaitingApproval }

    func submit(_ prompt: String, viaVoice: Bool = false) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !busy else { return }
        spokenReply = viaVoice
        log = []
        code = ""
        guard let impl = provider.makeProvider(mode: approvalMode) else {
            phase = .failed
            status = "OFFLINE"
            add("\(provider.rawValue) is not wired up yet", .warn)
            return
        }
        phase = .working
        status = "INITIALIZING"
        add("Task: \(prompt)", .info)
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
        if busy { phase = .failed; status = "ABORTED"; add("Aborted by operator", .warn) }
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
        cont.resume(returning: approved)
    }

    /// Push-to-talk: transcript streams into `draft`; releasing sends it as a task.
    func startListening() {
        guard !busy, !listening else { return }
        listening = true
        draft = ""
        status = "LISTENING"
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

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: String(text.prefix(240)))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        speaker.speak(utterance)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = workingDirectory
        if panel.runModal() == .OK, let url = panel.url { workingDirectory = url }
    }

    private func ask(_ request: ApprovalRequest) async -> Bool {
        if let rule = request.rule, allowRules.contains(rule) {
            add("Auto-allowed by rule: \(rule.label)", .ok)
            return true
        }
        pending = request
        phase = .awaitingApproval
        status = "AWAITING AUTHORIZATION"
        add(request.summary, .warn)
        return await withCheckedContinuation { approval = $0 }
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .status(let s): if phase != .awaitingApproval { status = s }
        case .log(let s): add(s, .step)
        case .code(let s): code += s
        case .done(let s):
            phase = .done; status = "MISSION COMPLETE"; add(s, .ok)
            if spokenReply { speak(s) }
        case .failed(let s): phase = .failed; status = "MISSION FAILED"; add(s, .warn)
        }
    }

    private func streamEnded() {
        if busy { phase = .done; status = "MISSION COMPLETE" }
    }

    private func add(_ text: String, _ kind: LogEntry.Kind) {
        log.append(LogEntry(text: text, kind: kind))
    }
}
