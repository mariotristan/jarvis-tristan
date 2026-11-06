import XCTest
@testable import Tristan

// MARK: wake word

final class WakeWordTests: XCTestCase {
    func testMatcherExtractsTheCommandAfterTheWakePhrase() {
        XCTAssertEqual(WakeWordMatcher.command(in: "hey tristan write a function"), "write a function")
        XCTAssertEqual(WakeWordMatcher.command(in: "Hey, Tristan, list the files."), "list the files.")
        XCTAssertEqual(WakeWordMatcher.command(in: "OK Tristan add login"), "add login")
        XCTAssertEqual(WakeWordMatcher.command(in: "hey tristan"), "")
    }

    func testMatcherIgnoresSpeechWithoutTheWakePhrase() {
        XCTAssertNil(WakeWordMatcher.command(in: "write a function"))
        XCTAssertNil(WakeWordMatcher.command(in: "hello there tristan"))
        XCTAssertNil(WakeWordMatcher.command(in: "they tristanic"))
    }

    func testMatcherUsesTheLastWakePhrase() {
        XCTAssertEqual(WakeWordMatcher.command(in: "hey tristan never mind hey tristan run tests"), "run tests")
    }

    func testCaptureStartsUpdatesAndSubmitsAfterSilence() {
        var capture = WakeCapture()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(capture.feed(transcript: "blah blah", now: t0), .none)
        XCTAssertEqual(capture.feed(transcript: "hey tristan", now: t0), .started)
        XCTAssertEqual(capture.tick(now: t0.addingTimeInterval(1)), .none, "waits longer when nothing was said after the wake phrase")
        XCTAssertEqual(capture.feed(transcript: "hey tristan add", now: t0.addingTimeInterval(1.2)), .update("add"))
        XCTAssertEqual(capture.feed(transcript: "hey tristan add login", now: t0.addingTimeInterval(1.6)), .update("add login"))
        XCTAssertEqual(capture.tick(now: t0.addingTimeInterval(2.5)), .none, "still within the silence timeout")
        XCTAssertEqual(capture.tick(now: t0.addingTimeInterval(3.6)), .submit("add login"))
        XCTAssertFalse(capture.capturing)
        XCTAssertEqual(capture.tick(now: t0.addingTimeInterval(9)), .none)
    }

    func testCaptureCancelsWhenNothingFollowsTheWakePhrase() {
        var capture = WakeCapture()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(capture.feed(transcript: "hey tristan", now: t0), .started)
        XCTAssertEqual(capture.tick(now: t0.addingTimeInterval(6)), .cancelled)
        XCTAssertFalse(capture.capturing)
    }

    func testSameTranscriptDoesNotCountAsActivity() {
        var capture = WakeCapture()
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = capture.feed(transcript: "hey tristan run tests", now: t0)
        XCTAssertEqual(capture.feed(transcript: "hey tristan run tests", now: t0.addingTimeInterval(1.5)), .none)
        XCTAssertEqual(capture.tick(now: t0.addingTimeInterval(2)), .submit("run tests"), "repeats must not extend the silence timer")
    }
}

// MARK: history, shortcuts, notifications

final class HistoryTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tristan-history-\(UUID().uuidString.prefix(8))/history.json")
    }

    func testRoundTripAndPrivatePermissions() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HistoryStore(url: url)
        XCTAssertEqual(store.load(), [])
        let record = MissionRecord(task: "add login", provider: "CLAUDE", mode: "ASK", status: "done", summary: "ok", folder: "/tmp/x")
        store.save([record])
        XCTAssertEqual(store.load().first?.task, "add login")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600, "history may contain task text, so keep it private")
    }

    func testLimitKeepsTheNewestRecords() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HistoryStore(url: url, limit: 3)
        store.save((0..<10).map { MissionRecord(task: "t\($0)", provider: "DEMO", mode: "ASK", status: "done", summary: "", folder: "/") })
        XCTAssertEqual(store.load().map(\.task), ["t0", "t1", "t2"], "records are stored newest first")
    }

    func testCorruptFileLoadsAsEmpty() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(HistoryStore(url: url).load(), [])
    }
}

final class SmallPiecesTests: XCTestCase {
    func testHotkeyPresetsAreDistinct() {
        let modifiers = HotkeyPreset.allCases.map(\.modifiers)
        XCTAssertEqual(Set(modifiers).count, HotkeyPreset.allCases.count)
        XCTAssertEqual(HotkeyPreset.optionSpace.talkLabel, "⌥⇧ Space")
    }

    func testNotificationsOnlyWhenEnabledInactiveAndBundled() {
        XCTAssertTrue(Notifier.shouldNotify(enabled: true, appIsActive: false, bundled: true))
        XCTAssertFalse(Notifier.shouldNotify(enabled: false, appIsActive: false, bundled: true))
        XCTAssertFalse(Notifier.shouldNotify(enabled: true, appIsActive: true, bundled: true))
        XCTAssertFalse(Notifier.shouldNotify(enabled: true, appIsActive: false, bundled: false))
    }
}

// MARK: session integration

@MainActor
final class SessionHistoryTests: XCTestCase {
    func testFailedMissionIsRecordedPersistedAndRerunnable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-session-\(UUID().uuidString.prefix(8))/history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HistoryStore(url: url)

        let session = Session(history: store)
        session.soundsOn = false
        session.voiceOn = false
        session.notificationsOn = false
        session.records = []
        session.provider = .azure           // unconfigured, so it fails immediately without any network
        session.submit("add login")

        for _ in 0..<50 where session.phase != .failed { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(session.records.count, 1)
        XCTAssertEqual(session.records.first?.task, "add login")
        XCTAssertEqual(session.records.first?.status, "failed")
        XCTAssertEqual(store.load().count, 1, "history must be written to disk")

        session.provider = .demo
        session.rerun(session.records[0])
        XCTAssertEqual(session.draft, "add login")
        XCTAssertEqual(session.provider, .azure, "re-run restores the provider the mission used")

        session.clearHistory()
        XCTAssertTrue(session.records.isEmpty)
        XCTAssertEqual(store.load(), [])
    }
}
