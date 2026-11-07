import Foundation

/// Drives the `claude` CLI headlessly and turns its stream-json output into HUD events.
/// Every permission prompt is routed back to the operator through the PermissionServer / MCP shim.
package struct ClaudeCodeProvider: AgentProvider {
    var mode: ApprovalMode = .ask

    package init(mode: ApprovalMode = .ask) { self.mode = mode }

    package func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AsyncStream { c in
            let box = ProcessBox()
            let server = PermissionServer(workingDirectory: workingDirectory) { tool, detail, rule in
                await approve(ApprovalRequest(summary: "Allow \(tool)?", detail: detail, rule: rule))
            }
            let worker = Task {
                var arguments = ["-p", task,
                                 "--output-format", "stream-json", "--verbose",
                                 "--permission-mode", mode.claudeFlag]
                if mode == .ask {
                    // Route every permission prompt back to the operator through the MCP shim.
                    guard server.start(), let executable = Bundle.main.executablePath else {
                        c.yield(.failed("Could not start the approval bridge"))
                        c.finish(); return
                    }
                    let config: [String: Any] = ["mcpServers": ["tristan": [
                        "command": executable,
                        "args": ["--mcp-permission", server.socketPath],
                    ]]]
                    let configURL = server.directory.appendingPathComponent("mcp.json")
                    guard let json = try? JSONSerialization.data(withJSONObject: config),
                          (try? json.write(to: configURL)) != nil else {
                        c.yield(.failed("Could not write the MCP config"))
                        c.finish(); return
                    }
                    arguments += ["--mcp-config", configURL.path, "--permission-prompt-tool", "mcp__tristan__approve"]
                } else {
                    c.yield(.log("Approval mode \(mode.rawValue): no per-action prompts"))
                }

                let process: Process
                do {
                    process = try ProcessLauncher.prepare("claude", arguments, directory: workingDirectory, extraEnvironment: [:])
                } catch {
                    c.yield(.failed("Could not launch claude: \(error.localizedDescription)"))
                    server.stop(); c.finish(); return
                }
                guard box.set(process) else { server.stop(); c.finish(); return }
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice

                do { try process.run() } catch {
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
}

package enum ClaudeStream {
    static func parse(_ line: String) -> [AgentEvent] {
        guard let data = line.data(using: .utf8),
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
                            events.append(.code(CodeFence.block(path: (path as NSString).abbreviatingWithTildeInPath, content: body)))
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
