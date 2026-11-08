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
            + "provider and folder. If that folder is gone it stops; pass --folder to choose another one.")

    @Option(help: "Only missions whose task, summary, provider, mode or folder name contain every word.")
    var query: String = ""

    @Option(help: "Only missions with this status: all, done or failed.")
    var status: HistoryStatus = .all

    @Option(help: "Run the task of the nth listed mission again.")
    var rerun: Int?

    @Option(help: "With --rerun: the folder to run in when the mission's own folder is gone (it must exist).")
    var folder: String?

    func validate() throws {
        if folder != nil && rerun == nil { throw ValidationError("--folder only goes with --rerun.") }
    }

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
            Terminal.writeOutput("\(index + 1)  \(oneLine(record.status, 20))  \(formatter.string(from: record.date))  \(oneLine(record.task, 80))\n")
            if !record.summary.isEmpty { Terminal.writeOutput("    \(oneLine(record.summary, 100))\n") }
        }
        return .ok
    }

    /// The same path as `tristan run`: ask mode, the record's provider (Ollama if unknown), in the record's folder.
    /// A folder that is gone is never replaced silently: the person picks one with --folder or nothing runs.
    private func runAgain(_ record: MissionRecord, environment: CLIEnvironment) async -> ExitCode {
        func isFolder(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let chosen: String
        if let folder {
            let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let resolved = URL(fileURLWithPath: folder, isDirectory: true, relativeTo: base).standardizedFileURL.path
            guard isFolder(resolved) else {
                Terminal.writeError("tristan: the folder \(oneLine(folder, 120)) does not exist.\n")
                return .usage
            }
            chosen = resolved
        } else if isFolder(record.folder) {
            chosen = record.folder
        } else {
            Terminal.writeError("tristan: the folder this mission ran in no longer exists (\(oneLine(record.folder, 120))). "
                + "Nothing was run; pass --folder <path> to choose where to run it.\n")
            return .usage
        }
        let arguments = ["--provider", (CLIProvider(rawValue: record.provider) ?? .ollama).rawValue, "--folder", chosen]
        do {
            let command = try RunCommand.parse(arguments + ["--", record.task])
            return await command.execute(environment: environment)
        } catch {
            Terminal.writeError("tristan: \(RunCommand.message(for: error))\n")
            return .usage
        }
    }
}
