#if os(Windows)
import Foundation
import WinSDK

/// Puts the fake provider CLIs in scripts/ci/fakes (claude, copilot, az, aws) first on PATH for one test, with any
/// extra variables the fakes read, and puts everything back in `restore()`. A copy of Tests/TristanCoreTests/FakeCLIFixture.swift.
final class FakeCLIs {
    /// scripts\ci\fakes in this checkout.
    static let folder: String = {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return native(repo.appendingPathComponent("scripts").appendingPathComponent("ci").appendingPathComponent("fakes"))
    }()

    private var saved: [String: String?] = [:]

    /// `prepend` goes in front of PATH, in order.
    init(prepend: [String] = [FakeCLIs.folder], extra: [String: String] = [:]) {
        set("Path", (prepend + [Self.get("PATH") ?? ""]).joined(separator: ";"))
        for (name, value) in extra { set(name, value) }
    }

    func set(_ name: String, _ value: String?) {
        if saved[name] == nil { saved[name] = .some(Self.get(name)) }
        Self.put(name, value)
    }

    func restore() {
        for (name, value) in saved { Self.put(name, value) }
        saved = [:]
    }

    static func get(_ name: String) -> String? {
        ProcessInfo.processInfo.environment.first { $0.key.uppercased() == name.uppercased() }?.value
    }

    /// Changes this process's environment, which `ProcessLauncher` reads and hands to the programs it starts.
    static func put(_ name: String, _ value: String?) {
        _ = name.withCString(encodedAs: UTF16.self) { wideName -> Bool in
            guard let value else { return SetEnvironmentVariableW(wideName, nil) }
            return value.withCString(encodedAs: UTF16.self) { SetEnvironmentVariableW(wideName, $0) }
        }
    }

    static func native(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
    }

    /// True while `tasklist` lists the pid.
    static func isAlive(_ pid: Int32) -> Bool {
        let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        let tasklist = Process()
        tasklist.executableURL = URL(fileURLWithPath: root + "\\System32\\tasklist.exe")
        tasklist.arguments = ["/FI", "PID eq \(pid)", "/NH", "/FO", "CSV"]
        let out = Pipe()
        tasklist.standardOutput = out
        tasklist.standardError = FileHandle.nullDevice
        tasklist.standardInput = FileHandle.nullDevice
        guard (try? tasklist.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        tasklist.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("\"\(pid)\"")
    }

    static func eventually(_ seconds: Double = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }

    /// The two pids a fake's "sleep" task wrote ("<fake> <its child>"), once the file is complete.
    static func pids(in file: URL) -> [Int32]? {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.hasSuffix("\n") else { return nil }
        let pids = text.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        return pids.count == 2 ? pids : nil
    }

    /// The `FAKE_ARGV_LOG` lines: one argument list per fake started.
    static func argvLog(_ file: URL) -> [(tool: String, argv: [String])] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let tool = object["tool"] as? String, let argv = object["argv"] as? [String] else { return nil }
            return (tool, argv)
        }
    }
}
#endif
