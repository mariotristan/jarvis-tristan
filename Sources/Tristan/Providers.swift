import Foundation

struct ApprovalRequest: Identifiable, Sendable {
    let id = UUID()
    let summary: String
    let detail: String
}

enum AgentEvent: Sendable {
    case status(String)
    case log(String)
    case code(String)
    case done(String)
    case failed(String)
}

typealias Approver = @Sendable (ApprovalRequest) async -> Bool

protocol AgentProvider: Sendable {
    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent>
}

/// How much supervision an agent run gets.
enum ApprovalMode: String, CaseIterable, Identifiable {
    case ask = "ASK"
    case auto = "AUTO"
    case yolo = "YOLO"

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .ask: return "Tristan asks you before every action that needs permission. Safest."
        case .auto: return "Claude's own safety classifier decides. Routine actions run without asking, risky ones are blocked."
        case .yolo: return "All permission checks are skipped. The agent can edit files and run any command without asking."
        }
    }

    /// Value for `claude --permission-mode`. ASK uses the prompt tool instead of a hands-off mode.
    var claudeFlag: String {
        switch self {
        case .ask: return "manual"
        case .auto: return "auto"
        case .yolo: return "bypassPermissions"
        }
    }
}

enum ProviderKind: String, CaseIterable, Identifiable {
    case claude = "CLAUDE"
    case copilot = "COPILOT"
    case bedrock = "BEDROCK"
    case azure = "AZURE"
    case demo = "DEMO"

    var id: String { rawValue }

    func makeProvider(mode: ApprovalMode) -> AgentProvider? {
        switch self {
        case .claude: return ClaudeCodeProvider(mode: mode)
        case .demo: return DemoProvider()
        case .copilot, .bedrock, .azure: return nil
        }
    }
}

/// Scripted provider so the HUD can be played with without spending tokens.
struct DemoProvider: AgentProvider {
    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AsyncStream { c in
            let worker = Task {
                func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
                c.yield(.status("PLANNING"))
                c.yield(.log("Task received: \(task)"))
                await pause(900)
                c.yield(.log("Scanning \(workingDirectory.lastPathComponent)"))
                await pause(900)
                c.yield(.status("AWAITING AUTHORIZATION"))
                let ok = await approve(ApprovalRequest(summary: "Write Sources/auth.ts", detail: "Create a new file in \(workingDirectory.path)"))
                guard ok else { c.yield(.failed("Denied by operator")); c.finish(); return }
                c.yield(.status("WRITING CODE"))
                c.yield(.log("Writing Sources/auth.ts"))
                let snippet = """
                // Sources/auth.ts
                import { sign } from "./jwt";

                export function login(user: User): string {
                  const token = sign({ sub: user.id, role: user.role });
                  audit("login", user.id);
                  return token;
                }

                """
                for ch in snippet {
                    if Task.isCancelled { c.finish(); return }
                    c.yield(.code(String(ch)))
                    await pause(18)
                }
                c.yield(.status("RUNNING TESTS"))
                c.yield(.log("npm test: 12 passed"))
                await pause(1200)
                c.yield(.done("1 file changed, tests green"))
                c.finish()
            }
            c.onTermination = { _ in worker.cancel() }
        }
    }
}

/// Drives the `claude` CLI headlessly and turns its stream-json output into HUD events.
/// Every permission prompt is routed back to the operator through the PermissionServer / MCP shim.
struct ClaudeCodeProvider: AgentProvider {
    var mode: ApprovalMode = .ask

    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AsyncStream { c in
            let process = Process()
            let server = PermissionServer { tool, detail in
                await approve(ApprovalRequest(summary: "Allow \(tool)?", detail: detail))
            }
            let worker = Task {
                var arguments = ["claude", "-p", task,
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

                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
                process.environment = env
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
                if process.isRunning { process.terminate() }
                server.stop()
            }
        }
    }
}

enum ClaudeStream {
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
                            events.append(.code("// \(path)\n\(body)\n\n"))
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
