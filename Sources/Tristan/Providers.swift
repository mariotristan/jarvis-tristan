import Foundation

enum ProviderKind: String, CaseIterable, Identifiable {
    case claude = "CLAUDE"
    case copilot = "COPILOT"
    case bedrock = "BEDROCK"
    case azure = "AZURE"
    case ollama = "OLLAMA"
    case demo = "DEMO"

    var id: String { rawValue }

    func makeProvider(mode: ApprovalMode) -> AgentProvider? {
        switch self {
        case .claude: return ClaudeCodeProvider(mode: mode)
        case .bedrock: return BedrockProvider.standard(mode: mode)
        case .demo: return DemoProvider(skipApproval: mode == .yolo)
        case .azure: return AzureOpenAIProvider(mode: mode)
        case .copilot: return CopilotProvider(mode: mode)
        case .ollama: return OllamaProvider(mode: mode)
        }
    }
}

/// Scripted provider so the HUD can be played with without spending tokens.
/// Scripted answers for the recorded demo (`Tristan --demo --kids`), matched by a few words in the question.
enum DemoAnswers {
    /// The prompt may carry the session's memory briefing in front; the question itself follows "Current task:".
    static func question(in prompt: String) -> String {
        guard let marker = prompt.range(of: "Current task:", options: .backwards) else { return prompt }
        return prompt[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func answer(for task: String) -> String? {
        let q = task.lowercased()
        if q.contains("times") || q.contains("7 x 8") {
            return "## 7 × 8 = 56\n\nHere is a trick: **5, 6, 7, 8**.\n\n- Say it in order: *five, six, seven, eight*\n- That gives you **56 = 7 × 8**\n\nTry **7 × 9** next. What do you think it is?\n"
        }
        if q.contains("sky") {
            return "## Why is the sky blue?\n\nSunlight looks white, but it is made of **all the colors** of the rainbow.\n\n- Light bumps into the tiny bits of air\n- **Blue** light bounces around the most\n- So blue comes at your eyes from every part of the sky\n\nAt sunset the light travels farther, so we see **red and orange** instead.\n"
        }
        if q.contains("planet") {
            return "## The biggest planet is **Jupiter**\n\n- It is so big that **1,300 Earths** could fit inside it\n- It has a giant storm called the **Great Red Spot**\n- It has at least **95 moons**\n\n> Fun fact: a day on Jupiter is only about 10 hours long!\n"
        }
        if q.contains("spider") || q.contains("insect") {
            return "## Is a spider an insect?\n\n**No!** A spider is an *arachnid*.\n\n| | Insect | Spider |\n|:--|:--:|:--:|\n| Legs | 6 | 8 |\n| Body parts | 3 | 2 |\n| Antennae | yes | no |\n\nCount the legs and you can always tell.\n"
        }
        return nil
    }
}

struct DemoProvider: AgentProvider {
    /// YOLO skips every permission check, the demo's one prompt included.
    var skipApproval = false

    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AsyncStream { c in
            let worker = Task {
                func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
                // School-style questions get a scripted, friendly answer and need no approval.
                let question = DemoAnswers.question(in: task)
                if let answer = DemoAnswers.answer(for: question) {
                    c.yield(.status("THINKING"))
                    c.yield(.log("Question received: \(question)"))
                    await pause(2200)
                    c.yield(.status("ANSWERING"))
                    for ch in answer {
                        if Task.isCancelled { c.finish(); return }
                        c.yield(.code(String(ch)))
                        await pause(16)
                    }
                    await pause(800)
                    c.yield(.done("Answered"))
                    c.finish()
                    return
                }
                c.yield(.status("PLANNING"))
                c.yield(.log("Task received: \(question)"))
                await pause(900)
                guard !Task.isCancelled else { c.finish(); return }
                c.yield(.log("Scanning \(workingDirectory.lastPathComponent)"))
                await pause(900)
                guard !Task.isCancelled else { c.finish(); return }
                c.yield(.status("AWAITING AUTHORIZATION"))
                let ok = skipApproval ? true : await approve(ApprovalRequest(summary: "Write Sources/auth.ts", detail: "Create a new file in \(workingDirectory.path)"))
                guard ok else { c.yield(.failed("Denied by operator")); c.finish(); return }
                c.yield(.status("WRITING CODE"))
                c.yield(.log("Writing Sources/auth.ts"))
                let intro = "## Adding login\n\nI'll create **Sources/auth.ts** with a `login` function:\n"
                let snippet = intro + CodeFence.block(path: "Sources/auth.ts", content: """
                import { sign } from "./jwt";

                export function login(user: User): string {
                  const token = sign({ sub: user.id, role: user.role });
                  audit("login", user.id);
                  return token;
                }
                """)
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
            let server = PermissionServer(workingDirectory: workingDirectory) { tool, detail, rule in
                await approve(ApprovalRequest(summary: "Allow \(tool)?", detail: detail, rule: rule))
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
