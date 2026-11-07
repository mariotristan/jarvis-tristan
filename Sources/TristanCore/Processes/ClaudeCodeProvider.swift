import Foundation

/// Drives the `claude` CLI headlessly and turns its stream-json output into HUD events.
/// Every permission prompt is routed back to the operator through the PermissionServer / MCP shim.
package struct ClaudeCodeProvider: AgentProvider {
    var mode: ApprovalMode = .ask
    /// How the MCP shim reaches the approval server: a Unix socket on the Mac, token-protected loopback TCP on Windows.
    var transport: ApprovalTransportKind = .platformDefault
    /// The program started as Claude Code (tests point this at a stand-in).
    var claudeTool = "claude"
    /// The program Claude Code starts as the approval shim; nil means this program (tests point it at a built `tristan`).
    var shimCommand: String?

    package init(mode: ApprovalMode = .ask) { self.mode = mode }

    package func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AsyncStream { c in
            let box = ProcessBox()
            let server = PermissionServer(workingDirectory: workingDirectory, transport: transport) { tool, detail, rule in
                await approve(ApprovalRequest(summary: "Allow \(tool)?", detail: detail, rule: rule))
            }
            let worker = Task {
                var arguments = ["-p", task,
                                 "--output-format", "stream-json", "--verbose",
                                 "--permission-mode", mode.claudeFlag]
                if mode == .ask {
                    // Route every permission prompt back to the operator through the MCP shim.
                    guard server.start(), let endpoint = server.endpoint, let executable = shimCommand ?? Self.shimExecutable() else {
                        c.yield(.failed("Could not start the approval bridge"))
                        server.stop(); c.finish(); return
                    }
                    guard let configURL = Self.writeMCPConfig(executable: executable, endpoint: endpoint,
                                                              token: server.token, serverToken: server.serverToken,
                                                              in: server.directory) else {
                        c.yield(.failed("Could not write the MCP config"))
                        server.stop(); c.finish(); return
                    }
                    arguments += ["--mcp-config", ProcessLauncher.nativePath(configURL), "--permission-prompt-tool", "mcp__tristan__approve"]
                } else {
                    c.yield(.log("Approval mode \(mode.rawValue): no per-action prompts"))
                }

                let process: Process
                do {
                    process = try ProcessLauncher.prepare(claudeTool, arguments, directory: workingDirectory, extraEnvironment: [:])
                } catch {
                    c.yield(.failed(Self.launchFailure(error)))
                    server.stop(); c.finish(); return
                }
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice

                do {
                    guard try box.start(process) else { server.stop(); c.finish(); return }
                } catch {
                    c.yield(.failed("Could not launch claude: \(error.localizedDescription)"))
                    server.stop(); c.finish(); return
                }
                c.yield(.status("ONLINE"))
                var finished = false
                do {
                    for try await line in out.fileHandleForReading.bytes.lines {
                        for event in ClaudeStream.parse(line) {
                            switch event {
                            case .done, .failed: finished = true
                            default: break
                            }
                            c.yield(event)
                        }
                    }
                } catch {}
                process.waitUntilExit()
                if !finished {
                    c.yield(process.terminationStatus == 0 ? .done("Complete") : .failed("claude exited with status \(process.terminationStatus)"))
                }
                server.stop()
                c.finish()
            }
            c.onTermination = { _ in
                worker.cancel()
                box.terminate()
                server.stop()
            }
        }
    }

    /// Why `claude` could not be started. The Mac wording is unchanged; on Windows a missing CLI also names Git for
    /// Windows, which Claude Code needs there, and a refused task says what to remove.
    static func launchFailure(_ error: Error, windows: Bool = ProcessLauncher.isWindows) -> String {
        if windows, error is ToolNotFound {
            return "Could not launch claude: \(error.localizedDescription). Install Claude Code (`npm install -g @anthropic-ai/claude-code`) "
                + "and Git for Windows (`winget install -e --id Git.Git`), which Claude Code needs on Windows, then open a new terminal."
        }
        if windows, error is UnsafeArguments {
            return "Could not launch claude safely: \(error.localizedDescription). Remove those characters from the task and retry."
        }
        return "Could not launch claude: \(error.localizedDescription)"
    }

    /// Writes `<directory>/mcp.json`, which makes Claude Code start `executable --mcp-permission <endpoint>` as an MCP
    /// server. Tokens go in the server's `env` block (the shim reads them from its environment), never in `args`.
    static func writeMCPConfig(executable: String, endpoint: String, token: String?, serverToken: String?,
                               in directory: URL) -> URL? {
        var server: [String: Any] = [
            "command": executable,
            "args": ["--mcp-permission", endpoint],
        ]
        var environment: [String: String] = [:]
        if let token { environment[ApprovalTransport.tokenEnvironmentKey] = token }
        if let serverToken { environment[ApprovalTransport.serverTokenEnvironmentKey] = serverToken }
        if !environment.isEmpty { server["env"] = environment }
        let config: [String: Any] = ["mcpServers": ["tristan": server]]
        let url = directory.appendingPathComponent("mcp.json")
        guard let json = try? JSONSerialization.data(withJSONObject: config),
              (try? json.write(to: url)) != nil else { return nil }
        return url
    }

    /// The absolute path of this program, which Claude Code starts as the MCP shim.
    static func shimExecutable() -> String? {
        if let path = Bundle.main.executablePath, !path.isEmpty { return path }
        let windows = ProcessLauncher.isWindows
        let environment = ProcessInfo.processInfo.environment
        return absoluteExecutable(CommandLine.arguments.first ?? "",
                                  currentDirectory: FileManager.default.currentDirectoryPath,
                                  path: ProcessLauncher.value(of: "PATH", in: environment, windows: windows) ?? "",
                                  windows: windows,
                                  isFile: { path in
                                      var isDirectory: ObjCBool = false
                                      return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
                                  })
    }

    /// `argument0` (how this program was started) as an absolute path: as is when absolute, against the current folder
    /// when it has a separator, otherwise looked up on PATH the way a shell found it.
    static func absoluteExecutable(_ argument0: String, currentDirectory: String, path: String, windows: Bool,
                                   isFile: (String) -> Bool) -> String? {
        guard !argument0.isEmpty else { return nil }
        if windows ? ProcessLauncher.isAbsoluteWindowsPath(argument0) : argument0.hasPrefix("/") { return argument0 }
        if ExecutableResolver.hasSeparator(argument0, windows: windows) {
            if windows {
                var relative = argument0
                while relative.hasPrefix(".\\") || relative.hasPrefix("./") { relative.removeFirst(2) }
                return ExecutableResolver.join(currentDirectory, relative, windows: true)
            }
            let base = URL(fileURLWithPath: currentDirectory, isDirectory: true)
            return URL(fileURLWithPath: argument0, relativeTo: base).standardizedFileURL.path
        }
        return ExecutableResolver.resolve(argument0, searchPath: ProcessLauncher.searchPath(path, windows: windows),
                                          pathExt: windows ? [".EXE"] : [], isFile: isFile, windows: windows)
    }
}

package enum ClaudeStream {
    /// One line of `--output-format stream-json`. A line ending left on it (CR LF on Windows) is ignored.
    static func parse(_ line: String) -> [AgentEvent] {
        guard let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return [] }
        switch type {
        case "system":
            return obj["subtype"] as? String == "init" ? [.log("Session started")] : []
        case "assistant":
            guard let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { return [] }
            var events: [AgentEvent] = []
            for item in content {
                switch item["type"] as? String {
                case "text":
                    if let text = item["text"] as? String {
                        events.append(.status("RESPONDING"))
                        events.append(.code(text + "\n"))
                    }
                case "tool_use":
                    let name = item["name"] as? String ?? "tool"
                    let input = item["input"] as? [String: Any] ?? [:]
                    events.append(.status("EXECUTING \(name.uppercased())"))
                    events.append(.log(describe(tool: name, input: input)))
                    if let path = input["file_path"] as? String {
                        if let body = (input["content"] ?? input["new_string"]) as? String {
                            #if canImport(Darwin)
                            let shown = (path as NSString).abbreviatingWithTildeInPath
                            #else
                            let shown = path   // no `~` abbreviation outside Apple's Foundation
                            #endif
                            events.append(.code(CodeFence.block(path: shown, content: body)))
                        }
                    }
                default: break
                }
            }
            return events
        case "result":
            let text = obj["result"] as? String ?? "Complete"
            let isError = obj["is_error"] as? Bool ?? false
            return [isError ? .failed(text) : .done(text)]
        default:
            return []
        }
    }

    private static func describe(tool: String, input: [String: Any]) -> String {
        if let path = input["file_path"] as? String { return "\(tool) \((path as NSString).lastPathComponent)" }
        if let cmd = input["command"] as? String { return "\(tool): \(cmd.prefix(60))" }
        if let pattern = input["pattern"] as? String { return "\(tool): \(pattern.prefix(60))" }
        return tool
    }
}
