import XCTest
@testable import Tristan
@testable import TristanCore

@MainActor
final class KidsModeTests: XCTestCase {
    private var retained: [Session] = []

    private func hub() -> Session {
        let hub = Session(history: nil, music: SpotifyController(runner: FakeSpotify(), isRunning: { true }, releaseDelay: .zero))
        retained.append(hub)
        hub.soundsOn = false; hub.voiceOn = false; hub.notificationsOn = false
        hub.kidsMode = false
        hub.approvalMode = .ask
        return hub
    }

    override func tearDown() async throws {
        for hub in retained { hub.kidsMode = false }
        retained.removeAll()
        for key in ["kidsMode", "parentAuth", "approvalMode"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testPINValidation() {
        XCTAssertFalse(ParentPIN.valid("123"))
        XCTAssertFalse(ParentPIN.valid("12a4"))
        XCTAssertTrue(ParentPIN.valid("1234"))
        XCTAssertNotEqual(ParentPIN.hash("1234"), ParentPIN.hash("1235"))
        XCTAssertFalse(ParentPIN.hash("1234").contains("1234"))
    }

    func testKidsModeForcesAskAndLocks() {
        let hub = hub()
        hub.approvalMode = .yolo
        hub.kidsMode = true
        XCTAssertEqual(hub.approvalMode, .ask)
        XCTAssertTrue(hub.kidsLocked)
    }

    func testLockingClosesSettingsAndDropsAuto() {
        let hub = hub()
        hub.kidsMode = true
        hub.unlockParent()
        XCTAssertFalse(hub.kidsLocked)
        hub.showSettings = true
        hub.approvalMode = .auto
        hub.closeSettings()
        XCTAssertTrue(hub.kidsLocked)
        XCTAssertFalse(hub.showSettings)
        XCTAssertEqual(hub.approvalMode, .ask)
    }

    func testOpeningSettingsWithoutKidsModeIsImmediate() {
        let hub = hub()
        hub.openSettings()
        XCTAssertTrue(hub.showSettings)
        hub.openSettings()
        XCTAssertFalse(hub.showSettings)
    }

    func testMicStaysShutWhileWorkingAndForAMomentAfter() async throws {
        let hub = hub()
        hub.active.provider = .demo
        XCTAssertFalse(hub.micBusy)
        hub.submit("say hello")
        XCTAssertTrue(hub.micBusy)
        hub.startListening()
        XCTAssertFalse(hub.listening, "push-to-talk must not start while Tristan is working")
        hub.cancel()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(hub.micBusy, "the mic stays shut briefly after the mission ends")
        for _ in 0..<100 where hub.micBusy { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(hub.micBusy, "the mic opens again once the mission is over")
    }

    func testDemoAnswersIgnoreTheMemoryBriefing() {
        let briefing = "Context: you have already worked in this folder.\n1. [done] Task: What is 7 times 8?\n\nTreat that as what you did. Current task:\nWhy is the sky blue?"
        let question = DemoAnswers.question(in: briefing)
        XCTAssertEqual(question, "Why is the sky blue?")
        XCTAssertTrue(DemoAnswers.answer(for: question)?.contains("Why is the sky blue?") == true)
        XCTAssertTrue(DemoAnswers.answer(for: "What is the biggest planet?")?.contains("Jupiter") == true)
        XCTAssertNil(DemoAnswers.answer(for: "write a README"))
    }
}

final class NoKeychainTests: XCTestCase {
    override func tearDown() { NoKeychain.enabled = false }

    func testDemoModeKeepsSecretsInMemoryAndNeverTouchesTheKeychain() {
        let account = "test.nokeychain.\(UUID().uuidString)"
        NoKeychain.enabled = true
        XCTAssertTrue(KeychainStore.set("secret", account: account))
        XCTAssertEqual(KeychainStore.get(account), "secret")
        XCTAssertTrue(KeychainStore.set("", account: account))
        XCTAssertNil(KeychainStore.get(account), "an empty value removes it")

        XCTAssertTrue(KeychainStore.set("only in memory", account: account))
        NoKeychain.enabled = false
        XCTAssertNil(KeychainStore.get(account), "nothing reached the real Keychain")
    }
}
