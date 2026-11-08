import Foundation
import TristanCore
#if os(Windows)
import WinSDK
#endif

/// One running `tristan run`, as listed by `tristan sessions`.
struct SessionInfo: Codable, Equatable {
    var pid: Int32
    var task: String
    var provider: String
    var folder: String
    var started: Date
}

/// One small JSON file per running `tristan run` (`<directory>/<pid>.json`): task, provider, folder and start time,
/// never a secret. Entries whose process is gone, and files that cannot be read, are removed when listing.
struct SessionRegistry {
    let directory: URL
    private let isAlive: (Int32) -> Bool

    init(directory: URL, isAlive: @escaping (Int32) -> Bool) {
        self.directory = directory
        self.isAlive = isAlive
    }

    /// The default folder: `%APPDATA%\Tristan\sessions` on Windows, Application Support on macOS, else `~/.config`.
    static var defaultDirectory: URL {
        #if os(Windows)
        return WindowsAppData.directory.appendingPathComponent("sessions", isDirectory: true)
        #elseif os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tristan/sessions", isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/tristan/sessions", isDirectory: true)
        #endif
    }

    static func processIsAlive(_ pid: Int32) -> Bool {
        #if os(Windows)
        guard let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) else {
            return GetLastError() == DWORD(ERROR_ACCESS_DENIED)   // exists, but belongs to someone else
        }
        defer { CloseHandle(handle) }
        var code: DWORD = 0
        return GetExitCodeProcess(handle, &code) && code == DWORD(STILL_ACTIVE)
        #else
        return kill(pid, 0) == 0 || errno == EPERM
        #endif
    }

    static var live: SessionRegistry { SessionRegistry(directory: defaultDirectory, isAlive: processIsAlive) }

    private func file(_ pid: Int32) -> URL { directory.appendingPathComponent("\(pid).json") }

    func register(pid: Int32, task: String, provider: String, folder: String) {
        let info = SessionInfo(pid: pid, task: String(task.prefix(200)), provider: provider, folder: folder, started: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(info) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: file(pid), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(pid).path)
    }

    func unregister(pid: Int32) {
        try? FileManager.default.removeItem(at: file(pid))
    }

    func active() -> [SessionInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [SessionInfo] = []
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let info = try? decoder.decode(SessionInfo.self, from: data),
                  name == "\(info.pid).json" else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if isAlive(info.pid) { result.append(info) } else { try? FileManager.default.removeItem(at: url) }
        }
        return result.sorted { ($0.started, $0.pid) < ($1.started, $1.pid) }
    }
}
