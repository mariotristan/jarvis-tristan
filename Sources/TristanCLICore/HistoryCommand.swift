import ArgumentParser
import Foundation
import TristanCore

enum HistoryStatus: String, CaseIterable, ExpressibleByArgument {
    case all, done, failed
    var filter: HistoryFilter {
        switch self {
        case .all: return .all
        case .done: return .done
        case .failed: return .failed
        }
    }
}

/// `tristan history [--query <text>] [--status all|done|failed] [--rerun <n>]`
struct HistoryCommand: ParsableCommand, CLICommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "List past missions, newest first, or run one of them again.",
        discussion: "--rerun <n> runs the task of line n again like `tristan run` (approvals: ask), with that mission's "
            + "provider and folder when they are still available.")

    @Option(help: "Only missions whose task, summary, provider, mode or folder name contain every word.")
    var query: String = ""

    @Option(help: "Only missions with this status: all, done or failed.")
    var status: HistoryStatus = .all

    @Option(help: "Run the task of the nth listed mission again.")
    var rerun: Int?

    func execute(environment: CLIEnvironment) async -> ExitCode {
        let records = HistoryStore(url: environment.historyURL).load().filtered(query: query, status: status.filter)
        if let rerun {
            guard rerun >= 1, rerun <= records.count else {
                Terminal.writeError("tristan: --rerun \(rerun) is out of range (\(records.count) missions listed).\n")
                return .usage
            }
            return await runAgain(records[rerun - 1], environment: environment)
        }
        guard !records.isEmpty else {
            Terminal.writeOutput("No missions in the history.\n")
            return .ok
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for (index, record) in records.enumerated() {
            Terminal.writeOutput("\(index + 1)  \(record.status)  \(formatter.string(from: record.date))  \(oneLine(record.task, 80))\n")
            if !record.summary.isEmpty { Terminal.writeOutput("    \(oneLine(record.summary, 100))\n") }
        }
        return .ok
    }

    /// The same path as `tristan run`: ask mode, the record's provider (Ollama if unknown), its folder if it exists.
    private func runAgain(_ record: MissionRecord, environment: CLIEnvironment) async -> ExitCode {
        var arguments = ["--provider", (CLIProvider(rawValue: record.provider) ?? .ollama).rawValue]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: record.folder, isDirectory: &isDirectory), isDirectory.boolValue {
            arguments += ["--folder", record.folder]
        }
        do {
            let command = try RunCommand.parse(arguments + ["--", record.task])
            return await command.execute(environment: environment)
        } catch {
            Terminal.writeError("tristan: \(RunCommand.message(for: error))\n")
            return .usage
        }
    }
}
