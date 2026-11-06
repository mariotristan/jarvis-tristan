import Foundation

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

extension BedrockProvider {
    /// Streams over HTTPS when possible and falls back to the AWS CLI (which also gives the clearest error messages).
    static func standard(mode: ApprovalMode) -> BedrockProvider {
        let config = BedrockConfig.load()
        let client = FallbackConverseClient(primary: BedrockStreamingClient(config: config, credentialProvider: AWSCLICredentials(profile: config.profile)),
                                            fallback: AWSCLIConverseClient(config: config))
        return BedrockProvider(mode: mode, client: client)
    }
}
