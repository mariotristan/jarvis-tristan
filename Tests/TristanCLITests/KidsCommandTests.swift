import XCTest
import TristanCore
@testable import TristanCLICore

private struct Quiet: AgentProvider {
    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AsyncStream { c in c.yield(.done("ok")); c.finish() }
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [CLIProvider] = []
    private var modes: [ApprovalMode] = []
    private var answers: [String?]
    private var asked: [String] = []
    init(answers: [String?] = []) { self.answers = answers }
    func make(_ p: CLIProvider, _ m: ApprovalMode) { lock.lock(); made.append(p); modes.append(m); lock.unlock() }
    var providers: [CLIProvider] { lock.lock(); defer { lock.unlock() }; return made }
    var approvalModes: [ApprovalMode] { lock.lock(); defer { lock.unlock() }; return modes }
    var prompts: [String] { lock.lock(); defer { lock.unlock() }; return asked }
    func next(_ prompt: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        asked.append(prompt)
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

final class KidsCommandTests: XCTestCase {
    private var saved: SettingsBackend!
    private var savedMemory = false
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kids-\(UUID().uuidString)")

    override func setUp() {
        saved = Settings.backend
        Settings.backend = MemoryBackend()
        savedMemory = ParentPIN.inMemory
        ParentPIN.inMemory = true
        ParentPIN.clearInMemory()
    }
    override func tearDown() {
        ParentPIN.clearInMemory()
        ParentPIN.inMemory = savedMemory
        Settings.backend = saved
    }

    /// How often a run waited after a wrong PIN (the real wait is replaced so tests run at once).
    private let delays = Counter()

    private func exec(_ arguments: [String], _ calls: Calls, interactive: Bool = true) async throws -> ExitCode {
        let command = try XCTUnwrap(TristanCommand.parseAsRoot(arguments) as? CLICommand)
        var env = CLIEnvironment(interactive: interactive, readPIN: { calls.next($0) },
                                 makeProvider: { p, m in calls.make(p, m); return Quiet() }, installInterrupt: false,
                                 historyURL: scratch.appendingPathComponent("history.json"),
                                 sessions: SessionRegistry(directory: scratch.appendingPathComponent("sessions"), isAlive: { _ in true }))
        let delays = self.delays
        env.afterPINCheck = { delays.add() }
        return await command.execute(environment: env)
    }

    // MARK: - Every checked parent PIN costs the same delay

    func testWrongPINWaitsOncePerAttempt() async throws {
        XCTAssertTrue(ParentPIN.set("1234"))
        Settings.set(true, forKey: "kidsMode")
        var code = try await exec(["kids", "off"], Calls(answers: ["9999"]))
        XCTAssertEqual(code, .failed)
        XCTAssertEqual(delays.value, 1)
        code = try await exec(["kids", "set-pin"], Calls(answers: ["0000"]))
        XCTAssertEqual(code, .failed)
        XCTAssertEqual(delays.value, 2)
        code = try await exec(["run", "--provider", "claude", "--allow-cloud", "hi"], Calls(answers: ["1111"]))
        XCTAssertEqual(code, .usage)
        XCTAssertEqual(delays.value, 3)
        code = try await exec(["config", "set", "ollama.model", "llama3"], Calls(answers: ["2222"]))
        XCTAssertEqual(code, .failed)
        XCTAssertEqual(delays.value, 4)
        XCTAssertTrue(kidsOn)
    }

    /// The right PIN waits exactly as long as a wrong one, so the time taken does not tell them apart. Nothing is
    /// checked (and nobody waits) with no terminal or when no PIN was entered.
    func testRightPINWaitsTooButNoCheckDoesNot() async throws {
        XCTAssertTrue(ParentPIN.set("1234"))
        Settings.set(true, forKey: "kidsMode")
        var code = try await exec(["kids", "off"], Calls(answers: ["1234"]), interactive: false)
        XCTAssertNotEqual(code, .ok)
        code = try await exec(["kids", "off"], Calls(answers: [nil]))
        XCTAssertEqual(code, .failed, "no PIN entered")
        XCTAssertEqual(delays.value, 0)
        code = try await exec(["kids", "off"], Calls(answers: ["1234"]))
        XCTAssertEqual(code, .ok)
        XCTAssertEqual(delays.value, 1)
    }

    func testPINCheckDelayIsAboutASecondAndAHalf() {
        XCTAssertEqual(Kids.pinCheckDelay, 1.5, accuracy: 0.01)
    }

    private var kidsOn: Bool { Settings.bool("kidsMode") }

    func testKidsRunRefusesCloudProvider() async throws {
        Settings.set(true, forKey: "kidsMode")
        for provider in ["claude", "copilot", "bedrock", "azure"] {
            let calls = Calls()
            let code = try await exec(["run", "--provider", provider, "hi"], calls)
            XCTAssertEqual(code, .usage, provider)
            XCTAssertEqual(calls.providers, [], "\(provider) must never be constructed")
        }
    }

    func testKidsRunDefaultsToOllama() async throws {
        Settings.set(true, forKey: "kidsMode")
        let calls = Calls()
        let code = try await exec(["run", "hi"], calls)
        XCTAssertEqual(code, .ok)
        XCTAssertEqual(calls.providers, [.ollama])
        XCTAssertEqual(calls.approvalModes, [.ask])
    }

    func testKidsRunForcesAsk() async throws {
        Settings.set(true, forKey: "kidsMode")
        for flag in ["--yolo", "--yes-routine"] {
            let calls = Calls()
            let code = try await exec(["run", flag, "hi"], calls)
            XCTAssertEqual(code, .usage, flag)
            XCTAssertEqual(calls.providers, [], flag)
        }
    }

    func testKidsOffNeedsPIN() async throws {
        XCTAssertTrue(ParentPIN.set("1234"))
        Settings.set(true, forKey: "kidsMode")
        let bad = try await exec(["kids", "off"], Calls(answers: ["9999"]))
        XCTAssertNotEqual(bad, .ok)
        XCTAssertTrue(kidsOn)
        let good = try await exec(["kids", "off"], Calls(answers: ["1234"]))
        XCTAssertEqual(good, .ok)
        XCTAssertFalse(kidsOn)
    }

    func testKidsOnRefusesWithoutPIN() async throws {
        let calls = Calls()
        let code = try await exec(["kids", "on"], calls, interactive: false)
        XCTAssertEqual(code, .usage)
        XCTAssertFalse(kidsOn)
    }

    func testKidsOnWithPINSucceedsWithoutAsking() async throws {
        XCTAssertTrue(ParentPIN.set("1234"))
        let calls = Calls()
        let code = try await exec(["kids", "on"], calls, interactive: false)
        XCTAssertEqual(code, .ok)
        XCTAssertTrue(kidsOn)
        XCTAssertEqual(calls.prompts, [])
    }

    /// Already on without a PIN (switched on in the Mac app with Touch ID): the same message as `off` and `set-pin`,
    /// not "Set a PIN first", which `set-pin` would then refuse.
    func testKidsOnWhenAlreadyOnWithoutPINSaysTheSameAsOff() async throws {
        Settings.set(true, forKey: "kidsMode")
        let err = Sink()
        Terminal.captureError = { err.add($0) }
        defer { Terminal.captureError = nil }
        let code = try await exec(["kids", "on"], Calls(), interactive: false)
        XCTAssertEqual(code, .usage)
        XCTAssertEqual(err.value, Kids.noPINMessage + "\n")
        XCTAssertTrue(kidsOn)
    }

    func testKidsOffWhenOnWithoutPINRefuses() async throws {
        Settings.set(true, forKey: "kidsMode")   // e.g. switched on from the Mac app in Touch ID mode
        let code = try await exec(["kids", "off"], Calls(answers: ["1234"]))
        XCTAssertNotEqual(code, .ok)
        XCTAssertTrue(kidsOn)
    }

    func testSetPinWhenKidsOnWithoutPINRefuses() async throws {
        Settings.set(true, forKey: "kidsMode")
        let code = try await exec(["kids", "set-pin"], Calls(answers: ["1234", "1234"]))
        XCTAssertNotEqual(code, .ok)
        XCTAssertFalse(ParentPIN.isSet)
        XCTAssertTrue(kidsOn)
    }

    func testFirstPINCanBeSetWhileKidsIsOff() async throws {
        let code = try await exec(["kids", "set-pin"], Calls(answers: ["1234", "1234"]))
        XCTAssertEqual(code, .ok)
        XCTAssertTrue(ParentPIN.matches("1234"))
    }

    func testKidsOffWhenAlreadyOffIsANoOp() async throws {
        let code = try await exec(["kids", "off"], Calls(), interactive: false)
        XCTAssertEqual(code, .ok)
        XCTAssertFalse(kidsOn)
    }

    func testEveryProviderButOllamaIsRefusedInKidsMode() async throws {
        Settings.set(true, forKey: "kidsMode")
        for provider in CLIProvider.allCases {
            let calls = Calls()
            let code = try await exec(["run", "--provider", provider.rawValue, "hi"], calls)
            if provider == .ollama {
                XCTAssertEqual(code, .ok)
                XCTAssertEqual(calls.providers, [.ollama])
            } else {
                XCTAssertEqual(code, .usage, provider.rawValue)
                XCTAssertEqual(calls.providers, [], provider.rawValue)
            }
        }
    }

    func testSetPinRejectsShortPIN() async throws {
        let code = try await exec(["kids", "set-pin"], Calls(answers: ["12", "12"]))
        XCTAssertEqual(code, .usage)
        XCTAssertFalse(ParentPIN.isSet)
        _ = try await exec(["kids", "set-pin"], Calls(answers: ["abcd", "abcd"]))
        XCTAssertFalse(ParentPIN.isSet)
    }

    func testSetPinSetsAndNeedsExistingPIN() async throws {
        var code = try await exec(["kids", "set-pin"], Calls(answers: ["1234", "1234"]))
        XCTAssertEqual(code, .ok)
        XCTAssertTrue(ParentPIN.matches("1234"))
        code = try await exec(["kids", "set-pin"], Calls(answers: ["0000", "5678", "5678"]))
        XCTAssertNotEqual(code, .ok)
        XCTAssertTrue(ParentPIN.matches("1234"))
        code = try await exec(["kids", "set-pin"], Calls(answers: ["1234", "5678", "5678"]))
        XCTAssertEqual(code, .ok)
        XCTAssertTrue(ParentPIN.matches("5678"))
        code = try await exec(["kids", "set-pin"], Calls(answers: ["5678", "1111", "2222"]))
        XCTAssertNotEqual(code, .ok)
        XCTAssertTrue(ParentPIN.matches("5678"), "a mismatched confirmation changes nothing")
    }

    func testNoTerminalFailsClosed() async throws {
        XCTAssertTrue(ParentPIN.set("1234"))
        Settings.set(true, forKey: "kidsMode")
        let calls = Calls(answers: ["1234", "5678", "5678"])
        var code = try await exec(["kids", "off"], calls, interactive: false)
        XCTAssertEqual(code, .usage)
        XCTAssertTrue(kidsOn)
        code = try await exec(["kids", "set-pin"], calls, interactive: false)
        XCTAssertEqual(code, .usage)
        XCTAssertTrue(ParentPIN.matches("1234"))
        code = try await exec(["run", "--provider", "claude", "--allow-cloud", "hi"], calls, interactive: false)
        XCTAssertEqual(code, .usage)
        XCTAssertEqual(calls.providers, [])
        XCTAssertEqual(calls.prompts, [], "nothing is read without a terminal")
    }

    func testSetPinWithNoTerminalAndNoPINFailsClosed() async throws {
        let code = try await exec(["kids", "set-pin"], Calls(answers: ["1234", "1234"]), interactive: false)
        XCTAssertEqual(code, .usage)
        XCTAssertFalse(ParentPIN.isSet)
    }

    func testAllowCloudNeedsRightPINAndLastsOneRun() async throws {
        XCTAssertTrue(ParentPIN.set("1234"))
        Settings.set(true, forKey: "kidsMode")
        let wrong = Calls(answers: ["0000"])
        var code = try await exec(["run", "--provider", "claude", "--allow-cloud", "hi"], wrong)
        XCTAssertEqual(code, .usage)
        XCTAssertEqual(wrong.providers, [])

        let right = Calls(answers: ["1234"])
        code = try await exec(["run", "--provider", "claude", "--allow-cloud", "hi"], right)
        XCTAssertEqual(code, .ok)
        XCTAssertEqual(right.providers, [.claude])
        XCTAssertEqual(right.approvalModes, [.ask])
        XCTAssertTrue(kidsOn, "kids mode stays on")

        let again = Calls()
        code = try await exec(["run", "--provider", "claude", "hi"], again)
        XCTAssertEqual(code, .usage)
        XCTAssertEqual(again.providers, [])
    }

    func testAllowCloudStillForcesAsk() async throws {
        XCTAssertTrue(ParentPIN.set("1234"))
        Settings.set(true, forKey: "kidsMode")
        let calls = Calls(answers: ["1234"])
        let code = try await exec(["run", "--provider", "claude", "--allow-cloud", "--yolo", "hi"], calls)
        XCTAssertEqual(code, .usage)
        XCTAssertEqual(calls.providers, [])
        XCTAssertEqual(calls.prompts, [], "the PIN is not even asked for")
    }

    func testAllowCloudWithNoPINSetIsRefused() async throws {
        Settings.set(true, forKey: "kidsMode")
        let calls = Calls(answers: ["1234"])
        let code = try await exec(["run", "--provider", "claude", "--allow-cloud", "hi"], calls)
        XCTAssertEqual(code, .usage)
        XCTAssertEqual(calls.providers, [])
    }

    func testRunWithoutKidsModeIsUnchanged() async throws {
        let calls = Calls()
        let code = try await exec(["run", "--provider", "claude", "--yolo", "hi"], calls)
        XCTAssertEqual(code, .ok)
        XCTAssertEqual(calls.providers, [.claude])
        XCTAssertEqual(calls.approvalModes, [.yolo])
    }

    // MARK: - A settings file that cannot be read: kids mode counts as on and the file is never rewritten

    /// Points `Settings` at a settings file holding `contents` (corrupt), and returns its URL.
    private func corruptSettings(_ contents: Data) throws -> URL {
        let url = scratch.appendingPathComponent("settings-\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try contents.write(to: url)
        Settings.backend = JSONFileBackend(url: url)
        return url
    }

    private static let corrupt: [Data] = [Data([0xFF, 0x00, 0x1B, 0x9B, 0x42]), Data(#"{"kidsMode": fal"#.utf8)]

    func testCorruptSettingsRefuseCloudProviders() async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        for contents in Self.corrupt {
            let url = try corruptSettings(contents)
            for provider in ["claude", "copilot", "bedrock", "azure"] {
                let calls = Calls()
                let code = try await exec(["run", "--provider", provider, "hi"], calls)
                XCTAssertEqual(code, .usage, provider)
                XCTAssertEqual(calls.providers, [], "\(provider) must never be constructed")
            }
            for flag in ["--yolo", "--yes-routine"] {
                let calls = Calls()
                let code = try await exec(["run", flag, "hi"], calls)
                XCTAssertEqual(code, .usage, flag)
                XCTAssertEqual(calls.providers, [])
            }
            // --allow-cloud needs a parent PIN, and none is set.
            let cloud = Calls(answers: ["1234"])
            let cloudCode = try await exec(["run", "--provider", "claude", "--allow-cloud", "hi"], cloud)
            XCTAssertEqual(cloudCode, .usage)
            XCTAssertEqual(cloud.providers, [])
            let local = Calls()
            let localCode = try await exec(["run", "hi"], local)
            XCTAssertEqual(localCode, .ok)
            XCTAssertEqual(local.providers, [.ollama])
            XCTAssertEqual(try Data(contentsOf: url), contents, "the file must not be rewritten")
        }
    }

    func testCorruptSettingsAreNeverOverwritten() async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        XCTAssertTrue(ParentPIN.set("1234"))
        for contents in Self.corrupt {
            let url = try corruptSettings(contents)
            // The right PIN is not enough: the write itself is refused.
            let off = try await exec(["kids", "off"], Calls(answers: ["1234"]))
            XCTAssertEqual(off, .failed)
            let on = try await exec(["kids", "on"], Calls())
            XCTAssertEqual(on, .failed)
            let set = try await exec(["config", "set", "ollama.model", "llama3"], Calls(answers: ["1234"]))
            XCTAssertEqual(set, .failed)
            let unset = try await exec(["config", "unset", "ollama.model"], Calls(answers: ["1234"]))
            XCTAssertEqual(unset, .failed)
            XCTAssertEqual(try Data(contentsOf: url), contents, "the file must not be rewritten")
            XCTAssertTrue(Kids.isOn)
        }
    }

    /// `kids on` with an unreadable file and no PIN: first why kids mode counts as on, then the usual no-PIN message.
    func testKidsOnWithCorruptSettingsSaysWhyFirst() async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = try corruptSettings(Self.corrupt[1])
        let err = Sink()
        Terminal.captureError = { err.add($0) }
        defer { Terminal.captureError = nil }
        let code = try await exec(["kids", "on"], Calls(), interactive: false)
        XCTAssertEqual(code, .usage)
        let text = err.value
        let why = try XCTUnwrap(text.range(of: "cannot be read"), text)
        let pin = try XCTUnwrap(text.range(of: Kids.noPINMessage), text)
        XCTAssertLessThan(why.lowerBound, pin.lowerBound, text)
        XCTAssertEqual(try Data(contentsOf: url), Self.corrupt[1])
    }

    func testCorruptSettingsStatusSaysOn() async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try corruptSettings(Self.corrupt[0])
        let out = Sink(), err = Sink()
        Terminal.capture = { out.add($0) }
        Terminal.captureError = { err.add($0) }
        defer { Terminal.capture = nil; Terminal.captureError = nil }
        _ = try await exec(["kids", "status"], Calls(), interactive: false)
        XCTAssertEqual(out.value, "Kids mode: on\nParent PIN: not set\n")
        XCTAssertTrue(err.value.contains("cannot be read"), err.value)
    }

    func testStatusPrintsState() async throws {
        let out = Sink()
        Terminal.capture = { out.add($0) }
        defer { Terminal.capture = nil }
        _ = try await exec(["kids", "status"], Calls(), interactive: false)
        XCTAssertEqual(out.value, "Kids mode: off\nParent PIN: not set\n")
        XCTAssertTrue(ParentPIN.set("1234"))
        Settings.set(true, forKey: "kidsMode")
        let on = Sink()
        Terminal.capture = { on.add($0) }
        _ = try await exec(["kids", "status"], Calls(), interactive: false)
        XCTAssertEqual(on.value, "Kids mode: on\nParent PIN: set\n")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func add(_ s: String) { lock.lock(); text += s; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}
