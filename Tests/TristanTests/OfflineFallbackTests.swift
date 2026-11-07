import XCTest
@testable import Tristan
@testable import TristanCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func bump() { lock.lock(); value += 1; lock.unlock() }
}

@MainActor
final class OfflineFallbackTests: XCTestCase {
    private var retained: [Session] = []

    private func hub(offline: Bool, provider: ProviderKind = .claude, ollamaUp: Bool, startOutcome: LocalModelLauncher.Outcome,
                     kinds: KindLog, starts: Counter) -> Session {
        let hub = Session(history: nil, music: SpotifyController(runner: FakeSpotify(), isRunning: { true }, releaseDelay: .zero))
        retained.append(hub)
        hub.soundsOn = false; hub.voiceOn = false; hub.notificationsOn = false
        hub.kidsMode = false
        hub.offline = offline
        let up = Counter()
        if ollamaUp { up.bump() }
        hub.localModelReady = { up.count > 0 }
        hub.startLocalModel = { starts.bump(); if startOutcome == .ready { up.bump() }; return startOutcome }
        hub.providerFactory = { kind, _ in kinds.add(kind); return StubProvider() }
        hub.active.provider = provider
        return hub
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
    }

    override func tearDown() async throws {
        retained.removeAll()
        for key in ["kidsMode", "approvalMode"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testOnlineMissionsStayOnTheChosenProvider() async throws {
        let kinds = KindLog(), starts = Counter()
        let hub = hub(offline: false, ollamaUp: false, startOutcome: .ready, kinds: kinds, starts: starts)
        hub.submit("hello")
        try await wait { hub.active.phase == .done }
        XCTAssertEqual(kinds.kinds, [.claude])
        XCTAssertEqual(starts.count, 0)
    }

    func testOfflineCloudMissionsFallBackToOllamaWhenItIsRunning() async throws {
        let kinds = KindLog(), starts = Counter()
        let hub = hub(offline: true, ollamaUp: true, startOutcome: .ready, kinds: kinds, starts: starts)
        hub.submit("hello")
        try await wait { hub.active.phase == .done }
        XCTAssertEqual(kinds.kinds, [.ollama])
        XCTAssertEqual(starts.count, 0, "Ollama was already running")
        XCTAssertTrue(hub.active.log.contains { $0.text.contains("Falling back") })
    }

    func testOfflineStartsOllamaWhenItIsOffAndShowsThatItIsWorkingOnIt() async throws {
        let kinds = KindLog(), starts = Counter()
        let hub = hub(offline: true, ollamaUp: false, startOutcome: .ready, kinds: kinds, starts: starts)
        hub.submit("hello")
        try await wait { hub.active.phase == .done }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(kinds.kinds, [.ollama])
        XCTAssertTrue(hub.active.log.contains { $0.text.contains("starting it now") })
        XCTAssertTrue(hub.active.log.contains { $0.text.contains("Ollama is running") })
    }

    func testOfflineWithOllamaNotInstalledSaysSoAndRunsNothing() async throws {
        let kinds = KindLog(), starts = Counter()
        let hub = hub(offline: true, ollamaUp: false, startOutcome: .notInstalled, kinds: kinds, starts: starts)
        hub.submit("hello")
        try await wait { hub.active.phase == .failed }
        XCTAssertEqual(hub.active.status, "FALLBACK FAILED")
        XCTAssertTrue(hub.active.code.contains("setup-ollama.sh"))
        XCTAssertFalse(hub.active.log.contains { $0.kind == .ok }, "the mission never ran")
    }

    func testOfflineWithNoModelAsksForOnePull() async throws {
        let kinds = KindLog(), starts = Counter()
        let hub = hub(offline: true, ollamaUp: false, startOutcome: .noModel, kinds: kinds, starts: starts)
        hub.submit("hello")
        try await wait { hub.active.phase == .failed }
        XCTAssertTrue(hub.active.code.contains("ollama pull"))
    }

    func testOllamaItselfIsNotAFallbackWhenOffline() async throws {
        let kinds = KindLog(), starts = Counter()
        let hub = hub(offline: true, provider: .ollama, ollamaUp: true, startOutcome: .ready, kinds: kinds, starts: starts)
        hub.submit("hello")
        try await wait { hub.active.phase == .done }
        XCTAssertEqual(kinds.kinds, [.ollama])
        XCTAssertFalse(hub.active.log.contains { $0.text.contains("Falling back") })
    }
}
