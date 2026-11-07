import Foundation

/// Calls `aws bedrock-runtime converse`, so credentials, SSO and profiles work exactly as in the user's terminal.
package struct AWSCLIConverseClient: ConverseClient {
    let config: BedrockConfig

    package func converse(_ request: [String: Any]) async throws -> [String: Any] {
        var body = request
        body["modelId"] = config.model
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-bedrock-\(UUID().uuidString.prefix(8))")
        try ProcessLauncher.createPrivateFolder(dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let requestFile = dir.appendingPathComponent("request.json")
        let outFile = dir.appendingPathComponent("out.json")
        let errFile = dir.appendingPathComponent("err.txt")
        try JSONSerialization.data(withJSONObject: body).write(to: requestFile)
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        FileManager.default.createFile(atPath: errFile.path, contents: nil)

        var arguments = ["bedrock-runtime", "converse",
                         "--cli-input-json", Self.inputArgument(for: ProcessLauncher.nativePath(requestFile), windows: ProcessLauncher.isWindows),
                         "--region", config.region, "--output", "json", "--cli-read-timeout", "300"]
        if !config.profile.isEmpty { arguments += ["--profile", config.profile] }
        let process: Process
        do {
            process = try ProcessLauncher.prepare("aws", arguments, directory: nil, extraEnvironment: [:])
        } catch is ToolNotFound {
            throw BedrockError(message: Self.notInstalled)
        } catch {
            throw BedrockError(message: "Could not launch the AWS CLI: \(error.localizedDescription)")
        }
        process.standardOutput = try FileHandle(forWritingTo: outFile)
        process.standardError = try FileHandle(forWritingTo: errFile)
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    if try !box.start(process) { continuation.resume(throwing: CancellationError()) }
                } catch {
                    continuation.resume(throwing: BedrockError(message: "Could not launch the AWS CLI: \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            box.terminate()
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

    /// The `--cli-input-json` value for the request file. The AWS CLI drops `file://` and opens the rest as a path, so
    /// a Windows path is given with forward slashes (`file://C:/Users/x/.../request.json`), the form AWS documents;
    /// a POSIX path keeps its leading slash (`file:///tmp/.../request.json`).
    static func inputArgument(for path: String, windows: Bool) -> String {
        "file://" + (windows ? path.replacingOccurrences(of: "\\", with: "/") : path)
    }

    static var notInstalled: String { notInstalledMessage(windows: ProcessLauncher.isWindows) }

    static func notInstalledMessage(windows: Bool) -> String {
        windows ? "The AWS CLI was not found. Install it with `winget install Amazon.AWSCLI`, then open a new terminal."
                : "The AWS CLI was not found. Install it with `brew install awscli`."
    }

    static func explain(stderr: String, windows: Bool = ProcessLauncher.isWindows) -> String {
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
        if lower.contains("command not found") || lower.contains("no such file") && lower.contains("aws")
            || lower.contains("is not recognized as an internal or external command") {   // cmd.exe's wording
            return notInstalledMessage(windows: windows)
        }
        return text.isEmpty ? "The AWS CLI failed with no message" : String(text.suffix(400))
    }
}

package extension BedrockProvider {
    /// Streams over HTTPS when possible and falls back to the AWS CLI (which also gives the clearest error messages).
    static func standard(mode: ApprovalMode) -> BedrockProvider {
        let config = BedrockConfig.load()
        let client = FallbackConverseClient(primary: BedrockStreamingClient(config: config, credentialProvider: AWSCLICredentials(profile: config.profile)),
                                            fallback: AWSCLIConverseClient(config: config))
        return BedrockProvider(mode: mode, client: client)
    }
}
