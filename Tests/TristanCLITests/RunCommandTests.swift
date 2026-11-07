import XCTest
import TristanCore
@testable import TristanCLICore

/// Plays back a script; `approval` asks once before the final event.
private struct FakeProvider: AgentProvider {
    var events: [AgentEvent]
    var approval: ApprovalRequest?
    var final: AgentEvent

    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AsyncStream { c in
            Task {
                for event in events { c.yield(event) }
                if let approval {
                    let ok = await approve(approval)
                    c.yield(.log(ok ? "approved" : "skipped: denied"))
                }
                c.yield(final)
                c.finish()
            }
        }
    }
}

private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func add(_ s: String) { lock.lock(); text += s; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}

final class RunCommandTests: XCTestCase {
    private var saved: SettingsBackend!

    override func setUp() { saved = Settings.backend; Settings.backend = MemoryBackend() }
    override func tearDown() { Settings.backend = saved }

    private func run(_ provider: AgentProvider, interactive: Bool = false, answer: String? = nil) async -> (ExitCode, String, String) {
        let out = Sink(), err = Sink()
        let approver = TerminalApprover(interactive: interactive, mode: .ask, input: { answer }, output: { err.add($0) })
        let code = await Mission.run(provider: provider, task: "t", folder: FileManager.default.temporaryDirectory,
                                     approver: approver, stdout: { out.add($0) }, stderr: { err.add($0) })
        return (code, out.value, err.value)
    }

    func testRunExitsOkOnDone() async {
        let (code, out, _) = await run(FakeProvider(events: [.code("hello\n")], final: .done("Answered")))
        XCTAssertEqual(code, .ok)
        XCTAssertTrue(out.contains("hello"))
        XCTAssertTrue(out.contains("Answered"))
    }

    func testRunExitsDeniedWhenAnythingWasDenied() async {
        let provider = FakeProvider(events: [.status("THINKING")], approval: ApprovalRequest(summary: "Allow Bash?", detail: "ls"),
                                    final: .done("Finished without it"))
        let (code, out, err) = await run(provider)
        XCTAssertEqual(code, .denied)
        XCTAssertEqual(code.rawValue, 3)
        XCTAssertTrue(out.contains("> skipped: denied"), out)
        XCTAssertTrue(err.contains("Allow Bash?"), err)
    }

    func testRunApprovedInteractivelyExitsOk() async {
        let provider = FakeProvider(events: [], approval: ApprovalRequest(summary: "Allow Bash?", detail: "ls"), final: .done("ok"))
        let (code, out, _) = await run(provider, interactive: true, answer: "y")
        XCTAssertEqual(code, .ok)
        XCTAssertTrue(out.contains("> approved"))
    }

    func testRunExitsFailedOnFailedEvent() async {
        let (code, _, err) = await run(FakeProvider(events: [.log("working")], final: .failed("boom")))
        XCTAssertEqual(code, .failed)
        XCTAssertTrue(err.contains("boom"), err)
    }

    func testRunWithoutFinalEventFails() async {
        struct Silent: AgentProvider {
            func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
                AsyncStream { $0.finish() }
            }
        }
        let (code, _, _) = await run(Silent())
        XCTAssertEqual(code, .failed)
    }

    func testRenderSeparatesLogCodeAndStatus() {
        XCTAssertEqual(render(.log("Read main.swift")).stdout, "> Read main.swift\n")
        XCTAssertNil(render(.log("x")).stderr)
        XCTAssertEqual(render(.code("let x = 1")).stdout, "let x = 1")
        XCTAssertNil(render(.code("x")).stderr)
        XCTAssertNil(render(.status("THINKING")).stdout)
        XCTAssertEqual(render(.status("THINKING")).stderr, "[THINKING]\n")
        XCTAssertEqual(render(.done("All good")).stdout, "Done: All good\n")
        XCTAssertEqual(render(.failed("Broken")).stderr, "Failed: Broken\n")
        XCTAssertNil(render(.failed("Broken")).stdout)
    }

    func testYesRoutineAndYoloAreExclusive() throws {
        XCTAssertThrowsError(try TristanCommand.parseAsRoot(["run", "--yes-routine", "--yolo", "do it"])) { error in
            XCTAssertEqual(CLI.exitCode(for: error), .usage)
        }
        let auto = try XCTUnwrap(TristanCommand.parseAsRoot(["run", "--yes-routine", "do it"]) as? RunCommand)
        XCTAssertEqual(auto.mode, .auto)
        let yolo = try XCTUnwrap(TristanCommand.parseAsRoot(["run", "--yolo", "do it"]) as? RunCommand)
        XCTAssertEqual(yolo.mode, .yolo)
    }

    func testRunDefaults() throws {
        let run = try XCTUnwrap(TristanCommand.parseAsRoot(["run", "say", "hello"]) as? RunCommand)
        XCTAssertEqual(run.mode, .ask)
        XCTAssertEqual(run.provider, .ollama)
        XCTAssertEqual(run.taskText, "say hello")
        XCTAssertEqual(run.folderURL.standardizedFileURL.path,
                       URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path)
        let claude = try XCTUnwrap(TristanCommand.parseAsRoot(["run", "--provider", "claude", "x"]) as? RunCommand)
        XCTAssertEqual(claude.provider, .claude)
    }

    func testUsageErrors() {
        for arguments in [["run", "--folder", "/nonexistent/tristan-\(UUID().uuidString)", "x"],
                          ["run", "--provider", "gpt", "x"],
                          ["run"],
                          ["frobnicate"]] {
            XCTAssertThrowsError(try TristanCommand.parseAsRoot(arguments), "\(arguments)") { error in
                XCTAssertEqual(CLI.exitCode(for: error), .usage, "\(arguments)")
            }
        }
        for arguments in [["--help"], ["run", "--help"], ["help", "run"]] {
            guard case .stop(let code, let message) = CLI.parse(arguments) else { return XCTFail("\(arguments) should print help") }
            XCTAssertEqual(code, .ok, "\(arguments)")
            XCTAssertTrue(message.contains("USAGE"), message)
        }
        guard case .stop(let code, _) = CLI.parse([]) else { return XCTFail("bare tristan should print help") }
        XCTAssertEqual(code, .usage)
        guard case .stop(let mixed, let message) = CLI.parse(["run", "--yolo", "--yes-routine", "x"]) else { return XCTFail() }
        XCTAssertEqual(mixed, .usage)
        XCTAssertTrue(message.contains("cannot be used together"), message)
        guard case .run(let command) = CLI.parse(["providers"]) else { return XCTFail() }
        XCTAssertTrue(command is ProvidersCommand)
    }

    func testEveryProviderIsMade() {
        XCTAssertEqual(CLIProvider.allCases.map(\.rawValue), ["claude", "copilot", "bedrock", "azure", "ollama"])
        XCTAssertTrue(CLIProvider.claude.make(mode: .ask) is ClaudeCodeProvider)
        XCTAssertTrue(CLIProvider.copilot.make(mode: .ask) is CopilotProvider)
        XCTAssertTrue(CLIProvider.bedrock.make(mode: .ask) is BedrockProvider)
        XCTAssertTrue(CLIProvider.azure.make(mode: .ask) is AzureOpenAIProvider)
        XCTAssertTrue(CLIProvider.ollama.make(mode: .ask) is OllamaProvider)
    }
}
