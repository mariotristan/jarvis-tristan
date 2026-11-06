import XCTest
@testable import Tristan

@MainActor
final class MultiSessionTests: XCTestCase {
    private var base: URL!
    private var folderA: URL!
    private var folderB: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-multi-\(UUID().uuidString.prefix(8))")
        folderA = base.appendingPathComponent("a")
        folderB = base.appendingPathComponent("b")
        for url in [folderA!, folderB!] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func hub(history: HistoryStore? = nil, defaults: UserDefaults = .standard) -> Session {
        let hub = Session(history: history, music: SpotifyController(runner: FakeSpotify(), isRunning: { true }, releaseDelay: .zero), defaults: defaults)
        hub.soundsOn = false; hub.voiceOn = false; hub.notificationsOn = false
        hub.approvalMode = .ask
        return hub
    }

    /// A hub with two idle DEMO sessions in different folders.
    private func twoSessions() -> (hub: Session, first: MissionSession, second: MissionSession) {
        let hub = hub()
        let first = hub.active
        first.provider = .demo
        first.workingDirectory = folderA
        let second = hub.newSession(provider: .demo, folder: folderB)!
        return (hub, first, second)
    }

    private func eventually(timeout: Double = 15, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    }

    // MARK: running side by side

    func testTwoSessionsRunAtTheSameTimeAndStayIsolated() async throws {
        let (hub, first, second) = twoSessions()
        first.submit("first task")
        second.submit("second task")
        try await eventually { first.pending != nil && second.pending != nil }
        XCTAssertNotNil(first.pending); XCTAssertNotNil(second.pending, "both are waiting at once")

        XCTAssertTrue(first.log.contains { $0.text.contains("first task") })
        XCTAssertFalse(first.log.contains { $0.text.contains("second task") }, "logs never mix")
        XCTAssertFalse(second.log.contains { $0.text.contains("first task") })
        XCTAssertNotEqual(first.missionID, second.missionID)

        // Answering one does not touch the other.
        second.resolve(true)
        try await eventually(timeout: 25) { second.phase == .done }
        XCTAssertEqual(second.phase, .done)
        XCTAssertEqual(first.phase, .awaitingApproval, "the first is still waiting for its own answer")
        XCTAssertTrue(second.code.contains("export function login"))
        XCTAssertTrue(first.code.isEmpty, "the first has written nothing")

        first.resolve(false)
        try await eventually { first.phase == .failed }
        XCTAssertEqual(first.phase, .failed)
        XCTAssertEqual(second.phase, .done, "denying the first did not disturb the finished second")

        // Each mission is recorded once, with its own provider and folder.
        XCTAssertEqual(hub.records.count, 2)
        XCTAssertEqual(Set(hub.records.map(\.task)), ["first task", "second task"])
        XCTAssertEqual(hub.records.first { $0.task == "second task" }?.status, "done")
        XCTAssertEqual(hub.records.first { $0.task == "first task" }?.folder, folderA.path)
    }

    func testAbortingOneSessionLeavesTheOtherRunning() async throws {
        let (_, first, second) = twoSessions()
        first.submit("one"); second.submit("two")
        try await eventually { first.pending != nil && second.pending != nil }
        first.cancel()
        XCTAssertEqual(first.phase, .failed)
        XCTAssertEqual(first.status, "ABORTED")
        XCTAssertEqual(second.phase, .awaitingApproval, "the other session is untouched")
        second.resolve(true)
        try await eventually(timeout: 25) { second.phase == .done }
        XCTAssertEqual(second.phase, .done)
    }

    func testSessionsHaveTheirOwnProviderAndFolder() {
        let hub = hub()
        let first = hub.active
        first.provider = .claude; first.workingDirectory = folderA
        let second = hub.newSession(provider: .copilot, folder: folderB)!
        XCTAssertEqual(hub.provider, .copilot, "the hub shows the active session")
        XCTAssertEqual(hub.workingDirectory, folderB)
        hub.provider = .bedrock                                   // changes only the active session
        XCTAssertEqual(second.provider, .bedrock)
        XCTAssertEqual(first.provider, .claude)
        hub.select(first.id)
        XCTAssertEqual(hub.provider, .claude)
        XCTAssertEqual(hub.workingDirectory, folderA)
    }

    func testANewSessionStartsFromTheActiveOnesSettings() {
        let hub = hub()
        hub.provider = .azure
        hub.workingDirectory = folderA
        let created = hub.newSession()!
        XCTAssertEqual(created.provider, .azure)
        XCTAssertEqual(created.workingDirectory, folderA)
        XCTAssertEqual(hub.active.id, created.id, "and switches to it")
        let background = hub.newSession(select: false)!
        XCTAssertNotEqual(hub.active.id, background.id)
    }

    // MARK: needing attention

    func testASessionInTheBackgroundThatNeedsApprovalIsFlaggedAndAnswerable() async throws {
        let (hub, first, second) = twoSessions()
        second.submit("work in the background")
        hub.select(first.id)                                     // looking at the idle one
        try await eventually { second.pending != nil }
        XCTAssertEqual(hub.attention?.id, second.id)
        XCTAssertEqual(hub.backgroundApprovals.map(\.id), [second.id])
        XCTAssertNil(hub.pending, "the active session has nothing to approve")
        try await eventually { hub.overallPhase == .awaitingApproval }
        XCTAssertEqual(hub.overallPhase, .awaitingApproval, "the notch and reactor reflect the most urgent session")

        hub.resolveAttention(true)                               // what the notch's APPROVE does
        XCTAssertEqual(second.phase, .working)
        XCTAssertTrue(hub.backgroundApprovals.isEmpty)
        second.cancel()
    }

    func testTheActiveSessionComesFirstWhenBothWait() async throws {
        let (hub, first, second) = twoSessions()
        first.submit("a"); second.submit("b")
        try await eventually { first.pending != nil && second.pending != nil }
        hub.select(second.id)
        XCTAssertEqual(hub.attention?.id, second.id)
        hub.select(first.id)
        XCTAssertEqual(hub.attention?.id, first.id)
        first.cancel(); second.cancel()
    }

    func testOverallPhaseIsWorkingWhenAnySessionWorksEvenIfTheActiveOneIsIdle() async throws {
        let (hub, first, second) = twoSessions()
        second.submit("busy one")
        hub.select(first.id)
        try await eventually { hub.overallPhase == .working }
        XCTAssertEqual(first.phase, .idle)
        XCTAssertEqual(hub.overallPhase, .working)
        second.cancel()
        try await eventually { hub.overallPhase != .working }
        XCTAssertNotEqual(hub.overallPhase, .working)
    }

    func testWarnsWhenTwoSessionsWorkInTheSameFolder() async throws {
        let hub = hub()
        let first = hub.active
        first.provider = .demo; first.workingDirectory = folderA
        let second = hub.newSession(provider: .demo, folder: folderA)!
        first.submit("one")
        try await eventually { first.pending != nil }
        second.submit("two")
        XCTAssertTrue(second.log.contains { $0.text.contains("Session 1") && $0.text.contains("same folder") || $0.text.contains("also working in this folder") })
        XCTAssertFalse(first.log.contains { $0.text.contains("also working") }, "the warning goes to the session that is starting")
        first.cancel(); second.cancel()
    }

    // MARK: opening and closing

    func testClosingARunningSessionAbortsAndRecordsItAndKeepsTheOthers() async throws {
        let (hub, first, second) = twoSessions()
        second.submit("will be closed")
        try await eventually { second.pending != nil }
        hub.close(second.id)
        XCTAssertEqual(hub.sessions.map(\.id), [first.id])
        XCTAssertEqual(second.status, "ABORTED")
        XCTAssertEqual(hub.records.first?.task, "will be closed")
        XCTAssertEqual(hub.records.first?.status, "aborted")
        XCTAssertEqual(hub.active.id, first.id, "the neighbour becomes active")
    }

    func testClosingTheLastSessionLeavesAFreshOne() {
        let hub = hub()
        let only = hub.active
        hub.provider = .copilot
        hub.close(only.id)
        XCTAssertEqual(hub.sessions.count, 1)
        XCTAssertNotEqual(hub.active.id, only.id)
        XCTAssertEqual(hub.active.provider, .copilot, "it keeps the provider")
        XCTAssertEqual(hub.active.phase, .idle)
    }

    func testThereIsALimitOnOpenSessions() {
        let hub = hub()
        while hub.sessions.count < Session.maxSessions { XCTAssertNotNil(hub.newSession()) }
        XCTAssertNil(hub.newSession(), "no more than \(Session.maxSessions)")
        XCTAssertEqual(hub.sessions.count, Session.maxSessions)
    }

    func testSelectingByIndexAndLabels() {
        let hub = hub()
        let first = hub.active
        let second = hub.newSession()!
        hub.select(index: 0)
        XCTAssertEqual(hub.active.id, first.id)
        hub.select(index: 5)                                      // out of range does nothing
        XCTAssertEqual(hub.active.id, first.id)
        XCTAssertEqual(hub.label(for: first), "Session 1")
        XCTAssertEqual(hub.label(for: second), "Session 2")
    }

    func testOpenSessionsComeBackAfterARestart() throws {
        let suite = "tristan-multi-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HistoryStore(url: base.appendingPathComponent("history.json"))

        let before = hub(history: store, defaults: defaults)
        before.provider = .claude; before.workingDirectory = folderA
        before.newSession(provider: .copilot, folder: folderB)
        XCTAssertEqual(before.sessions.count, 2)

        let after = hub(history: store, defaults: defaults)
        XCTAssertEqual(after.sessions.map(\.provider), [.claude, .copilot])
        XCTAssertEqual(after.sessions.map(\.workingDirectory.path), [folderA.path, folderB.path])
        XCTAssertEqual(after.active.provider, .copilot, "the active session is remembered")
        XCTAssertTrue(after.sessions.allSatisfy { $0.phase == .idle && $0.log.isEmpty }, "running work is not resurrected")

        let anonymous = hub(history: nil, defaults: defaults)       // an in-memory hub neither saves nor restores
        XCTAssertEqual(anonymous.sessions.count, 1)
    }

    func testRemoteAndMusicStillTalkToTheActiveSession() async throws {
        let (hub, first, second) = twoSessions()
        hub.select(first.id)
        hub.musicOn = true
        hub.submit("next song")                                   // a music command: no mission anywhere
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(first.phase, .idle); XCTAssertEqual(second.phase, .idle)
        XCTAssertTrue(first.log.contains { $0.text.contains("♪") }, "the reply is noted in the active session")
        hub.musicOn = false
    }
}
