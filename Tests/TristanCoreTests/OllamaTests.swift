import XCTest
@testable import TristanCore

final class OllamaConfigTests: XCTestCase {
    func testOnlyThisMacIsAllowed() throws {
        XCTAssertNoThrow(try OllamaConfig(host: "http://localhost:11434", model: "").baseURL())
        XCTAssertNoThrow(try OllamaConfig(host: "http://127.0.0.1:11434", model: "").baseURL())
        XCTAssertThrowsError(try OllamaConfig(host: "http://192.168.1.20:11434", model: "").baseURL())
        XCTAssertThrowsError(try OllamaConfig(host: "https://example.com", model: "").baseURL())
        XCTAssertThrowsError(try OllamaConfig(host: "http://localhost.evil.com", model: "").baseURL())
    }

    func testEndpointPath() throws {
        let url = try OllamaConfig(host: "http://localhost:11434", model: "").endpoint("/v1/chat/completions")
        XCTAssertEqual(url.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func testModelResolution() {
        XCTAssertEqual(OllamaStatus.resolveModel(chosen: "", installed: ["llama3.1:8b", "qwen:7b"]), "llama3.1:8b")
        XCTAssertEqual(OllamaStatus.resolveModel(chosen: "qwen", installed: ["llama3.1:8b", "qwen:7b"]), "qwen:7b")
        XCTAssertEqual(OllamaStatus.resolveModel(chosen: "qwen:7b", installed: ["qwen:7b"]), "qwen:7b")
        XCTAssertNil(OllamaStatus.resolveModel(chosen: "mistral", installed: ["llama3.1:8b"]))
        XCTAssertNil(OllamaStatus.resolveModel(chosen: "", installed: []))
    }

    func testProviderRunsTheAgentLoopOnAScriptedClient() async {
        let client = ScriptedChat([ScriptedChat.reply(text: "hello from a local model")])
        var events: [AgentEvent] = []
        for await event in OllamaProvider(client: client).run(task: "hi", workingDirectory: FileManager.default.temporaryDirectory, approve: { _ in true }) {
            events.append(event)
        }
        XCTAssertTrue(events.contains { if case .done(let text) = $0 { return text.contains("local model") } else { return false } })
    }
}
