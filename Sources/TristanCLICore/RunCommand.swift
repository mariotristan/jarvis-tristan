import ArgumentParser
import Foundation
import TristanCore

/// A command `CLI.main` runs after parsing; it returns the process exit status.
protocol CLICommand {
    func execute() async -> ExitCode
}

/// `tristan run [--provider <name>] [--folder <path>] [--yes-routine | --yolo] "<task>"`
struct RunCommand: ParsableCommand, CLICommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a mission and answer its approvals in this terminal.",
        discussion: """
            Without --yes-routine or --yolo every action that needs approval is asked about here. With no terminal \
            attached (input piped or redirected) those actions are denied and tristan exits with status 3.
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

    func execute() async -> ExitCode {
        if Settings.bool("kidsMode") {
            // Same promise as the Mac app: in kids mode only the local model answers, and every action asks.
            guard provider == .ollama, mode == .ask else {
                Terminal.writeError("Kids mode is on: only Ollama answers, and --yes-routine and --yolo are off.\n")
                return .failed
            }
        }
        let approver = TerminalApprover(interactive: Terminal.inputIsTerminal, mode: mode,
                                        input: { readLine() }, output: Terminal.writeError)
        let agent = provider.make(mode: mode)
        let task = taskText, folder = folderURL
        Terminal.writeError("tristan: \(provider.rawValue) in \(folder.path) (approvals: \(mode.rawValue.lowercased()))\n")
        let work = Task {
            await Mission.run(provider: agent, task: task, folder: folder, approver: approver,
                              stdout: Terminal.writeOutput, stderr: Terminal.writeError)
        }
        Interrupt.install { work.cancel() }
        let code = await work.value
        Interrupt.missionEnded()
        return code
    }
}
