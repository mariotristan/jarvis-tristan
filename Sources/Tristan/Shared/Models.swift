import Foundation

// Types shared by the Mac app and the iOS app. This folder must not import AppKit or UIKit.

enum Phase: String, Codable { case idle, working, awaitingApproval, done, failed }

/// How much supervision an agent run gets.
enum ApprovalMode: String, CaseIterable, Identifiable {
    case ask = "ASK"
    case auto = "AUTO"
    case yolo = "YOLO"

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .ask: return "Tristan asks you before every action that needs permission. Safest."
        case .auto: return "Routine actions run without asking; risky ones are blocked or still ask. Claude: its own safety classifier. Bedrock: in-folder writes and plain commands."
        case .yolo: return "All permission checks are skipped. The agent can edit files and run any command without asking."
        }
    }

    /// Value for `claude --permission-mode`. ASK uses the prompt tool instead of a hands-off mode.
    var claudeFlag: String {
        switch self {
        case .ask: return "manual"
        case .auto: return "auto"
        case .yolo: return "bypassPermissions"
        }
    }
}

/// One finished mission. Only the task and a short summary are stored, never the code or file contents.
struct MissionRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var task: String
    var provider: String
    var mode: String
    var status: String      // "done", "failed" or "aborted"
    var summary: String
    var folder: String
}

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "ALL", done = "DONE", failed = "FAILED", aborted = "ABORTED"
    var id: String { rawValue }
}

extension Array where Element == MissionRecord {
    /// Every word in `query` must appear somewhere in the task, summary, provider, mode or folder name.
    func filtered(query: String, status: HistoryFilter) -> [MissionRecord] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return filter { record in
            if status != .all, record.status != status.rawValue.lowercased() { return false }
            let haystack = [record.task, record.summary, record.provider, record.mode, (record.folder as NSString).lastPathComponent]
                .joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}
