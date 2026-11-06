import SwiftUI
import AppKit

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
    @Published var provider: ProviderKind = .demo
    @Published var workingDirectory = FileManager.default.homeDirectoryForCurrentUser

    private var approval: CheckedContinuation<Bool, Never>?
    private var runner: Task<Void, Never>?

    var busy: Bool { phase == .working || phase == .awaitingApproval }

    func submit(_ prompt: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !busy else { return }
        log = []
        code = ""
        guard let impl = provider.makeProvider() else {
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

    func resolve(_ approved: Bool) {
        guard let cont = approval else { return }
        approval = nil
        pending = nil
        phase = .working
        add(approved ? "Authorization granted" : "Authorization denied", approved ? .ok : .warn)
        cont.resume(returning: approved)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = workingDirectory
        if panel.runModal() == .OK, let url = panel.url { workingDirectory = url }
    }

    private func ask(_ request: ApprovalRequest) async -> Bool {
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
        case .done(let s): phase = .done; status = "MISSION COMPLETE"; add(s, .ok)
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
