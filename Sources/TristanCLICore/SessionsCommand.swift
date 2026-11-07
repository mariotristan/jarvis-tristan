import ArgumentParser
import Foundation

/// `tristan sessions`: the runs that are going on now, from any terminal.
struct SessionsCommand: ParsableCommand, CLICommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "List the missions running now (pid, provider, folder, task).")

    func execute(environment: CLIEnvironment) async -> ExitCode {
        let active = environment.sessions.active()
        guard !active.isEmpty else {
            Terminal.writeOutput("No active sessions.\n")
            return .ok
        }
        for info in active {
            Terminal.writeOutput("\(info.pid)  \(oneLine(info.provider, 20))  \(oneLine(info.folder, 60))  \(oneLine(info.task, 100))\n")
        }
        return .ok
    }
}

/// Model- or user-controlled text for one terminal line: line breaks become spaces, long text is cut, control
/// characters are made visible (the same helper the approval prompt uses).
func oneLine(_ text: String, _ limit: Int) -> String {
    let flat = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
    let cut = flat.count > limit ? String(flat.prefix(limit)) + "..." : flat
    return TerminalApprover.visible(cut)
}
