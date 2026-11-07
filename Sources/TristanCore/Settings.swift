import Foundation

/// Where preferences live. UserDefaults on Apple platforms, a JSON file on Windows.
package protocol SettingsBackend: AnyObject {
    func object(forKey: String) -> Any?
    func set(_ value: Any?, forKey: String)
}

package final class UserDefaultsBackend: SettingsBackend {
    private let defaults: UserDefaults
    package init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    package func object(forKey key: String) -> Any? { defaults.object(forKey: key) }
    package func set(_ value: Any?, forKey key: String) { defaults.set(value, forKey: key) }
}

/// A flat JSON object on disk. Writes are atomic and the folder is created on demand.
/// Data values are stored as `{"$data": "<base64>"}` since JSON has no byte type.
package final class JSONFileBackend: SettingsBackend, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    package init(url: URL) { self.url = url }

    private func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    package func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        guard let value = load()[key] else { return nil }
        if let wrapped = value as? [String: Any], let text = wrapped["$data"] as? String {
            return Data(base64Encoded: text)
        }
        return value
    }

    package func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        switch value {
        case nil: all.removeValue(forKey: key)
        case let data as Data: all[key] = ["$data": data.base64EncodedString()]
        case let some?: all[key] = some
        }
        guard JSONSerialization.isValidJSONObject(all),
              let out = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? out.write(to: url, options: .atomic)
    }
}

package enum Settings {
    package nonisolated(unsafe) static var backend: SettingsBackend = makeDefaultBackend()

    private static func makeDefaultBackend() -> SettingsBackend {
        #if os(Windows)
        let env = ProcessInfo.processInfo.environment
        let base: URL
        if let appData = env["APPDATA"], !appData.isEmpty {
            base = URL(fileURLWithPath: appData, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
        }
        return JSONFileBackend(url: base.appendingPathComponent("Tristan", isDirectory: true)
            .appendingPathComponent("settings.json"))
        #else
        return UserDefaultsBackend()
        #endif
    }

    package static func string(_ key: String) -> String? { backend.object(forKey: key) as? String }
    package static func bool(_ key: String) -> Bool { (backend.object(forKey: key) as? Bool) ?? false }
    package static func data(_ key: String) -> Data? { backend.object(forKey: key) as? Data }
    package static func set(_ value: Any?, forKey key: String) { backend.set(value, forKey: key) }
}
