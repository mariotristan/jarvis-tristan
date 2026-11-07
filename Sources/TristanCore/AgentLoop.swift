import Foundation

/// Provider-neutral transcript types. Each backend translates these to its own wire format.
package struct ToolCall: @unchecked Sendable {
    let id: String
    let name: String
    let input: [String: Any]
    var argumentError: String?
}

package struct ToolOutcome: Sendable {
    let id: String
    let text: String
    let isError: Bool
}

package enum ChatMessage: @unchecked Sendable {
    case user(String)
    case assistant(text: String, calls: [ToolCall])
    case toolResults([ToolOutcome])
}

package enum StopReason: Sendable { case toolUse, end, truncated, filtered }

package struct ModelTurn: @unchecked Sendable {
    var text: String
    var calls: [ToolCall]
    var stop: StopReason
    /// True when `text` was already delivered token by token through `onText`.
    var streamed = false
}

package protocol ChatBackend: Sendable {
    /// `onText` receives text as it arrives for backends that can stream; others may ignore it.
    func nextTurn(system: String, history: [ChatMessage], onText: @escaping @Sendable (String) -> Void) async throws -> ModelTurn
}

/// Counts streamed deltas so a backend can tell whether the text already reached the UI.
package final class StreamTally: @unchecked Sendable {
    private(set) var count = 0
    func note() { count += 1 }
}

/// The agent loop shared by every model-only provider: the model asks for tools, Tristan runs them
/// (asking the operator first, per approval mode) and feeds the results back until the model is done.
package struct AgentLoop {
    let label: String
    let mode: ApprovalMode
    let backend: ChatBackend
    var maxTurns = 25

    #if os(macOS)
    static let systemPrompt = """
    You are Tristan, a coding agent working in a single project folder on the user's Mac. \
    Use the tools to read, list and write files and to run shell commands. All paths are relative to the working folder. \
    Look before you change things, keep edits small, and run tests when they exist. \
    If a tool call is denied, do not try to work around the denial; explain what you could not do. \
    When finished, reply with a short summary of what you changed.
    """
    #else
    static let systemPrompt = """
    You are Tristan, a coding assistant working in a single folder on the user's iPhone or iPad. \
    Use the tools to read, list and write files. You cannot run commands or tests on this device, so say so if the task needs them. \
    All paths are relative to the working folder. Look before you change things and keep edits small. \
    If a tool call is denied, do not try to work around the denial; explain what you could not do. \
    When finished, reply with a short summary of what you changed.
    """
    #endif

    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AsyncStream { c in
            let worker = Task {
                let sandbox = ToolSandbox(root: workingDirectory)
                let policy = ToolPolicy(mode: mode)
                var history: [ChatMessage] = [.user(task)]
                c.yield(.log("\(label) agent, approval mode \(mode.rawValue)"))

                for turn in 0..<maxTurns {
                    if Task.isCancelled { c.finish(); return }
                    c.yield(.status(turn == 0 ? "THINKING" : "REASONING"))
                    let reply: ModelTurn
                    do {
                        reply = try await backend.nextTurn(system: Self.systemPrompt, history: history) { delta in
                            c.yield(.status("RESPONDING"))
                            c.yield(.code(delta))
                        }
                    } catch is CancellationError {
                        c.finish(); return
                    } catch {
                        c.yield(.failed(error.localizedDescription)); c.finish(); return
                    }

                    if reply.streamed {
                        c.yield(.code("\n"))
                    } else if !reply.text.isEmpty {
                        c.yield(.status("RESPONDING"))
                        c.yield(.code(reply.text + "\n"))
                    }
                    switch reply.stop {
                    case .truncated:
                        c.yield(.failed("The model's response was cut off (token limit)")); c.finish(); return
                    case .filtered:
                        c.yield(.failed("The response was blocked by the provider's content filter")); c.finish(); return
                    case .toolUse where !reply.calls.isEmpty:
                        var outcomes: [ToolOutcome] = []
                        for call in reply.calls {
                            outcomes.append(await execute(call, sandbox: sandbox, policy: policy, approve: approve, events: c))
                        }
                        history.append(.assistant(text: reply.text, calls: reply.calls))
                        history.append(.toolResults(outcomes))
                    default:
                        c.yield(.done(reply.text.isEmpty ? "Complete" : reply.text)); c.finish(); return
                    }
                }
                c.yield(.failed("Stopped after \(maxTurns) turns without finishing"))
                c.finish()
            }
            c.onTermination = { _ in worker.cancel() }
        }
    }

    private func execute(_ call: ToolCall, sandbox: ToolSandbox, policy: ToolPolicy, approve: Approver,
                         events c: AsyncStream<AgentEvent>.Continuation) async -> ToolOutcome {
        let input = call.input
        let denied = ToolCallResult(text: "The operator denied this action. Do not retry it; explain what you could not do.", isError: true)
        var result: ToolCallResult

        if let problem = call.argumentError {
            result = .init(text: "Could not parse the arguments for \(call.name): \(problem). Send valid JSON.", isError: true)
            return ToolOutcome(id: call.id, text: result.text, isError: true)
        }

        switch call.name {
        case "read_file":
            let path = input["path"] as? String ?? ""
            c.yield(.status("READING")); c.yield(.log("read_file \(path)"))
            result = sandbox.read(path)
        case "list_dir":
            let path = input["path"] as? String ?? "."
            c.yield(.status("SCANNING")); c.yield(.log("list_dir \(path)"))
            result = sandbox.list(path)
        case "write_file":
            let path = input["path"] as? String ?? ""
            let text = input["content"] as? String ?? ""
            if let url = sandbox.resolve(path) {
                let rule = ApprovalRule.make(tool: "Write", input: ["file_path": url.path], workingDirectory: sandbox.root)
                let allowed = policy.needsApproval(tool: call.name, rule: rule)
                    ? await approve(ApprovalRequest(summary: "Allow Write?", detail: "\(sandbox.relative(url)) (\(text.utf8.count) bytes)", rule: rule))
                    : true
                if allowed {
                    c.yield(.status("WRITING CODE")); c.yield(.log("write_file \(sandbox.relative(url))"))
                    c.yield(.code(CodeFence.block(path: sandbox.relative(url), content: text)))
                    result = sandbox.write(path, content: text)
                } else { result = denied }
            } else {
                result = sandbox.write(path, content: text)   // returns the "outside the folder" error
            }
        case "run_command":
            let command = input["command"] as? String ?? ""
            let rule = ApprovalRule.make(tool: ShellFlavor.current.ruleToolName, input: ["command": command], workingDirectory: sandbox.root)
            let allowed = policy.needsApproval(tool: call.name, rule: rule)
                ? await approve(ApprovalRequest(summary: "Allow Bash?", detail: command, rule: rule))
                : true
            #if !os(iOS)
            if allowed {
                c.yield(.status("EXECUTING")); c.yield(.log("run_command: \(command.prefix(60))"))
                result = await sandbox.run(command)
            } else { result = denied }
            #else
            _ = allowed
            result = .init(text: "Commands cannot be run on this device. Use the file tools only.", isError: true)
            #endif
        default:
            result = .init(text: "Unknown tool: \(call.name)", isError: true)
        }
        return ToolOutcome(id: call.id, text: result.text, isError: result.isError)
    }
}
