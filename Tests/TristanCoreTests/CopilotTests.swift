import XCTest
@testable import TristanCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class CopilotTests: XCTestCase {
    /// `script` runs in /bin/sh; on Windows `windows` runs in Windows PowerShell instead.
    private func run(mode: ApprovalMode, script: String, windows: String? = nil, allow: Bool = true) async -> (events: [AgentEvent], prompts: [ApprovalRequest]) {
        var provider = CopilotProvider(mode: mode, model: "")
        #if os(Windows)
        let shell = ProcessLauncher.locate("powershell") ?? "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
        let command = windows ?? script
        provider.launchOverride = { _ in (URL(fileURLWithPath: shell), ["-NoProfile", "-NonInteractive", "-Command", command]) }
        #else
        provider.launchOverride = { _ in (URL(fileURLWithPath: "/bin/sh"), ["-c", script]) }
        #endif
        let prompts = PromptLog()
        let stream = provider.run(task: "t", workingDirectory: FileManager.default.temporaryDirectory) { request in
            await prompts.add(request); return allow
        }
        var events: [AgentEvent] = []
        for await event in stream { events.append(event) }
        return (events, await prompts.all)
    }

    // MARK: permission mapping

    func testYoloAllowsEverythingWithNoDenyRules() {
        let args = CopilotArguments.make(task: "x", mode: .yolo, model: "")
        XCTAssertTrue(args.contains("--allow-all-tools"))
        XCTAssertFalse(args.contains("--deny-tool"))
    }

    func testAskAllowsAllToolsButStillDeniesDangerousCommands() {
        let args = CopilotArguments.make(task: "x", mode: .ask, model: "")
        XCTAssertTrue(args.contains("--allow-all-tools"))
        for command in ["rm", "sudo", "curl", "git push"] {
            XCTAssertTrue(args.contains("shell(\(command):*)"), "\(command) should be denied")
        }
    }

    func testAutoNeverUsesAllowAllTools() {
        let args = CopilotArguments.make(task: "x", mode: .auto, model: "")
        XCTAssertFalse(args.contains("--allow-all-tools"))
        XCTAssertTrue(args.contains("write"))
        XCTAssertTrue(args.contains("shell(git status:*)"))
        XCTAssertTrue(args.contains("shell(rm:*)"), "deny list still applies")
        // Deny rules must not also appear as allow rules.
        let allowed = zip(args, args.dropFirst()).filter { $0.0 == "--allow-tool" }.map { $0.1 }
        for denied in CopilotArguments.deniedShell { XCTAssertFalse(allowed.contains("shell(\(denied):*)")) }
    }

    func testModelAndPromptArePassedThrough() {
        let args = CopilotArguments.make(task: "do the thing", mode: .yolo, model: "gpt-5")
        XCTAssertEqual(args[0], "-p"); XCTAssertEqual(args[1], "do the thing")
        XCTAssertTrue(zip(args, args.dropFirst()).contains { $0.0 == "--model" && $0.1 == "gpt-5" })
    }

    func testEachRunCanBeGivenItsOwnLogDirectory() {
        XCTAssertFalse(CopilotArguments.make(task: "x", mode: .ask, model: "").contains("--log-dir"))
        let args = CopilotArguments.make(task: "x", mode: .ask, model: "", logDirectory: "/tmp/run-1")
        XCTAssertTrue(zip(args, args.dropFirst()).contains { $0.0 == "--log-dir" && $0.1 == "/tmp/run-1" })
    }

    func testANSIIsStripped() {
        XCTAssertEqual(CopilotArguments.stripANSI("\u{001B}[32mgreen\u{001B}[0m text"), "green text")
    }

    // MARK: Windows (plan Task 15)

    func testStripANSIHandlesCRLF() {
        XCTAssertEqual(CopilotArguments.stripANSI("\u{001B}[32mok\u{001B}[0m\r\n"), "ok")
        XCTAssertEqual(CopilotArguments.stripANSI("line one\r\nline two\r\n"), "line one\nline two")
        XCTAssertEqual(CopilotArguments.stripANSI("no carriage return\n"), "no carriage return\n", "unchanged without a CR")
    }

    /// A lone CR returns to the start of the line, as in a terminal: only what follows the last one is kept.
    func testStripANSIKeepsTextAfterTheLastLoneCR() {
        XCTAssertEqual(CopilotArguments.stripANSI("progress\rdone"), "done")
        XCTAssertEqual(CopilotArguments.stripANSI("Thinking…\rDone"), "Done")
        XCTAssertEqual(CopilotArguments.stripANSI("10%\r50%\r100%\r\n"), "100%")
        XCTAssertEqual(CopilotArguments.stripANSI("a\rb\nc\rd\r\ne"), "b\nd\ne")
        XCTAssertEqual(CopilotArguments.stripANSI("\u{001B}[2KThinking\r\u{001B}[2KAnswer\r\n"), "Answer")
        XCTAssertEqual(CopilotArguments.stripANSI("line one\r\nline two\r\n"), "line one\nline two", "CRLF is still a line end")
        XCTAssertEqual(CopilotArguments.stripANSI("shown\r"), "shown", "a CR with nothing after it overwrites nothing")
        XCTAssertEqual(CopilotArguments.stripANSI("old\r\rnew"), "new")
    }

    func testUnsafeTaskOnCmdShimIsRefusedWithMessage() async {
        var provider = CopilotProvider(mode: .yolo, model: "")
        let launched = Counter()
        provider.prepare = { tool, _, _, _ in
            launched.add()
            throw UnsafeArguments(tool: tool)
        }
        var events: [AgentEvent] = []
        for await event in provider.run(task: "fix a & b", workingDirectory: FileManager.default.temporaryDirectory, approve: { _ in true }) {
            events.append(event)
        }
        XCTAssertEqual(launched.value, 1)
        XCTAssertFalse(events.contains { if case .status("ONLINE") = $0 { return true } else { return false } }, "nothing may start")
        guard case .failed(let message)? = events.last else { return XCTFail("expected a failure, got \(events)") }
        XCTAssertEqual(message, "Could not launch the Copilot CLI safely: refusing to pass text containing % ^ & | < > \" or a line break "
                       + "to copilot through cmd.exe. Remove those characters from the task and retry.")
    }

    func testNotFoundMessageOnWindows() {
        let windows = CopilotProvider.launchFailure(ToolNotFound(name: "copilot"), windows: true)
        XCTAssertTrue(windows.contains("npm install -g @github/copilot"), windows)
        XCTAssertTrue(windows.contains("Node.js"), windows)
        XCTAssertEqual(CopilotProvider.launchFailure(ToolNotFound(name: "copilot"), windows: false),
                       "Could not launch the Copilot CLI: copilot was not found on PATH. Install it with `npm install -g @github/copilot`.")
    }

    func testLogFolderCreationDoesNotNeedPosixPermissions() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-copilot-logs-test-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: base) }
        try ProcessLauncher.createPrivateFolder(base, windows: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.createFile(atPath: base.appendingPathComponent("session.log").path, contents: Data("x".utf8)))
    }

    // MARK: process handling

    func testAskModeRequiresUpFrontApprovalAndDenialStopsTheRun() async {
        let (events, prompts) = await run(mode: .ask, script: "echo should-not-run", allow: false)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertFalse(events.contains { if case .code = $0 { return true } else { return false } }, "nothing may run after a denial")
        if case .failed? = events.last {} else { XCTFail("expected a failure event") }
    }

    func testOutputStreamsAndSuccessFinishes() async {
        let (events, prompts) = await run(mode: .yolo, script: "echo first; echo; echo final answer",
                                             windows: "Write-Output first; Write-Output ''; Write-Output 'final answer'")
        XCTAssertTrue(prompts.isEmpty)
        let code = events.compactMap { event -> String? in if case .code(let text) = event { return text } else { return nil } }.joined()
        XCTAssertTrue(code.contains("first") && code.contains("final answer"))
        if case .done(let summary)? = events.last { XCTAssertTrue(summary.contains("final answer")) } else { XCTFail("expected done") }
    }

    func testNonZeroExitReportsStderr() async {
        let (events, _) = await run(mode: .yolo, script: "echo 'not logged in' 1>&2; exit 3",
                                      windows: "[Console]::Error.WriteLine('not logged in'); exit 3")
        if case .failed(let message)? = events.last { XCTAssertTrue(message.contains("not logged in")) } else { XCTFail("expected failure") }
    }
}
