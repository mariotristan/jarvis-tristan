import Foundation

package struct AzureError: LocalizedError {
    let message: String
    package var errorDescription: String? { message }
}

package struct AzureConfig {
    var endpoint: String
    var deployment: String
    var apiVersion: String

    package static let defaultAPIVersion = "2024-10-21"
    package static let keychainAccount = "azure-openai-key"
    /// Hosts the API key may be sent to. Anything else is refused so a typo cannot leak the key.
    static let allowedHostSuffixes = ["openai.azure.com", "cognitiveservices.azure.com", "services.ai.azure.com",
                                      "openai.azure.us", "openai.azure.cn"]

    static func load() -> AzureConfig {
        let defaults = UserDefaults.standard
        func value(_ key: String) -> String { (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespaces) }
        return AzureConfig(endpoint: value("azure.endpoint"), deployment: value("azure.deployment"),
                           apiVersion: value("azure.apiVersion").isEmpty ? defaultAPIVersion : value("azure.apiVersion"))
    }

    func requestURL() throws -> URL {
        let text = endpoint.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw AzureError(message: "Set the Azure OpenAI endpoint in Configuration (for example https://my-resource.openai.azure.com).") }
        guard var components = URLComponents(string: text), components.scheme == "https", components.user == nil,
              let host = components.host?.lowercased(),
              Self.allowedHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            throw AzureError(message: "The endpoint must be an https Azure OpenAI URL, like https://my-resource.openai.azure.com.")
        }
        let name = deployment.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw AzureError(message: "Set the Azure OpenAI deployment name in Configuration.") }
        guard name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw AzureError(message: "The deployment name may only contain letters, digits, dots, dashes and underscores.")
        }
        components.path = "/openai/deployments/\(name)/chat/completions"
        components.queryItems = [URLQueryItem(name: "api-version", value: apiVersion)]
        guard let url = components.url else { throw AzureError(message: "Could not build the Azure OpenAI URL.") }
        return url
    }
}

/// One chat-completions call. The real client streams over HTTPS; tests use a scripted fake.
/// Streamed text is delivered through `onText`; the return value is always the assembled non-streaming shape.
package protocol ChatCompletionsClient: Sendable {
    func complete(_ body: [String: Any], onText: @escaping @Sendable (String) -> Void) async throws -> [String: Any]
}

/// Chooses between an API key (from the Keychain) and the Azure CLI login (Entra ID).
package final class AzureAuth: @unchecked Sendable {
    private var cachedToken: (value: String, expires: Date)?

    func headers() async throws -> [String: String] {
        if let key = KeychainStore.get(AzureConfig.keychainAccount), !key.isEmpty { return ["api-key": key] }
        #if os(macOS)
        if let cached = cachedToken, cached.expires > Date() { return ["Authorization": "Bearer \(cached.value)"] }
        let token = try await Self.azureCLIToken()
        cachedToken = (token, Date().addingTimeInterval(20 * 60))
        return ["Authorization": "Bearer \(token)"]
        #else
        throw AzureError(message: "No Azure OpenAI API key is set. Add one in Settings.")
        #endif
    }

    #if os(macOS)
    private static func azureCLIToken() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["az", "account", "get-access-token", "--resource", "https://cognitiveservices.azure.com",
                                     "--query", "accessToken", "-o", "tsv"]
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
                process.environment = env
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(throwing: AzureError(message: "No API key is set and the Azure CLI was not found. Add an API key in Configuration or install it with `brew install azure-cli`."))
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0, !token.isEmpty {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: AzureError(message: "No API key is set and the Azure CLI is not logged in. Run `az login`, or add an API key in Configuration."))
                }
            }
        }
    }
    #endif
}


/// Server-sent-events assembler for streamed chat completions. Pure, so it is easy to test.
package struct SSEAssembler {
    private(set) var text = ""
    private var finish: String?
    private var calls: [Int: (id: String, name: String, arguments: String)] = [:]

    /// Feeds one line of the event stream. Returns any new text to show.
    mutating func feed(line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
              let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (chunk["choices"] as? [[String: Any]])?.first else { return nil }   // some chunks have no choices
        if let reason = choice["finish_reason"] as? String { finish = reason }
        guard let delta = choice["delta"] as? [String: Any] else { return nil }
        for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
            let index = call["index"] as? Int ?? 0
            var entry = calls[index] ?? ("", "", "")
            if let id = call["id"] as? String { entry.id = id }
            if let function = call["function"] as? [String: Any] {
                if let name = function["name"] as? String { entry.name += name }
                if let arguments = function["arguments"] as? String { entry.arguments += arguments }
            }
            calls[index] = entry
        }
        if let piece = delta["content"] as? String, !piece.isEmpty {
            text += piece
            return piece
        }
        return nil
    }

    /// The assembled result, in the same shape as a non-streaming response.
    var response: [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": text.isEmpty ? NSNull() : text]
        if !calls.isEmpty {
            message["tool_calls"] = calls.keys.sorted().map { key -> [String: Any] in
                let call = calls[key]!
                return ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments]]
            }
        }
        return ["choices": [["message": message, "finish_reason": finish ?? (calls.isEmpty ? "stop" : "tool_calls")]]]
    }
}

package struct AzureHTTPClient: ChatCompletionsClient {
    let config: AzureConfig
    let auth = AzureAuth()
    var session: URLSession = .shared

    package func complete(_ body: [String: Any], onText: @escaping @Sendable (String) -> Void) async throws -> [String: Any] {
        let url = try config.requestURL()
        var payload = body
        payload["stream"] = true
        var lastError: Error = AzureError(message: "Azure OpenAI request failed")

        for attempt in 0..<3 {
            try Task.checkCancellation()
            var request = URLRequest(url: url, timeoutInterval: 300)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (name, value) in try await auth.headers() { request.setValue(value, forHTTPHeaderField: name) }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw AzureError(message: "No response from Azure OpenAI") }
                guard http.statusCode == 200 else {
                    var errorBody = Data()
                    for try await byte in bytes { errorBody.append(byte); if errorBody.count > 4096 { break } }
                    let retryAfter = Double(http.value(forHTTPHeaderField: "retry-after") ?? "")
                    let error = AzureError(message: Self.explain(status: http.statusCode, body: errorBody))
                    if [429, 500, 502, 503].contains(http.statusCode), attempt < 2 {
                        lastError = error
                        try await Task.sleep(for: .seconds(min(retryAfter ?? Double(2 << attempt), 30)))
                        continue
                    }
                    throw error
                }
                var assembler = SSEAssembler()
                for try await line in bytes.lines {
                    if let piece = assembler.feed(line: line) { onText(piece) }
                }
                return assembler.response
            } catch let error as AzureError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AzureError(message: "Could not reach Azure OpenAI: \(error.localizedDescription)")
            }
        }
        throw lastError
    }

    static func explain(status: Int, body: Data) -> String {
        let apiMessage = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? String(decoding: body.prefix(200), as: UTF8.self)
        switch status {
        case 401: return "Azure rejected the credentials. Check the API key in Configuration, or run `az login` if you rely on the Azure CLI. \(apiMessage)"
        case 403: return "Azure denied access. The key or your Entra role may lack permission for this resource. \(apiMessage)"
        case 404: return "Azure could not find that deployment. Check the endpoint and deployment name in Configuration. \(apiMessage)"
        case 429: return "Azure OpenAI is rate limiting this deployment. Try again shortly. \(apiMessage)"
        case 400 where apiMessage.lowercased().contains("content_filter") || apiMessage.lowercased().contains("content management"):
            return "Azure's content filter blocked the request. \(apiMessage)"
        default: return "Azure OpenAI returned HTTP \(status). \(apiMessage)"
        }
    }
}

/// Translates the neutral transcript to and from the OpenAI / Azure OpenAI chat-completions format.
package struct AzureBackend: ChatBackend {
    let client: ChatCompletionsClient

    package func nextTurn(system: String, history: [ChatMessage], onText: @escaping @Sendable (String) -> Void) async throws -> ModelTurn {
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        messages += history.flatMap(Self.wire)
        let body: [String: Any] = ["messages": messages, "tools": AgentToolSpec.openAITools]
        let tally = StreamTally()
        let response = try await client.complete(body) { delta in tally.note(); onText(delta) }

        guard let choice = (response["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw AzureError(message: "Unexpected response from Azure OpenAI")
        }
        let text = message["content"] as? String ?? ""
        var calls: [ToolCall] = []
        for raw in message["tool_calls"] as? [[String: Any]] ?? [] {
            let function = raw["function"] as? [String: Any] ?? [:]
            let arguments = function["arguments"] as? String ?? ""
            var input: [String: Any] = [:]
            var problem: String?
            if !arguments.trimmingCharacters(in: .whitespaces).isEmpty {
                if let data = arguments.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    input = object
                } else {
                    problem = "the arguments were not a valid JSON object"
                }
            }
            calls.append(ToolCall(id: raw["id"] as? String ?? "", name: function["name"] as? String ?? "", input: input, argumentError: problem))
        }
        let stop: StopReason
        switch choice["finish_reason"] as? String {
        case "length": stop = .truncated
        case "content_filter": stop = .filtered
        default: stop = calls.isEmpty ? .end : .toolUse
        }
        return ModelTurn(text: text, calls: calls, stop: stop, streamed: tally.count > 0)
    }

    static func wire(_ message: ChatMessage) -> [[String: Any]] {
        switch message {
        case .user(let text):
            return [["role": "user", "content": text]]
        case .assistant(let text, let calls):
            var entry: [String: Any] = ["role": "assistant", "content": text.isEmpty ? NSNull() : text]
            if !calls.isEmpty {
                entry["tool_calls"] = calls.map { call -> [String: Any] in
                    let data = (try? JSONSerialization.data(withJSONObject: call.input)) ?? Data("{}".utf8)
                    return ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": String(decoding: data, as: UTF8.self)]]
                }
            }
            return [entry]
        case .toolResults(let outcomes):
            return outcomes.map { ["role": "tool", "tool_call_id": $0.id, "content": $0.isError ? "ERROR: \($0.text)" : $0.text] }
        }
    }
}

/// Azure OpenAI agent: the shared agent loop on top of an Azure OpenAI chat-completions deployment.
package struct AzureOpenAIProvider: AgentProvider {
    var mode: ApprovalMode = .ask
    var client: ChatCompletionsClient = AzureHTTPClient(config: .load())
    var maxTurns = 25

    package init(mode: ApprovalMode = .ask, client: ChatCompletionsClient = AzureHTTPClient(config: .load()), maxTurns: Int = 25) {
        self.mode = mode
        self.client = client
        self.maxTurns = maxTurns
    }

    package func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AgentLoop(label: "Azure OpenAI", mode: mode, backend: AzureBackend(client: client), maxTurns: maxTurns)
            .run(task: task, workingDirectory: workingDirectory, approve: approve)
    }
}
