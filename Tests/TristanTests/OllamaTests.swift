import XCTest
@testable import Tristan

private struct StubProvider: AgentProvider {
    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AsyncStream { c in c.yield(.code("answer")); c.yield(.done("ok")); c.finish() }
    }
}

private final class KindLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ProviderKind] = []
    func add(_ kind: ProviderKind) { lock.lock(); items.append(kind); lock.unlock() }
    var kinds: [ProviderKind] { lock.lock(); defer { lock.unlock() }; return items }
}

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

@MainActor
final class KidsLocalOnlyTests: XCTestCase {
    private var retained: [Session] = []

    private func hub(localReady: Bool, kinds: KindLog) -> Session {
        ParentPIN.inMemory = true
        ParentPIN.set("1234")
        let hub = Session(history: nil, music: SpotifyController(runner: FakeSpotify(), isRunning: { true }, releaseDelay: .zero))
        retained.append(hub)
        hub.soundsOn = false; hub.voiceOn = false; hub.notificationsOn = false
        hub.parentAuth = .pin
        hub.kidsMode = true
        hub.localModelReady = { localReady }
        hub.providerFactory = { kind, _ in kinds.add(kind); return StubProvider() }
        hub.active.provider = .claude
        return hub
    }

    override func tearDown() async throws {
        for hub in retained { hub.kidsMode = false }
        retained.removeAll()
        ParentPIN.inMemory = false
        for key in ["kidsMode", "parentAuth", "approvalMode"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
    }

    func testKidsQuestionsGoToTheLocalModelEvenWithACloudProviderChosen() async throws {
        let kinds = KindLog()
        let hub = hub(localReady: true, kinds: kinds)
        hub.submit("Why is the sky blue?")
        try await wait { hub.active.phase == .done }
        XCTAssertEqual(kinds.kinds, [.ollama])
        XCTAssertEqual(hub.active.phase, .done)
    }

    func testWithoutALocalModelTheChildIsToldToAskAParent() async throws {
        let kinds = KindLog()
        let hub = hub(localReady: false, kinds: kinds)
        hub.submit("Why is the sky blue?")
        try await wait { hub.active.phase == .failed }
        XCTAssertEqual(hub.active.status, "ASK A PARENT")
        XCTAssertTrue(hub.active.code.contains("ask a parent"))
        XCTAssertNotNil(hub.parentPrompt, "a parent is asked whether this one question may go to the cloud")
        XCTAssertEqual(kinds.kinds, [.ollama], "nothing reached a cloud provider")
    }

    func testAParentCanAllowOneCloudAnswerAndOnlyOne() async throws {
        let kinds = KindLog()
        let hub = hub(localReady: false, kinds: kinds)
        hub.submit("Why is the sky blue?")
        try await wait { hub.parentPrompt != nil }
        XCTAssertFalse(hub.submitParentPIN("0000"))
        XCTAssertTrue(hub.submitParentPIN("1234"))
        try await wait { hub.active.phase == .done }
        XCTAssertEqual(kinds.kinds, [.ollama, .claude], "the approved question used the chosen cloud provider")
        XCTAssertTrue(hub.kidsLocked, "approving one answer does not unlock kids mode")

        hub.submit("And the grass?")
        try await wait { hub.active.phase == .failed }
        XCTAssertEqual(kinds.kinds, [.ollama, .claude, .ollama], "the next question is local again")
    }

    func testCancellingTheParentPromptKeepsTheQuestionOffTheCloud() async throws {
        let kinds = KindLog()
        let hub = hub(localReady: false, kinds: kinds)
        hub.submit("Why is the sky blue?")
        try await wait { hub.parentPrompt != nil }
        hub.cancelParentPrompt()
        XCTAssertEqual(hub.active.phase, .failed)
        XCTAssertEqual(kinds.kinds, [.ollama])
    }
}
