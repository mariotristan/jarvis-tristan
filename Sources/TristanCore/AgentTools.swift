import Foundation

package struct ToolCallResult {
    let text: String
    let isError: Bool
}

package struct ToolDefinition {
    let name: String
    let description: String
    let properties: [String: [String: String]]
    let required: [String]
}

/// Tool definitions, rendered in whichever wire format a provider needs.
package enum AgentToolSpec {
    static let definitions: [ToolDefinition] = [
        ToolDefinition(name: "read_file", description: "Read a UTF-8 text file inside the working folder.",
                       properties: ["path": ["type": "string", "description": "Path relative to the working folder"]], required: ["path"]),
        ToolDefinition(name: "list_dir", description: "List the entries of a directory inside the working folder. Use \".\" for the folder itself.",
                       properties: ["path": ["type": "string", "description": "Directory path relative to the working folder"]], required: ["path"]),
        ToolDefinition(name: "write_file", description: "Create or overwrite a text file inside the working folder.",
                       properties: ["path": ["type": "string", "description": "Path relative to the working folder"],
                                    "content": ["type": "string", "description": "Full file contents"]], required: ["path", "content"]),
    ] + shellTools

    static func shellDescription(for flavor: ShellFlavor) -> String {
        let shell = flavor == .powershell ? "PowerShell" : "zsh"
        return "Run a shell command (\(shell)) in the working folder. 60 second timeout."
    }

    /// Running commands needs a shell, which exists on the Mac and Windows. On iOS the model is simply never offered the tool.
    private static var shellTools: [ToolDefinition] {
        #if !os(iOS)
        return [ToolDefinition(name: "run_command", description: shellDescription(for: .current),
                               properties: ["command": ["type": "string", "description": "The command to run"]], required: ["command"])]
        #else
        return []
        #endif
    }

    private static func schema(_ tool: ToolDefinition) -> [String: Any] {
        ["type": "object", "properties": tool.properties, "required": tool.required]
    }

    /// Bedrock Converse `toolSpec` format.
    static var converseTools: [[String: Any]] {
        definitions.map { ["toolSpec": ["name": $0.name, "description": $0.description, "inputSchema": ["json": schema($0)]]] }
    }

    /// OpenAI / Azure OpenAI function-calling format.
    static var openAITools: [[String: Any]] {
        definitions.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": schema($0)]] }
    }
}

/// Symlink-safe path resolution that also works for files that do not exist yet.
package enum SafePath {
    /// Resolves symlinks in the deepest existing ancestor, then appends the not-yet-existing tail.
    /// Returns nil if the path runs through a dangling symlink, whose target cannot be checked.
    static func real(_ url: URL) -> String? {
        real(url, parent: { $0.deletingLastPathComponent() })
    }

    /// `parent` and `exists` are seams for tests: on Windows a drive root (`C:\`, or a missing `Q:\`) is its own
    /// parent and never equals "/", so the walk stops when the parent stops changing (the root must then pass
    /// `fileExists`, else nil), and gives up (nil) after a bounded number of steps.
    static func real(_ url: URL, parent: (URL) -> URL,
                     exists: (String) -> Bool = { (try? FileManager.default.attributesOfItem(atPath: $0)) != nil }) -> String? {
        let fm = FileManager.default
        var existing = url.standardizedFileURL
        var tail: [String] = []
        var steps = 0
        while !exists(existing.path), existing.path != "/" {
            let up = parent(existing)
            steps += 1
            if up.path == existing.path { break }   // a self-parent root (`C:\`): confirmed or refused below
            guard steps < 4096 else { return nil }
            tail.insert(existing.lastPathComponent, at: 0)
            existing = up
        }
        if !fm.fileExists(atPath: existing.path), existing.path != "/" { return nil }   // dangling symlink
        let resolved = ([existing.resolvingSymlinksInPath().path] + tail).joined(separator: "/")
        // A `..` that survived resolution (Foundation on Windows can leave one, e.g. for `D:/..`) means the walk
        // did not end on a real folder: refuse rather than guess.
        guard !resolved.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..") else { return nil }
        return resolved
    }
}

/// Confines file access to the working folder (symlinks resolved) and runs the tools.
package struct ToolSandbox {
    let root: URL
    private static let maxOutput = 20_000

    private var rootPath: String { SafePath.real(root) ?? root.standardizedFileURL.path }

    func resolve(_ path: String) -> URL? {
        resolve(path, flavor: .current)
    }

    /// `flavor` is a seam for tests; callers use `.current`.
    func resolve(_ path: String, flavor: PathFlavor) -> URL? {
        let url: URL
        switch PathContainment.form(of: path, flavor: flavor) {
        case .absolute: url = URL(fileURLWithPath: path)
        case .relative: url = root.appendingPathComponent(path)
        case .rejected: return nil
        }
        guard let resolved = SafePath.real(url),
              PathContainment.contains(root: rootPath, path: resolved, flavor: flavor) else { return nil }
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

    #if !os(iOS)
    func run(_ command: String, timeout: TimeInterval = 60) async -> ToolCallResult {
        // The box stops the command with everything it started, on timeout or when the mission is cancelled.
        let box = ProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shell = ShellRunner.command(for: command, flavor: .current)
                let process: Process
                do { process = try ProcessLauncher.prepare(shell.tool, shell.arguments, directory: root, extraEnvironment: [:], addToolPaths: false) } catch {
                    continuation.resume(returning: .init(text: "Could not run command: \(error.localizedDescription)", isError: true))
                    return
                }
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    guard try box.start(process) else {
                        continuation.resume(returning: .init(text: "Command cancelled", isError: true))
                        return
                    }
                } catch {
                    continuation.resume(returning: .init(text: "Could not run command: \(error.localizedDescription)", isError: true))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { box.terminate() } }
                DispatchQueue.global().async {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    var text = String(decoding: data, as: UTF8.self)
                    if text.count > Self.maxOutput { text = String(text.prefix(Self.maxOutput)) + "\n[output truncated]" }
                    let status = process.terminationStatus
                    continuation.resume(returning: .init(text: text + "\n[exit status \(status)]", isError: status != 0))
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    #endif

    private func outside(_ path: String) -> ToolCallResult {
        .init(text: "\(path) is outside the working folder, which is not allowed.", isError: true)
    }
}

/// Which tool calls need the operator's approval, per approval mode.
package struct ToolPolicy {
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
