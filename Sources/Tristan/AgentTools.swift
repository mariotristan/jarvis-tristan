import Foundation

struct ToolCallResult {
    let text: String
    let isError: Bool
}

/// Tool definitions in the Bedrock Converse `toolSpec` format, for providers that need their own agent loop.
enum AgentToolSpec {
    static var converseTools: [[String: Any]] {
        [
            spec("read_file", "Read a UTF-8 text file inside the working folder.",
                 ["path": ["type": "string", "description": "Path relative to the working folder"]], required: ["path"]),
            spec("list_dir", "List the entries of a directory inside the working folder. Use \".\" for the folder itself.",
                 ["path": ["type": "string", "description": "Directory path relative to the working folder"]], required: ["path"]),
            spec("write_file", "Create or overwrite a text file inside the working folder.",
                 ["path": ["type": "string", "description": "Path relative to the working folder"],
                  "content": ["type": "string", "description": "Full file contents"]], required: ["path", "content"]),
            spec("run_command", "Run a shell command (zsh) in the working folder. 60 second timeout.",
                 ["command": ["type": "string", "description": "The command to run"]], required: ["command"]),
        ]
    }

    private static func spec(_ name: String, _ description: String, _ properties: [String: [String: String]],
                             required: [String]) -> [String: Any] {
        ["toolSpec": ["name": name, "description": description,
                      "inputSchema": ["json": ["type": "object", "properties": properties, "required": required]]]]
    }
}

/// Symlink-safe path resolution that also works for files that do not exist yet.
enum SafePath {
    /// Resolves symlinks in the deepest existing ancestor, then appends the not-yet-existing tail.
    /// Returns nil if the path runs through a dangling symlink, whose target cannot be checked.
    static func real(_ url: URL) -> String? {
        let fm = FileManager.default
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while (try? fm.attributesOfItem(atPath: existing.path)) == nil, existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        if !fm.fileExists(atPath: existing.path), existing.path != "/" { return nil }   // dangling symlink
        return ([existing.resolvingSymlinksInPath().path] + tail).joined(separator: "/")
    }
}

/// Confines file access to the working folder (symlinks resolved) and runs the tools.
struct ToolSandbox {
    let root: URL
    private static let maxOutput = 20_000

    private var rootPath: String { SafePath.real(root) ?? root.standardizedFileURL.path }

    func resolve(_ path: String) -> URL? {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        guard let resolved = SafePath.real(url), resolved == rootPath || resolved.hasPrefix(rootPath + "/") else { return nil }
        return URL(fileURLWithPath: resolved)
    }

    func relative(_ url: URL) -> String {
        let path = SafePath.real(url) ?? url.path
        return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
    }

    func read(_ path: String) -> ToolCallResult {
        guard let url = resolve(path) else { return outside(path) }
        guard let data = try? Data(contentsOf: url) else { return .init(text: "Could not read \(path)", isError: true) }
        guard data.count <= 200_000 else { return .init(text: "\(path) is too large (\(data.count) bytes)", isError: true) }
        guard let text = String(data: data, encoding: .utf8) else { return .init(text: "\(path) is not UTF-8 text", isError: true) }
        return .init(text: text, isError: false)
    }

    func list(_ path: String) -> ToolCallResult {
        guard let url = resolve(path) else { return outside(path) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return .init(text: "Could not list \(path)", isError: true)
        }
        let lines = names.sorted().map { name -> String in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDir)
            return isDir.boolValue ? name + "/" : name
        }
        return .init(text: lines.joined(separator: "\n"), isError: false)
    }

    func write(_ path: String, content: String) -> ToolCallResult {
        guard let url = resolve(path) else { return outside(path) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return .init(text: "Wrote \(content.utf8.count) bytes to \(relative(url))", isError: false)
        } catch {
            return .init(text: "Could not write \(path): \(error.localizedDescription)", isError: true)
        }
    }

    func run(_ command: String, timeout: TimeInterval = 60) async -> ToolCallResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = root
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch {
                continuation.resume(returning: .init(text: "Could not run command: \(error.localizedDescription)", isError: true))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                var text = String(decoding: data, as: UTF8.self)
                if text.count > Self.maxOutput { text = String(text.prefix(Self.maxOutput)) + "\n[output truncated]" }
                let status = process.terminationStatus
                continuation.resume(returning: .init(text: text + "\n[exit status \(status)]", isError: status != 0))
            }
        }
    }

    private func outside(_ path: String) -> ToolCallResult {
        .init(text: "\(path) is outside the working folder, which is not allowed.", isError: true)
    }
}

/// Which tool calls need the operator's approval, per approval mode.
struct ToolPolicy {
    let mode: ApprovalMode

    func needsApproval(tool: String, rule: ApprovalRule?) -> Bool {
        switch mode {
        case .yolo: return false
        case .ask: return true
        case .auto:
            // File writes are already confined to the folder; shell commands only skip the prompt when
            // they are plain (no chaining or redirection) and not on the risky-program list.
            return tool == "run_command" ? rule == nil : false
        }
    }
}
