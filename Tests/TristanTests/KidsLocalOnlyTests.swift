import XCTest
@testable import Tristan
@testable import TristanCore

struct StubProvider: AgentProvider {
    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AsyncStream { c in c.yield(.code("answer")); c.yield(.done("ok")); c.finish() }
    }
}

final class KindLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ProviderKind] = []
    func add(_ kind: ProviderKind) { lock.lock(); items.append(kind); lock.unlock() }
    var kinds: [ProviderKind] { lock.lock(); defer { lock.unlock() }; return items }
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

    func testTheScriptedDemoProviderStaysItselfInKidsMode() async throws {
        let kinds = KindLog()
        let hub = hub(localReady: true, kinds: kinds)
        hub.active.provider = .demo
        hub.submit("Why is the sky blue?")
        try await wait { hub.active.phase == .done }
        XCTAssertEqual(kinds.kinds, [.demo], "the recorded kids demo keeps its scripted answers even when Ollama is running")
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
