import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

package struct OllamaError: LocalizedError {
    let message: String
    package var errorDescription: String? { message }
}

package struct OllamaConfig {
    var host: String
    var model: String

    package static let defaultHost = "http://localhost:11434"
    /// Only this machine may be used, so a typo can never send a prompt to another computer.
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    static func load() -> OllamaConfig {
        func value(_ key: String) -> String { (Settings.string(key) ?? "").trimmingCharacters(in: .whitespaces) }
        return OllamaConfig(host: value("ollama.host").isEmpty ? defaultHost : value("ollama.host"), model: value("ollama.model"))
    }

    /// True when `host` is a URL that `baseURL` accepts: plain http on this machine.
    package static func isAllowedHost(_ host: String) -> Bool { (try? OllamaConfig(host: host, model: "").baseURL()) != nil }

    func baseURL() throws -> URL {
        guard let components = URLComponents(string: host), components.scheme == "http", components.user == nil,
              let name = components.host?.lowercased(), Self.loopbackHosts.contains(name),
              let url = components.url else {
            throw OllamaError(message: "Ollama must run on this Mac, for example \(Self.defaultHost). Nothing is sent to other machines.")
        }
        return url
    }

    func endpoint(_ path: String) throws -> URL {
        guard var components = URLComponents(url: try baseURL(), resolvingAgainstBaseURL: false) else {
            throw OllamaError(message: "Could not build the Ollama URL.")
        }
        components.path = path
        guard let url = components.url else { throw OllamaError(message: "Could not build the Ollama URL.") }
        return url
    }
}

package enum OllamaStatus {
    #if !canImport(Darwin)
    private static let statusSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        return URLSession(configuration: configuration)
    }()
    #endif

    /// The installed model names, or nil when the Ollama server cannot be reached.
    package static func installedModels(_ config: OllamaConfig = .load(), session: URLSession = .shared) async -> [String]? {
        guard let url = try? config.endpoint("/api/tags") else { return nil }
        #if !canImport(Darwin)
        // swift-corelibs-foundation does not apply a request's timeoutInterval (the session's 60 s default wins), so a
        // check against a port nothing listens on took a minute on Windows. The quick check gets its own session there.
        let session = session === URLSession.shared ? statusSession : session
        #endif
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// The model to use: the chosen one if it is installed (or none was chosen, the first installed), else nil.
    package static func resolveModel(chosen: String, installed: [String]) -> String? {
        if chosen.isEmpty { return installed.first }
        if installed.contains(chosen) { return chosen }
        return installed.first { $0.hasPrefix(chosen + ":") }
    }

    /// True when a local model is ready to answer. Kids mode asks this before every question.
    package static func ready(_ config: OllamaConfig = .load()) async -> Bool {
        guard let installed = await installedModels(config) else { return false }
        return resolveModel(chosen: config.model, installed: installed) != nil
    }
}

package struct OllamaHTTPClient: ChatCompletionsClient {
    let config: OllamaConfig
    var session: URLSession = .shared

    package func complete(_ body: [String: Any], onText: @escaping @Sendable (String) -> Void) async throws -> [String: Any] {
        guard let installed = await OllamaStatus.installedModels(config, session: session) else {
            throw OllamaError(message: "Ollama is not running. Start it with `ollama serve` (or open the Ollama app) and try again.")
        }
        guard let model = OllamaStatus.resolveModel(chosen: config.model, installed: installed) else {
            let wanted = config.model.isEmpty ? "a model" : "'\(config.model)'"
            throw OllamaError(message: "Ollama has no model installed for \(wanted). Run `ollama pull llama3.1` and try again.")
        }
        var payload = body
        payload["model"] = model
        payload["stream"] = true

        var request = URLRequest(url: try config.endpoint("/v1/chat/completions"), timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw OllamaError(message: "No response from Ollama") }
            guard http.statusCode == 200 else {
                var errorBody = Data()
                for try await byte in bytes { errorBody.append(byte); if errorBody.count > 4096 { break } }
                throw OllamaError(message: Self.explain(status: http.statusCode, body: errorBody, model: model))
            }
            var assembler = SSEAssembler()
            for try await line in bytes.lines {
                if let piece = assembler.feed(line: line) { onText(piece) }
            }
            return assembler.response
        } catch let error as OllamaError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OllamaError(message: "Could not reach Ollama: \(error.localizedDescription)")
        }
    }

    static func explain(status: Int, body: Data, model: String) -> String {
        let apiMessage = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String ?? $0["error"] as? String }
            ?? String(decoding: body.prefix(200), as: UTF8.self)
        if apiMessage.lowercased().contains("does not support tools") {
            return "The model '\(model)' cannot use tools. Pick one that can in Configuration, such as llama3.1 or qwen2.5-coder."
        }
        return "Ollama returned HTTP \(status). \(apiMessage)"
    }
}

/// Local agent: the shared agent loop on top of an Ollama model running on this Mac. Nothing leaves the machine.
package struct OllamaProvider: AgentProvider {
    var mode: ApprovalMode = .ask
    var client: ChatCompletionsClient = OllamaHTTPClient(config: .load())
    var maxTurns = 25

    package init(mode: ApprovalMode = .ask, client: ChatCompletionsClient = OllamaHTTPClient(config: .load()), maxTurns: Int = 25) {
        self.mode = mode
        self.client = client
        self.maxTurns = maxTurns
    }

    package func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AgentLoop(label: "Ollama (local)", mode: mode, backend: AzureBackend(client: client), maxTurns: maxTurns)
            .run(task: task, workingDirectory: workingDirectory, approve: approve)
    }
}
