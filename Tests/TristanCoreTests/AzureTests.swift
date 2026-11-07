import XCTest
@testable import TristanCore

final class ScriptedChat: ChatCompletionsClient, @unchecked Sendable {
    private var responses: [[String: Any]]
    private(set) var bodies: [[String: Any]] = []
    var streamPieces: [String] = []
    init(_ responses: [[String: Any]]) { self.responses = responses }

    func complete(_ body: [String: Any], onText: @escaping @Sendable (String) -> Void) async throws -> [String: Any] {
        bodies.append(body)
        guard !responses.isEmpty else { throw AzureError(message: "script exhausted") }
        streamPieces.forEach(onText)
        return responses.removeFirst()
    }

    static func reply(text: String? = nil, calls: [(id: String, name: String, args: String)] = [], finish: String? = nil) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": text ?? NSNull()]
        if !calls.isEmpty {
            message["tool_calls"] = calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.args]] }
        }
        return ["choices": [["message": message, "finish_reason": finish ?? (calls.isEmpty ? "stop" : "tool_calls")]]]
    }
}

final class AzureTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-azure-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func run(_ client: ScriptedChat, mode: ApprovalMode = .ask, allow: Bool = true) async -> (events: [AgentEvent], prompts: [ApprovalRequest]) {
        let prompts = PromptLog()
        let stream = AzureOpenAIProvider(mode: mode, client: client).run(task: "do it", workingDirectory: folder) { request in
            await prompts.add(request); return allow
        }
        var events: [AgentEvent] = []
        for await event in stream { events.append(event) }
        return (events, await prompts.all)
    }

    private func last(_ events: [AgentEvent]) -> String {
        for event in events.reversed() {
            if case .done = event { return "done" }
            if case .failed(let message) = event { return "failed: \(message)" }
        }
        return "none"
    }

    // MARK: agent loop over the OpenAI wire format

    func testToolCallRoundTripUsesOpenAIFormat() async throws {
        let client = ScriptedChat([ScriptedChat.reply(calls: [("call_1", "write_file", #"{"path":"a.txt","content":"hi"}"#)]),
                                   ScriptedChat.reply(text: "All done.")])
        let (events, prompts) = await run(client)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8), "hi")
        XCTAssertEqual(last(events), "done")

        let first = client.bodies[0]
        XCTAssertEqual(((first["messages"] as? [[String: Any]])?.first)?["role"] as? String, "system")
        XCTAssertEqual((first["tools"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual(((first["tools"] as? [[String: Any]])?.first)?["type"] as? String, "function")

        let second = try XCTUnwrap(client.bodies[1]["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(second.first { $0["role"] as? String == "assistant" })
        let call = try XCTUnwrap((assistant["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertEqual(call["id"] as? String, "call_1")
        XCTAssertTrue(((call["function"] as? [String: Any])?["arguments"] as? String)?.contains("a.txt") == true, "arguments must be a JSON string")
        let tool = try XCTUnwrap(second.first { $0["role"] as? String == "tool" })
        XCTAssertEqual(tool["tool_call_id"] as? String, "call_1")
    }

    func testDeniedActionReachesTheModelAndDoesNotTouchDisk() async throws {
        let client = ScriptedChat([ScriptedChat.reply(calls: [("c", "run_command", #"{"command":"touch x.txt"}"#)]),
                                   ScriptedChat.reply(text: "Could not.")])
        let (events, prompts) = await run(client, allow: false)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("x.txt").path))
        XCTAssertEqual(last(events), "done")
        XCTAssertTrue(String(describing: client.bodies[1]["messages"] ?? "").contains("denied"))
    }

    func testMalformedArgumentsAreReportedBackNotExecuted() async throws {
        let client = ScriptedChat([ScriptedChat.reply(calls: [("c", "write_file", "{not json")]), ScriptedChat.reply(text: "Sorry.")])
        let (events, prompts) = await run(client, mode: .yolo)
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertEqual(last(events), "done")
        XCTAssertTrue(String(describing: client.bodies[1]["messages"] ?? "").contains("valid JSON"))
    }

    func testFinishReasonsMapToFailures() async {
        let cut = await run(ScriptedChat([ScriptedChat.reply(text: "partial", finish: "length")]))
        XCTAssertTrue(last(cut.events).contains("cut off"))
        let filtered = await run(ScriptedChat([ScriptedChat.reply(text: nil, finish: "content_filter")]))
        XCTAssertTrue(last(filtered.events).contains("content filter"))
    }

    func testStreamedTextIsNotDuplicated() async {
        let client = ScriptedChat([ScriptedChat.reply(text: "Hello there")])
        client.streamPieces = ["Hello", " there"]
        let (events, _) = await run(client)
        let code = events.compactMap { event -> String? in if case .code(let text) = event { return text } else { return nil } }.joined()
        XCTAssertEqual(code, "Hello there\n")
    }

    // MARK: SSE assembly

    func testSSEAssemblesTextAndToolCalls() throws {
        var assembler = SSEAssembler()
        let lines = [
            #"data: {"choices":[]}"#,   // content-filter prelude chunk with no choices
            #"data: {"choices":[{"delta":{"role":"assistant","content":"Let me "},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"content":"write it."},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_9","function":{"name":"write_file","arguments":"{\"path\":"}}]},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"a.txt\",\"content\":\"x\"}"}}]},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
        ]
        let pieces = lines.compactMap { assembler.feed(line: $0) }
        XCTAssertEqual(pieces, ["Let me ", "write it."])
        let choice = try XCTUnwrap((assembler.response["choices"] as? [[String: Any]])?.first)
        XCTAssertEqual(choice["finish_reason"] as? String, "tool_calls")
        let call = try XCTUnwrap(((choice["message"] as? [String: Any])?["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertEqual(call["id"] as? String, "call_9")
        let arguments = try XCTUnwrap((call["function"] as? [String: Any])?["arguments"] as? String)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["path"] as? String, "a.txt")
    }

    // MARK: config safety and errors

    func testEndpointValidationProtectsTheKey() throws {
        func url(_ endpoint: String, deployment: String = "gpt4o") throws -> URL {
            try AzureConfig(endpoint: endpoint, deployment: deployment, apiVersion: "2024-10-21").requestURL()
        }
        let good = try url("https://my-res.openai.azure.com")
        XCTAssertEqual(good.path, "/openai/deployments/gpt4o/chat/completions")
        XCTAssertTrue(good.absoluteString.contains("api-version=2024-10-21"))
        XCTAssertNoThrow(try url("https://my-res.cognitiveservices.azure.com/"))
        XCTAssertThrowsError(try url("http://my-res.openai.azure.com"), "plain http must be refused")
        XCTAssertThrowsError(try url("https://evil.com"))
        XCTAssertThrowsError(try url("https://my-res.openai.azure.com.evil.com"))
        XCTAssertThrowsError(try url("https://user:pw@my-res.openai.azure.com"))
        XCTAssertThrowsError(try url("https://my-res.openai.azure.com", deployment: "../admin"))
        XCTAssertThrowsError(try url("https://my-res.openai.azure.com", deployment: ""))
        XCTAssertThrowsError(try url(""))
    }

    func testHTTPErrorsAreExplained() {
        let body = Data(#"{"error":{"message":"The API deployment for this resource does not exist."}}"#.utf8)
        XCTAssertTrue(AzureHTTPClient.explain(status: 404, body: body).contains("deployment"))
        XCTAssertTrue(AzureHTTPClient.explain(status: 401, body: body).contains("credentials"))
        XCTAssertTrue(AzureHTTPClient.explain(status: 429, body: body).contains("rate"))
        XCTAssertTrue(AzureHTTPClient.explain(status: 500, body: Data()).contains("500"))
    }
}
