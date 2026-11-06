import SwiftUI

/// One session: its own provider, folder, mission log, code stream and approvals, plus the task that runs it.
/// `Session` (the hub) owns several, so a Claude session and a Copilot session can work at the same time.
@MainActor
final class MissionSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published var phase: Phase = .idle
    @Published var log: [LogEntry] = []
    @Published var code = ""
    @Published var status = "STANDING BY"
    @Published var pending: ApprovalRequest?
    @Published var provider: ProviderKind
    @Published var workingDirectory: URL
    @Published var draft = ""
    /// What this session has already done. It survives the end of a mission and goes in front of the next task.
    @Published private(set) var memory = ConversationMemory()
    /// Changes at the start of every mission, so a connected phone knows when to clear its log.
    @Published private(set) var missionID = UUID().uuidString

    weak var hub: Session?
    private var approval: CheckedContinuation<Bool, Never>?
    private var runner: Task<Void, Never>?
    private var recorded = false
    private var remembered = false
    var announcedApproval = false
    private(set) var spokenReply = false
    private(set) var currentTask = ""

    var busy: Bool { phase == .working || phase == .awaitingApproval }

    init(provider: ProviderKind, workingDirectory: URL, memory: ConversationMemory = ConversationMemory()) {
        self.provider = provider
        self.workingDirectory = workingDirectory
        self.memory = memory
    }

    // MARK: running

    func submit(_ prompt: String, viaVoice: Bool = false) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
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
        remembered = false
        // A session without its hub cannot know the approval mode or the allow rules, so it must not run anything at all.
        guard let hub else {
            phase = .failed
            status = "OFFLINE"
            add("This session is detached from Tristan and cannot start a mission.", .warn)
            return
        }
        guard let impl = hub.providerFactory(provider, hub.approvalMode) else {
            phase = .failed
            status = "OFFLINE"
            add("\(provider.rawValue) is not wired up yet", .warn)
            return
        }
        phase = .working
        status = "INITIALIZING"
        announcedApproval = false
        add("Task: \(prompt)", .info)
        if case let others = hub.sessionsBusy(in: workingDirectory, besides: self), !others.isEmpty {
            add("⚠︎ \(others.joined(separator: ", ")) is also working in this folder, so edits may collide.", .warn)
        }
        hub.missionStarted(self)
        let directory = workingDirectory
        let briefed = memory.compose(task: prompt, folder: directory.path)
        if briefed != prompt { add("Remembering \(memory.exchanges.filter { $0.folder == directory.path }.count) earlier mission(s) from this session", .info) }
        runner = Task { [weak self] in
            let stream = impl.run(task: briefed, workingDirectory: directory) { [weak self] request in
                await self?.ask(request) ?? false
            }
            for await event in stream { self?.handle(event) }
            self?.streamEnded()
        }
    }

    func cancel() {
        runner?.cancel()
        resolve(false)
        if busy {
            phase = .failed
            status = "ABORTED"
            add("Aborted by operator", .warn)
            remember(status: "aborted", summary: "Aborted by the operator before it finished")
            hub?.record(self, status: "aborted", summary: "Aborted by operator")
        }
    }

    // MARK: approvals

    func resolve(_ approved: Bool, always: Bool = false) {
        guard let continuation = approval else { return }
        if approved, always, let rule = pending?.rule, let hub, !hub.allowRules.contains(rule) {
            hub.allowRules.append(rule)
            add("Always allowed: \(rule.label)", .ok)
        }
        approval = nil
        pending = nil
        phase = .working
        add(approved ? "Authorization granted" : "Authorization denied", approved ? .ok : .warn)
        hub?.approvalAnswered(approved)
        continuation.resume(returning: approved)
    }

    private func ask(_ request: ApprovalRequest) async -> Bool {
        if let rule = request.rule, hub?.allowRules.contains(rule) == true {
            add("Auto-allowed by rule: \(rule.label)", .ok)
            return true
        }
        pending = request
        phase = .awaitingApproval
        status = "AWAITING AUTHORIZATION"
        add(request.summary, .warn)
        hub?.approvalNeeded(self, request)
        return await withCheckedContinuation { approval = $0 }
    }

    // MARK: events

    private func handle(_ event: AgentEvent) {
        switch event {
        case .status(let text): if phase != .awaitingApproval { status = text }
        case .log(let text): add(text, .step)
        case .code(let text): code += text
        case .done(let text):
            phase = .done; status = "MISSION COMPLETE"; add(text, .ok)
            remember(status: "done", summary: text)
            hub?.record(self, status: "done", summary: text)
            hub?.missionEnded(self, success: true, summary: text)
        case .failed(let text):
            phase = .failed; status = "MISSION FAILED"; add(text, .warn)
            remember(status: "failed", summary: text)
            hub?.record(self, status: "failed", summary: text)
            hub?.missionEnded(self, success: false, summary: text)
        }
    }

    private func streamEnded() {
        if busy {
            phase = .done
            status = "MISSION COMPLETE"
            remember(status: "done", summary: "Complete")
            hub?.record(self, status: "done", summary: "Complete")
        }
    }

    /// True the first time it is called for a mission; the hub uses it to record each mission once.
    func markRecorded() -> Bool {
        guard !recorded, !currentTask.isEmpty else { return false }
        recorded = true
        return true
    }

    /// Keeps the finished mission in the session's context, once per mission.
    private func remember(status: String, summary: String) {
        guard !remembered, !currentTask.isEmpty else { return }
        remembered = true
        let actions = log.filter { $0.kind == .step }.map(\.text)
        memory.record(task: currentTask, actions: actions, outcome: summary, status: status, folder: workingDirectory.path)
        hub?.memoryChanged()
    }

    /// Forgets everything this session did, so the next mission starts from a blank slate in the same tab.
    func forgetConversation() {
        guard !busy else { return }
        memory.clear()
        add("Session memory cleared", .info)
        hub?.memoryChanged()
    }

    func note(_ text: String, _ kind: LogEntry.Kind = .info) { add(text, kind) }

    private func add(_ text: String, _ kind: LogEntry.Kind) {
        log.append(LogEntry(text: text, kind: kind))
    }
}
