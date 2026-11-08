#if os(Windows)
import XCTest
@testable import TristanCore
@testable import TristanCLICore

/// `tristan run --provider <x>` through the command-line library on Windows, against the fake provider CLIs in
/// scripts/ci/fakes: output is streamed, approvals are answered in `ask` mode, exit codes are right, and cancelling
/// stops the provider's whole process tree. For Claude Code the approval shim is the built `tristan.exe`, so a
/// permission request travels fake claude → `tristan --mcp-permission` (MCP over stdio, tokens from the config's `env`
/// block) → loopback TCP → this run's terminal approver.
final class WindowsRunTests: XCTestCase {
    private var folder: URL!
    private var scratch: URL!
    private var fakes: FakeCLIs!
    private var savedBackend: SettingsBackend!
    private var savedNoKeychain = false

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-winrun-\(UUID().uuidString.prefix(8))", isDirectory: true)
        folder = base.appendingPathComponent("work", isDirectory: true)
        scratch = base.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        fakes = FakeCLIs()
        savedBackend = Settings.backend
        Settings.backend = MemoryBackend()
        savedNoKeychain = NoKeychain.enabled
        NoKeychain.enabled = true
    }

    override func tearDown() {
        fakes.restore()
        Settings.backend = savedBackend
        NoKeychain.enabled = savedNoKeychain
        Terminal.capture = nil
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    /// The `tristan.exe` that `swift build`/`swift test` built next to the tests (or `TRISTAN_EXE`).
    private func tristanExe() throws -> String {
        var candidates: [String] = []
        if let given = ProcessInfo.processInfo.environment["TRISTAN_EXE"] { candidates.append(given) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for folder in ["x86_64-unknown-windows-msvc", "aarch64-unknown-windows-msvc", ""] {
            var url = repo.appendingPathComponent(".build")
            if !folder.isEmpty { url = url.appendingPathComponent(folder) }
            candidates.append(FakeCLIs.native(url.appendingPathComponent("debug").appendingPathComponent("tristan.exe")))
        }
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            XCTFail("tristan.exe was not built; looked in \(candidates)")
            throw XCTSkip("no tristan.exe")
        }
        return found
    }

    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [String]
        private(set) var asked = 0
        init(_ answers: [String]) { queue = answers }
        func next() -> String? {
            lock.lock(); defer { lock.unlock() }
            asked += 1
            return queue.isEmpty ? nil : queue.removeFirst()
        }
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func add(_ s: String) { lock.lock(); text += s; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }

    /// Parses `arguments` as the command line does and runs the command; returns the exit code and stdout.
    private func run(_ arguments: [String], interactive: Bool = true, answers: Answers = Answers([]),
                     makeProvider: ((CLIProvider, ApprovalMode) -> AgentProvider)? = nil) async throws -> (ExitCode, String) {
        let command = try XCTUnwrap(TristanCommand.parseAsRoot(["run", "--folder", FakeCLIs.native(folder)] + arguments) as? RunCommand)
        var environment = CLIEnvironment(interactive: interactive, readPIN: { _ in nil },
                                         makeProvider: makeProvider ?? { $0.make(mode: $1) }, installInterrupt: false,
                                         historyURL: scratch.appendingPathComponent("history.json"),
                                         sessions: SessionRegistry(directory: scratch.appendingPathComponent("sessions"), isAlive: { _ in true }))
        environment.readAnswer = { answers.next() }
        let out = Sink()
        Terminal.capture = { out.add($0) }
        defer { Terminal.capture = nil }
        let code = await command.execute(environment: environment)
        return (code, out.value)
    }

    private var hello: URL { folder.appendingPathComponent("hello.txt") }
    private func helloText() -> String? { try? String(contentsOf: hello, encoding: .utf8) }

    // MARK: - Claude Code

    private func claudeWithBuiltShim() throws -> (CLIProvider, ApprovalMode) -> AgentProvider {
        let exe = try tristanExe()
        return { _, mode in
            var claude = ClaudeCodeProvider(mode: mode)
            claude.shimCommand = exe
            return claude
        }
    }

    func testClaudeAskApprovedThroughTheRealShim() async throws {
        let answers = Answers(["y"])
        let (code, out) = try await run(["--provider", "claude", "create hello.txt with hi"], answers: answers,
                                        makeProvider: try claudeWithBuiltShim())
        XCTAssertEqual(code, .ok, out)
        XCTAssertEqual(answers.asked, 1, "exactly one approval prompt")
        XCTAssertEqual(helloText(), "hi")
        XCTAssertTrue(out.contains("Task: create hello.txt with hi"), out)
        XCTAssertTrue(out.contains("Done: created hello.txt"), out)
    }

    func testClaudeAskDeniedThroughTheRealShim() async throws {
        let answers = Answers(["n"])
        let (code, out) = try await run(["--provider", "claude", "create hello.txt with hi"], answers: answers,
                                        makeProvider: try claudeWithBuiltShim())
        XCTAssertEqual(code, .denied, out)
        XCTAssertEqual(answers.asked, 1)
        XCTAssertNil(helloText())
        XCTAssertTrue(out.contains("did not create hello.txt: Denied by the operator in Tristan."), out)
    }

    func testClaudeAskWithNoTerminalDenies() async throws {
        let answers = Answers(["y"])
        let (code, out) = try await run(["--provider", "claude", "create hello.txt with hi"], interactive: false, answers: answers,
                                        makeProvider: try claudeWithBuiltShim())
        XCTAssertEqual(code, .denied, out)
        XCTAssertEqual(answers.asked, 0, "no terminal: nobody is asked")
        XCTAssertNil(helloText())
    }

    func testClaudeYesRoutineNeedsNoPrompt() async throws {
        let answers = Answers([])
        let (code, out) = try await run(["--provider", "claude", "--yes-routine", "create hello.txt with hi"], answers: answers)
        XCTAssertEqual(code, .ok, out)
        XCTAssertEqual(answers.asked, 0)
        XCTAssertEqual(helloText(), "hi")
    }

    func testClaudeFailureExitsFailed() async throws {
        let (code, _) = try await run(["--provider", "claude", "--yolo", "please fail"])
        XCTAssertEqual(code, .failed)
    }

    // MARK: - Copilot

    func testCopilotAskApprovedStreamsOutput() async throws {
        let answers = Answers(["yes"])
        let (code, out) = try await run(["--provider", "copilot", #"list "the" files & 100%"#], answers: answers)
        XCTAssertEqual(code, .ok, out)
        XCTAssertEqual(answers.asked, 1)
        XCTAssertTrue(out.contains(#"TASK<list "the" files & 100%>"#), out)
        XCTAssertTrue(out.contains("Done: ") && out.contains("Final answer: hello from fake copilot\n"), out)
        XCTAssertFalse(out.contains("\r") || out.contains("\u{1B}"), out.debugDescription)
    }

    func testCopilotAskDeniedExitsDenied() async throws {
        let (code, out) = try await run(["--provider", "copilot", "list files"], answers: Answers(["n"]))
        XCTAssertEqual(code, .denied, out)
        XCTAssertFalse(out.contains("TASK<"), out)
    }

    func testCopilotYesRoutineAndFailure() async throws {
        let (ok, out) = try await run(["--provider", "copilot", "--yes-routine", "list files"])
        XCTAssertEqual(ok, .ok, out)
        XCTAssertTrue(out.contains("tools: limited"), out)
        let (failed, _) = try await run(["--provider", "copilot", "--yolo", "please fail"])
        XCTAssertEqual(failed, .failed)
    }

    // MARK: - Bedrock (the standard provider: streaming first, then the aws CLI)

    func testBedrockAskApprovedThroughTheAWSCLI() async throws {
        fakes.set("FAKE_AWS_NO_CREDENTIALS", "1")   // streaming cannot sign, so the CLI fallback answers
        let answers = Answers(["y"])
        let (code, out) = try await run(["--provider", "bedrock", "write hello.txt"], answers: answers)
        XCTAssertEqual(code, .ok, out)
        XCTAssertEqual(answers.asked, 1)
        XCTAssertEqual(helloText(), "hi from bedrock")
        XCTAssertTrue(out.contains("Bedrock fake: finished after the tool ran."), out)
    }

    func testBedrockAskDeniedExitsDenied() async throws {
        fakes.set("FAKE_AWS_NO_CREDENTIALS", "1")
        let (code, out) = try await run(["--provider", "bedrock", "write hello.txt"], answers: Answers(["n"]))
        XCTAssertEqual(code, .denied, out)
        XCTAssertNil(helloText())
    }

    func testBedrockBadModelExitsFailed() async throws {
        fakes.set("FAKE_AWS_NO_CREDENTIALS", "1")
        Settings.set("bad-model", forKey: "bedrock.model")
        let (code, _) = try await run(["--provider", "bedrock", "--yolo", "say hi"])
        XCTAssertEqual(code, .failed)
    }

    // MARK: - Azure OpenAI (the az token from the fake az.cmd; HTTP answered in-process)

    func testAzureAskApprovedWithTheAzToken() async throws {
        let answers = Answers(["y"])
        let (code, out) = try await run(["--provider", "azure", "write hello.txt"], answers: answers, makeProvider: { _, mode in
            AzureOpenAIProvider(mode: mode, client: AzureStub.start())
        })
        defer { AzureStub.stop() }
        XCTAssertEqual(code, .ok, out)
        XCTAssertEqual(answers.asked, 1)
        XCTAssertEqual(helloText(), "hi from azure")
        XCTAssertEqual(AzureStub.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fake-az-token-0123456789")
    }

    // MARK: - providers

    func testProvidersFindsTheFakes() async {
        for provider in [CLIProvider.claude, .copilot, .bedrock] {
            let problem = await ProvidersCommand.problem(provider)
            XCTAssertNil(problem, provider.rawValue)
        }
        Settings.set("https://stub-resource.openai.azure.com", forKey: "azure.endpoint")
        Settings.set("gpt-stub", forKey: "azure.deployment")
        let azure = await ProvidersCommand.problem(.azure)
        XCTAssertNil(azure, "az.cmd counts as a way to sign in on Windows")
    }

    // MARK: - Cancel

    /// Cancelling `tristan run` (what Ctrl+C does) stops the fake and the child it started.
    func testCancelStopsTheProviderTree() async throws {
        for provider in ["copilot", "claude"] {
            let pidFile = scratch.appendingPathComponent("pids-\(provider).txt")
            fakes.set("FAKE_PID_FILE", FakeCLIs.native(pidFile))
            let work = Task { try await self.run(["--provider", provider, "--yolo", "sleep"]) }
            XCTAssertTrue(FakeCLIs.eventually(20) { FakeCLIs.pids(in: pidFile) != nil }, "\(provider): the fake never wrote its pids")
            let pids = try XCTUnwrap(FakeCLIs.pids(in: pidFile))
            XCTAssertTrue(pids.allSatisfy(FakeCLIs.isAlive), provider)
            work.cancel()
            let (code, _) = try await work.value
            XCTAssertEqual(code, .failed, provider)
            XCTAssertTrue(FakeCLIs.eventually(10) { !pids.contains(where: FakeCLIs.isAlive) },
                          "\(provider): still running after cancel: \(pids.filter(FakeCLIs.isAlive))")
        }
    }
}
#endif
