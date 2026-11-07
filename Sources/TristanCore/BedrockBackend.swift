import Foundation

package struct BedrockConfig {
    var model: String
    var region: String
    var profile: String

    package static let defaultModel = "us.anthropic.claude-sonnet-4-20250514-v1:0"

    static func load() -> BedrockConfig {
        func value(_ key: String) -> String { (Settings.string(key) ?? "").trimmingCharacters(in: .whitespaces) }
        return BedrockConfig(model: value("bedrock.model").isEmpty ? defaultModel : value("bedrock.model"),
                             region: value("bedrock.region").isEmpty ? "us-east-1" : value("bedrock.region"),
                             profile: value("bedrock.profile"))
    }
}

/// One model call. The real implementation shells out to the AWS CLI; tests use a scripted fake.
package protocol ConverseClient: Sendable {
    func converse(_ request: [String: Any]) async throws -> [String: Any]
    /// Streams text through `onText` when the client can; the result is always the complete response.
    func converseStreaming(_ request: [String: Any], onText: @escaping @Sendable (String) -> Void) async throws -> [String: Any]
}

package extension ConverseClient {
    func converseStreaming(_ request: [String: Any], onText: @escaping @Sendable (String) -> Void) async throws -> [String: Any] {
        try await converse(request)
    }
}

package struct BedrockError: LocalizedError {
    let message: String
    package var errorDescription: String? { message }
}

/// Translates the neutral transcript to and from Bedrock's Converse wire format.
package struct BedrockBackend: ChatBackend {
    let client: ConverseClient

    package func nextTurn(system: String, history: [ChatMessage], onText: @escaping @Sendable (String) -> Void) async throws -> ModelTurn {
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
package struct BedrockProvider: AgentProvider {
    var mode: ApprovalMode = .ask
    var client: ConverseClient
    var maxTurns = 25

    package func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AgentLoop(label: "Bedrock", mode: mode, backend: BedrockBackend(client: client), maxTurns: maxTurns)
            .run(task: task, workingDirectory: workingDirectory, approve: approve)
    }
}
