import Foundation

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

/// JSON file in Application Support. Injectable so tests never touch the real history.
final class HistoryStore {
    let url: URL
    let limit: Int

    init(url: URL, limit: Int = 100) {
        self.url = url
        self.limit = limit
    }

    static let standard: HistoryStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return HistoryStore(url: base.appendingPathComponent("Tristan/history.json"))
    }()

    func load() -> [MissionRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MissionRecord].self, from: data)) ?? []
    }

    func save(_ records: [MissionRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(records.prefix(limit))) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
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
