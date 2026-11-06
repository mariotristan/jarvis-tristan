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
    /// Streams text through `onText` when the client can; the result is always the complete response.
    func converseStreaming(_ request: [String: Any], onText: @escaping @Sendable (String) -> Void) async throws -> [String: Any]
}

extension ConverseClient {
    func converseStreaming(_ request: [String: Any], onText: @escaping @Sendable (String) -> Void) async throws -> [String: Any] {
        try await converse(request)
    }
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

/// Translates the neutral transcript to and from Bedrock's Converse wire format.
struct BedrockBackend: ChatBackend {
    let client: ConverseClient

    func nextTurn(system: String, history: [ChatMessage], onText: @escaping @Sendable (String) -> Void) async throws -> ModelTurn {
        let request: [String: Any] = [
            "messages": history.map(Self.wire),
            "system": [["text": system]],
            "toolConfig": ["tools": AgentToolSpec.converseTools],
            "inferenceConfig": ["maxTokens": 4096],
        ]
        let tally = StreamTally()
        let response = try await client.converseStreaming(request) { delta in tally.note(); onText(delta) }
        guard let message = (response["output"] as? [String: Any])?["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            throw BedrockError(message: "Unexpected response from Bedrock")
        }
        var text = ""
        var calls: [ToolCall] = []
        for block in content {
            if let t = block["text"] as? String { text += t }
            if let use = block["toolUse"] as? [String: Any] {
                calls.append(ToolCall(id: use["toolUseId"] as? String ?? "", name: use["name"] as? String ?? "",
                                      input: use["input"] as? [String: Any] ?? [:]))
            }
        }
        let stop: StopReason
        switch response["stopReason"] as? String {
        case "tool_use": stop = .toolUse
        case "max_tokens": stop = .truncated
        case "content_filtered", "guardrail_intervened": stop = .filtered
        default: stop = .end
        }
        return ModelTurn(text: text, calls: calls, stop: stop, streamed: tally.count > 0)
    }

    static func wire(_ message: ChatMessage) -> [String: Any] {
        switch message {
        case .user(let text):
            return ["role": "user", "content": [["text": text]]]
        case .assistant(let text, let calls):
            var content: [[String: Any]] = text.isEmpty ? [] : [["text": text]]
            content += calls.map { ["toolUse": ["toolUseId": $0.id, "name": $0.name, "input": $0.input]] }
            return ["role": "assistant", "content": content]
        case .toolResults(let outcomes):
            return ["role": "user", "content": outcomes.map {
                ["toolResult": ["toolUseId": $0.id, "content": [["text": $0.text]], "status": $0.isError ? "error" : "success"]]
            }]
        }
    }
}

/// Bedrock agent: the shared agent loop on top of Bedrock's Converse API.
struct BedrockProvider: AgentProvider {
    var mode: ApprovalMode = .ask
    /// Streams over HTTPS when possible and falls back to the AWS CLI (which also gives the clearest error messages).
    var client: ConverseClient = {
        let config = BedrockConfig.load()
        return FallbackConverseClient(primary: BedrockStreamingClient(config: config, credentialProvider: AWSCLICredentials(profile: config.profile)),
                                      fallback: AWSCLIConverseClient(config: config))
    }()
    var maxTurns = 25

    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AgentLoop(label: "Bedrock", mode: mode, backend: BedrockBackend(client: client), maxTurns: maxTurns)
            .run(task: task, workingDirectory: workingDirectory, approve: approve)
    }
}
