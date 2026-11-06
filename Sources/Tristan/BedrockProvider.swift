import Foundation

struct BedrockConfig {
    var model: String
    var region: String
    var profile: String

    static let defaultModel = "us.anthropic.claude-sonnet-4-20250514-v1:0"

    static func load() -> BedrockConfig {
        let defaults = UserDefaults.standard
        func value(_ key: String) -> String { (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespaces) }
        return BedrockConfig(model: value("bedrock.model").isEmpty ? defaultModel : value("bedrock.model"),
                             region: value("bedrock.region").isEmpty ? "us-east-1" : value("bedrock.region"),
                             profile: value("bedrock.profile"))
    }
}

/// One model call. The real implementation shells out to the AWS CLI; tests use a scripted fake.
protocol ConverseClient: Sendable {
    func converse(_ request: [String: Any]) async throws -> [String: Any]
}

struct BedrockError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Calls `aws bedrock-runtime converse`, so credentials, SSO and profiles work exactly as in the user's terminal.
struct AWSCLIConverseClient: ConverseClient {
    let config: BedrockConfig

    func converse(_ request: [String: Any]) async throws -> [String: Any] {
        var body = request
        body["modelId"] = config.model
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-bedrock-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let requestFile = dir.appendingPathComponent("request.json")
        let outFile = dir.appendingPathComponent("out.json")
        let errFile = dir.appendingPathComponent("err.txt")
        try JSONSerialization.data(withJSONObject: body).write(to: requestFile)
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        FileManager.default.createFile(atPath: errFile.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var arguments = ["aws", "bedrock-runtime", "converse", "--cli-input-json", "file://\(requestFile.path)",
                         "--region", config.region, "--output", "json", "--cli-read-timeout", "300"]
        if !config.profile.isEmpty { arguments += ["--profile", config.profile] }
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        process.standardOutput = try FileHandle(forWritingTo: outFile)
        process.standardError = try FileHandle(forWritingTo: errFile)
        process.standardInput = FileHandle.nullDevice

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { continuation.resume(throwing: BedrockError(message: "Could not launch the AWS CLI: \(error.localizedDescription)")) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        try Task.checkCancellation()
        guard status == 0 else {
            let stderr = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""
            throw BedrockError(message: Self.explain(stderr: stderr))
        }
        let data = try Data(contentsOf: outFile)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BedrockError(message: "Bedrock returned something that is not JSON")
        }
        return object
    }

    static func explain(stderr: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("expiredtoken") || lower.contains("security token") || lower.contains("unable to locate credentials")
            || lower.contains("sso") && lower.contains("expired") {
            return "AWS credentials are missing or expired. Log in again (for example `aws sso login` or your organisation's login), then retry."
        }
        if lower.contains("accessdenied") || lower.contains("not authorized") {
            return "AWS denied access to this model. Check that model access is enabled in Bedrock and your role may call it. \(text.suffix(200))"
        }
        if lower.contains("validationexception") && lower.contains("model") {
            return "Bedrock rejected the model id. Set a valid one in Configuration (see `aws bedrock list-inference-profiles`). \(text.suffix(200))"
        }
        if lower.contains("command not found") || lower.contains("no such file") && lower.contains("aws") {
            return "The AWS CLI was not found. Install it with `brew install awscli`."
        }
        return text.isEmpty ? "The AWS CLI failed with no message" : String(text.suffix(400))
    }
}

/// A small agent loop on top of Bedrock's Converse API: the model asks for tools, Tristan runs them
/// (asking the operator first, per approval mode) and feeds the results back until the model is done.
struct BedrockProvider: AgentProvider {
    var mode: ApprovalMode = .ask
    var client: ConverseClient = AWSCLIConverseClient(config: .load())
    var maxTurns = 25

    private let systemPrompt = """
    You are Tristan, a coding agent working in a single project folder on the user's Mac. \
    Use the tools to read, list and write files and to run shell commands. All paths are relative to the working folder. \
    Look before you change things, keep edits small, and run tests when they exist. \
    If a tool call is denied, do not try to work around the denial; explain what you could not do. \
    When finished, reply with a short summary of what you changed.
    """

    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AsyncStream { c in
            let worker = Task {
                let sandbox = ToolSandbox(root: workingDirectory)
                let policy = ToolPolicy(mode: mode)
                var messages: [[String: Any]] = [["role": "user", "content": [["text": task]]]]
                c.yield(.log("Bedrock agent, approval mode \(mode.rawValue)"))

                for turn in 0..<maxTurns {
                    if Task.isCancelled { c.finish(); return }
                    c.yield(.status(turn == 0 ? "THINKING" : "REASONING"))
                    let request: [String: Any] = [
                        "messages": messages,
                        "system": [["text": systemPrompt]],
                        "toolConfig": ["tools": AgentToolSpec.converseTools],
                        "inferenceConfig": ["maxTokens": 4096],
                    ]
                    let response: [String: Any]
                    do { response = try await client.converse(request) } catch is CancellationError {
                        c.finish(); return
                    } catch {
                        c.yield(.failed(error.localizedDescription)); c.finish(); return
                    }
                    guard let message = (response["output"] as? [String: Any])?["message"] as? [String: Any],
                          let content = message["content"] as? [[String: Any]] else {
                        c.yield(.failed("Unexpected response from Bedrock")); c.finish(); return
                    }
                    messages.append(message)

                    var finalText = ""
                    var results: [[String: Any]] = []
                    for block in content {
                        if let text = block["text"] as? String {
                            finalText += text
                            c.yield(.status("RESPONDING"))
                            c.yield(.code(text + "\n"))
                        }
                        if let use = block["toolUse"] as? [String: Any] {
                            results.append(await execute(use, sandbox: sandbox, policy: policy, approve: approve, events: c))
                        }
                    }
                    if (response["stopReason"] as? String) == "tool_use", !results.isEmpty {
                        messages.append(["role": "user", "content": results])
                        continue
                    }
                    c.yield(.done(finalText.isEmpty ? "Complete" : finalText))
                    c.finish(); return
                }
                c.yield(.failed("Stopped after \(maxTurns) turns without finishing"))
                c.finish()
            }
            c.onTermination = { _ in worker.cancel() }
        }
    }

    private func execute(_ use: [String: Any], sandbox: ToolSandbox, policy: ToolPolicy, approve: Approver,
                         events c: AsyncStream<AgentEvent>.Continuation) async -> [String: Any] {
        let id = use["toolUseId"] as? String ?? ""
        let name = use["name"] as? String ?? ""
        let input = use["input"] as? [String: Any] ?? [:]
        let denied = ToolCallResult(text: "The operator denied this action. Do not retry it; explain what you could not do.", isError: true)
        var result: ToolCallResult

        switch name {
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
                let allowed = policy.needsApproval(tool: name, rule: rule)
                    ? await approve(ApprovalRequest(summary: "Allow Write?", detail: "\(sandbox.relative(url)) (\(text.utf8.count) bytes)", rule: rule))
                    : true
                if allowed {
                    c.yield(.status("WRITING CODE")); c.yield(.log("write_file \(sandbox.relative(url))"))
                    c.yield(.code("// \(sandbox.relative(url))\n\(text)\n\n"))
                    result = sandbox.write(path, content: text)
                } else { result = denied }
            } else {
                result = sandbox.write(path, content: text)   // returns the "outside the folder" error
            }
        case "run_command":
            let command = input["command"] as? String ?? ""
            let rule = ApprovalRule.make(tool: "Bash", input: ["command": command], workingDirectory: sandbox.root)
            let allowed = policy.needsApproval(tool: name, rule: rule)
                ? await approve(ApprovalRequest(summary: "Allow Bash?", detail: command, rule: rule))
                : true
            if allowed {
                c.yield(.status("EXECUTING")); c.yield(.log("run_command: \(command.prefix(60))"))
                result = await sandbox.run(command)
            } else { result = denied }
        default:
            result = .init(text: "Unknown tool: \(name)", isError: true)
        }
        return ["toolResult": ["toolUseId": id, "content": [["text": result.text]], "status": result.isError ? "error" : "success"]]
    }
}
