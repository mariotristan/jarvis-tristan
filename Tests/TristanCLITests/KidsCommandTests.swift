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

    private func exec(_ arguments: [String], _ calls: Calls, interactive: Bool = true) async throws -> ExitCode {
        let command = try XCTUnwrap(TristanCommand.parseAsRoot(arguments) as? CLICommand)
        let env = CLIEnvironment(interactive: interactive, readPIN: { calls.next($0) },
                                 makeProvider: { p, m in calls.make(p, m); return Quiet() }, installInterrupt: false)
        return await command.execute(environment: env)
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

    func testKidsOffWithoutPINIsAllowedAndOnIsFree() async throws {
        let calls = Calls()
        var code = try await exec(["kids", "on"], calls, interactive: false)
        XCTAssertEqual(code, .ok)
        XCTAssertTrue(kidsOn)
        code = try await exec(["kids", "off"], calls, interactive: false)
        XCTAssertEqual(code, .ok)
        XCTAssertFalse(kidsOn)
        XCTAssertEqual(calls.prompts, [])
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

    func testStatus() async throws {
        let code = try await exec(["kids", "status"], Calls(), interactive: false)
        XCTAssertEqual(code, .ok)
    }
}
