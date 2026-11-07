import ArgumentParser
import Foundation
import TristanCore

/// A command `CLI.main` runs after parsing; it returns the process exit status.
protocol CLICommand {
    func execute(environment: CLIEnvironment) async -> ExitCode
}

extension CLICommand {
    func execute() async -> ExitCode { await execute(environment: .live) }
}

/// `tristan run [--provider <name>] [--folder <path>] [--yes-routine | --yolo] "<task>"`
struct RunCommand: ParsableCommand, CLICommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a mission and answer its approvals in this terminal.",
        discussion: """
            Without --yes-routine or --yolo every action that needs approval is asked about here; answering \
            [a]lways saves a rule that later runs in a terminal apply without asking. With no terminal attached \
            (input piped or redirected) saved always-allow rules are ignored, every action that needs approval is \
            denied, and tristan exits with status 3.
            Exit status: 0 done, 1 failed, 2 usage error, 3 finished with something denied, 130 cancelled (Ctrl+C).
            """)

    @Option(help: "Which provider runs the mission: \(CLIProvider.allCases.map(\.rawValue).joined(separator: ", ")).")
    var provider: CLIProvider = .ollama

    @Option(help: "The folder the mission works in (default: the current folder).")
    var folder: String?

    @Flag(name: .customLong("yes-routine"), help: "Auto mode: routine actions run without asking; anything else still asks.")
    var yesRoutine = false

    @Flag(help: "YOLO mode: nothing asks. Use only in a folder you can afford to lose.")
    var yolo = false

    @Flag(name: .customLong("allow-cloud"),
          help: "Kids mode only: a parent allows this one run on a cloud provider by typing the parent PIN.")
    var allowCloud = false

    @Argument(help: "What to do, in plain words (quote it).")
    var task: [String] = []

    var mode: ApprovalMode { yolo ? .yolo : yesRoutine ? .auto : .ask }
    var taskText: String { task.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
    var folderURL: URL {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        guard let folder else { return base.standardizedFileURL }
        return URL(fileURLWithPath: folder, isDirectory: true, relativeTo: base).standardizedFileURL
    }

    func validate() throws {
        if yesRoutine && yolo { throw ValidationError("--yes-routine and --yolo cannot be used together.") }
        if taskText.isEmpty { throw ValidationError("Say what to do, for example: tristan run \"explain this project\"") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ValidationError("The folder \(folder ?? folderURL.path) does not exist.")
        }
    }

    func execute(environment: CLIEnvironment) async -> ExitCode {
        if let refusal = kidsRefusal(environment) { return refusal }
        let approver = TerminalApprover(interactive: environment.interactive, mode: mode,
                                        input: environment.readAnswer, output: Terminal.writeError)
        let task = taskText, folder = folderURL
        let pid = ProcessInfo.processInfo.processIdentifier
        environment.sessions.register(pid: pid, task: task, provider: provider.rawValue, folder: folder.path)
        let agent = environment.makeProvider(provider, mode)
        Terminal.writeError("tristan: \(provider.rawValue) in \(folder.path) (approvals: \(mode.rawValue.lowercased()))\n")
        let work = Task {
            await Mission.runReporting(provider: agent, task: task, folder: folder, approver: approver,
                                       stdout: Terminal.writeOutput, stderr: Terminal.writeError)
        }
        if environment.installInterrupt { Interrupt.install { work.cancel() } }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        // Record before reporting the end: Ctrl+C handling waits for `missionEnded` and then exits the process.
        // Same as the Mac: what the run said at the end, or "aborted" when it was stopped before it said anything.
        // Only the task and a short summary are kept, never the streamed code.
        let finished = result.final.map { (status: $0.status, summary: $0.text) }
            ?? (work.isCancelled ? (status: "aborted", summary: "Aborted by operator") : nil)
        if let finished {
            let store = HistoryStore(url: environment.historyURL)
            store.save([MissionRecord(task: task, provider: provider.rawValue, mode: mode.rawValue, status: finished.status,
                                      summary: String(finished.summary.prefix(240)), folder: folder.path)] + store.load())
        }
        environment.sessions.unregister(pid: pid)
        if environment.installInterrupt { Interrupt.missionEnded() }
        return result.code
    }
}
