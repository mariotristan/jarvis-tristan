import Foundation

// Types shared by the Mac app and the iOS app. This folder must not import AppKit or UIKit.

package enum Phase: String, Codable { case idle, working, awaitingApproval, done, failed }

/// How much supervision an agent run gets.
package enum ApprovalMode: String, CaseIterable, Identifiable {
    case ask = "ASK"
    case auto = "AUTO"
    case yolo = "YOLO"

    package var id: String { rawValue }

    package var summary: String {
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
package struct MissionRecord: Codable, Identifiable, Equatable {
    package var id = UUID()
    package var date = Date()
    package var task: String
    package var provider: String
    package var mode: String
    package var status: String      // "done", "failed" or "aborted"
    package var summary: String
    package var folder: String

    package init(id: UUID = UUID(), date: Date = Date(), task: String, provider: String, mode: String, status: String,
                 summary: String, folder: String) {
        self.id = id
        self.date = date
        self.task = task
        self.provider = provider
        self.mode = mode
        self.status = status
        self.summary = summary
        self.folder = folder
    }
}

package enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "ALL", done = "DONE", failed = "FAILED", aborted = "ABORTED"
    package var id: String { rawValue }
}

package extension Array where Element == MissionRecord {
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
