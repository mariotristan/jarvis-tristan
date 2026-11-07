import Foundation

/// JSON file in Application Support. Injectable so tests never touch the real history.
package final class HistoryStore {
    let url: URL
    let limit: Int

    init(url: URL, limit: Int = 100) {
        self.url = url
        self.limit = limit
    }

    package static let standard: HistoryStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return HistoryStore(url: base.appendingPathComponent("Tristan/history.json"))
    }()

    package func load() -> [MissionRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MissionRecord].self, from: data)) ?? []
    }

    package func save(_ records: [MissionRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(records.prefix(limit))) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
