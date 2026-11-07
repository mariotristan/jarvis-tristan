import Foundation

/// Why a setting could not be saved.
package enum SettingsError: Error, LocalizedError {
    /// The settings file exists but cannot be read or parsed. It is left exactly as it is (it may hold a parent's
    /// kids-mode choice), so nothing is saved until it is fixed or deleted.
    case unreadable(path: String, reason: String)
    /// Writing the file failed.
    case notSaved(path: String, reason: String)

    package var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason):
            return "The settings file \(path) cannot be read (\(reason)). Kids mode counts as on, and nothing is saved "
                + "until the file is fixed or deleted."
        case .notSaved(let path, let reason):
            return "The settings file \(path) could not be saved (\(reason))."
        }
    }
}

/// Where preferences live. UserDefaults on Apple platforms, a JSON file on Windows.
package protocol SettingsBackend: AnyObject {
    func object(forKey: String) -> Any?
    func set(_ value: Any?, forKey: String) throws
    /// Non-nil when the store exists but cannot be read: kids mode then counts as on and every write is refused.
    var unreadable: SettingsError? { get }
}

extension SettingsBackend {
    package var unreadable: SettingsError? { nil }
}

package final class UserDefaultsBackend: SettingsBackend {
    private let defaults: UserDefaults
    package init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    package func object(forKey key: String) -> Any? { defaults.object(forKey: key) }
    package func set(_ value: Any?, forKey key: String) { defaults.set(value, forKey: key) }
}

/// A flat JSON object on disk. Writes are atomic and the folder is created on demand.
/// Data values are stored as `{"$data": "<base64>"}` since JSON has no byte type.
///
/// Fails closed: a file that exists but cannot be read, or is not a JSON object (garbage, truncated, empty), is
/// `unreadable`. It then reads as empty, kids mode counts as on (`KidsRouting.kidsModeIsOn`), and every `set` throws
/// without touching the file, so a parent's kids-mode choice in it is never replaced by a default.
package final class JSONFileBackend: SettingsBackend, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    package init(url: URL) { self.url = url }

    /// The stored object; empty when there is no file yet.
    private func load() -> Result<[String: Any], SettingsError> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // No file is the normal first run. Anything else (no permission, a folder in its place) fails closed.
            if !FileManager.default.fileExists(atPath: url.path) { return .success([:]) }
            return .failure(.unreadable(path: url.path, reason: "it could not be opened"))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.unreadable(path: url.path, reason: "it is not valid settings JSON"))
        }
        return .success(object)
    }

    package var unreadable: SettingsError? {
        lock.lock(); defer { lock.unlock() }
        if case .failure(let error) = load() { return error }
        return nil
    }

    package func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        guard case .success(let all) = load(), let value = all[key] else { return nil }
        if let wrapped = value as? [String: Any], let text = wrapped["$data"] as? String {
            return Data(base64Encoded: text)
        }
        return value
    }

    package func set(_ value: Any?, forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        var all = try load().get()
        switch value {
        case nil: all.removeValue(forKey: key)
        case let data as Data: all[key] = ["$data": data.base64EncodedString()]
        case let some?: all[key] = some
        }
        guard JSONSerialization.isValidJSONObject(all),
              let out = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) else {
            throw SettingsError.notSaved(path: url.path, reason: "the value cannot be stored as JSON")
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try out.write(to: url, options: .atomic)
        } catch {
            throw SettingsError.notSaved(path: url.path, reason: error.localizedDescription)
        }
    }
}

#if os(Windows)
/// `%APPDATA%\Tristan`, the folder every Windows file of the app lives in (settings, history, sessions).
package enum WindowsAppData {
    package static var directory: URL {
        let base: URL
        if let appData = ProcessInfo.processInfo.environment["APPDATA"], !appData.isEmpty {
            base = URL(fileURLWithPath: appData, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
        }
        return base.appendingPathComponent("Tristan", isDirectory: true)
    }
}
#endif

package enum Settings {
    package nonisolated(unsafe) static var backend: SettingsBackend = makeDefaultBackend()

    private static func makeDefaultBackend() -> SettingsBackend {
        #if os(Windows)
        return JSONFileBackend(url: WindowsAppData.directory.appendingPathComponent("settings.json"))
        #else
        return UserDefaultsBackend()
        #endif
    }

    package static func string(_ key: String) -> String? { backend.object(forKey: key) as? String }
    package static func bool(_ key: String) -> Bool { (backend.object(forKey: key) as? Bool) ?? false }
    package static func data(_ key: String) -> Data? { backend.object(forKey: key) as? Data }
    /// Non-nil when the settings store exists but cannot be read (only the JSON file used off Apple platforms).
    package static var unreadable: SettingsError? { backend.unreadable }
    /// Saves `value`, or throws why it was not saved (an unreadable settings file is never overwritten).
    package static func write(_ value: Any?, forKey key: String) throws { try backend.set(value, forKey: key) }
    /// Saves `value` when it can; a refused write changes nothing. Commands that report errors use `write`.
    package static func set(_ value: Any?, forKey key: String) { try? backend.set(value, forKey: key) }
}
