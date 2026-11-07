import XCTest
@testable import TristanCore

/// Plays back canned model responses and records every request the agent loop sends.
final class ScriptedClient: ConverseClient, @unchecked Sendable {
    private var responses: [[String: Any]]
    private(set) var requests: [[String: Any]] = []
    init(_ responses: [[String: Any]]) { self.responses = responses }

    func converse(_ request: [String: Any]) async throws -> [String: Any] {
        requests.append(request)
        guard !responses.isEmpty else { throw BedrockError(message: "script exhausted") }
        return responses.removeFirst()
    }

    static func toolUse(_ name: String, _ input: [String: Any], id: String = "t1") -> [String: Any] {
        ["output": ["message": ["role": "assistant", "content": [["toolUse": ["toolUseId": id, "name": name, "input": input]]]]],
         "stopReason": "tool_use"]
    }
    static func text(_ text: String) -> [String: Any] {
        ["output": ["message": ["role": "assistant", "content": [["text": text]]]], "stopReason": "end_turn"]
    }
}

final class BedrockTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// Runs the provider to completion; `answers` is consulted for each approval prompt.
    private func run(_ client: ScriptedClient, mode: ApprovalMode, allow: Bool = true) async -> (events: [AgentEvent], prompts: [ApprovalRequest]) {
        let prompts = PromptLog()
        let stream = BedrockProvider(mode: mode, client: client).run(task: "do it", workingDirectory: folder) { request in
            await prompts.add(request)
            return allow
        }
        var events: [AgentEvent] = []
        for await event in stream { events.append(event) }
        return (events, await prompts.all)
    }

    private func finalState(_ events: [AgentEvent]) -> String {
        for event in events.reversed() {
            if case .done = event { return "done" }
            if case .failed(let message) = event { return "failed: \(message)" }
        }
        return "none"
    }

    // MARK: sandbox

    func testSandboxBlocksPathsOutsideTheFolder() {
        let sandbox = ToolSandbox(root: folder)
        XCTAssertNotNil(sandbox.resolve("a/b.txt"))
        XCTAssertNil(sandbox.resolve("../escape.txt"))
        XCTAssertNil(sandbox.resolve("/etc/passwd"))
        XCTAssertTrue(sandbox.write("../escape.txt", content: "x").isError)
    }

    func testSandboxBlocksSymlinkEscape() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-outside-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertNil(ToolSandbox(root: folder).resolve("link/secret.txt"))
    }

    // MARK: agent loop

    func testAskModeDeniedWriteDoesNotTouchDisk() async throws {
        let client = ScriptedClient([ScriptedClient.toolUse("write_file", ["path": "a.txt", "content": "hi"]),
                                     ScriptedClient.text("I could not write it.")])
        let (events, prompts) = await run(client, mode: .ask, allow: false)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts.first?.summary, "Allow Write?")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.txt").path))
        XCTAssertEqual(finalState(events), "done")
        // The model must be told about the denial.
        let second = try XCTUnwrap(client.requests.last)
        let text = String(describing: second["messages"] ?? "")
        XCTAssertTrue(text.contains("denied"), "tool result should report the denial")
    }

    func testAskModeApprovedWriteCreatesFile() async throws {
        let client = ScriptedClient([ScriptedClient.toolUse("write_file", ["path": "sub/a.txt", "content": "hi"]),
                                     ScriptedClient.text("Done.")])
        let (events, prompts) = await run(client, mode: .ask)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("sub/a.txt"), encoding: .utf8), "hi")
        XCTAssertEqual(finalState(events), "done")
    }

    func testReadsNeverPrompt() async throws {
        try "hello".write(to: folder.appendingPathComponent("r.txt"), atomically: true, encoding: .utf8)
        let client = ScriptedClient([ScriptedClient.toolUse("read_file", ["path": "r.txt"]), ScriptedClient.text("ok")])
        let (_, prompts) = await run(client, mode: .ask)
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertTrue(String(describing: client.requests.last?["messages"] ?? "").contains("hello"))
    }

    func testAutoModeSkipsPromptForSafeButAsksForRiskyCommands() async throws {
        let safe = ScriptedClient([ScriptedClient.toolUse("run_command", ["command": "touch safe.txt"]), ScriptedClient.text("ok")])
        let (_, safePrompts) = await run(safe, mode: .auto)
        XCTAssertTrue(safePrompts.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("safe.txt").path))

        let risky = ScriptedClient([ScriptedClient.toolUse("run_command", ["command": "touch a.txt && touch b.txt"]), ScriptedClient.text("ok")])
        let (_, riskyPrompts) = await run(risky, mode: .auto, allow: false)
        XCTAssertEqual(riskyPrompts.count, 1, "chained commands must still ask in AUTO mode")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.txt").path))
    }

    func testYoloModeNeverPrompts() async throws {
        let client = ScriptedClient([ScriptedClient.toolUse("run_command", ["command": "touch a.txt && touch b.txt"]), ScriptedClient.text("ok")])
        let (_, prompts) = await run(client, mode: .yolo)
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("b.txt").path))
    }

    func testWriteOutsideFolderIsRefusedWithoutPrompt() async throws {
        let client = ScriptedClient([ScriptedClient.toolUse("write_file", ["path": "../evil.txt", "content": "x"]), ScriptedClient.text("ok")])
        let (events, prompts) = await run(client, mode: .yolo)
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
        XCTAssertEqual(finalState(events), "done")
        XCTAssertTrue(String(describing: client.requests.last?["messages"] ?? "").contains("outside the working folder"))
    }

    func testClientErrorBecomesFailedEvent() async {
        let (events, _) = await run(ScriptedClient([]), mode: .ask)
        XCTAssertTrue(finalState(events).hasPrefix("failed"))
    }

    func testLoopStopsAfterMaxTurns() async {
        let loop = ScriptedClient((0..<5).map { _ in ScriptedClient.toolUse("list_dir", ["path": "."]) })
        let stream = BedrockProvider(mode: .ask, client: loop, maxTurns: 3).run(task: "x", workingDirectory: folder) { _ in true }
        var last: AgentEvent?
        for await event in stream { last = event }
        if case .failed(let message)? = last { XCTAssertTrue(message.contains("3 turns")) } else { XCTFail("expected failure") }
    }

    // MARK: rules and errors

    func testAlwaysAllowRulesAreNarrow() {
        let dir = folder!
        XCTAssertNotNil(ApprovalRule.make(tool: "Bash", input: ["command": "npm test"], workingDirectory: dir))
        XCTAssertNil(ApprovalRule.make(tool: "Bash", input: ["command": "npm test && rm -rf ."], workingDirectory: dir))
        XCTAssertNil(ApprovalRule.make(tool: "Bash", input: ["command": "rm file"], workingDirectory: dir))
        XCTAssertNil(ApprovalRule.make(tool: "Bash", input: ["command": "echo hi > x"], workingDirectory: dir))
        XCTAssertNotNil(ApprovalRule.make(tool: "Write", input: ["file_path": dir.appendingPathComponent("a.txt").path], workingDirectory: dir))
        XCTAssertNil(ApprovalRule.make(tool: "Write", input: ["file_path": "/etc/hosts"], workingDirectory: dir))
        XCTAssertNil(ApprovalRule.make(tool: "WebFetch", input: ["url": "https://example.com"], workingDirectory: dir))
    }

    func testAWSErrorsAreExplained() {
        XCTAssertTrue(AWSCLIConverseClient.explain(stderr: "An error occurred (ExpiredTokenException)").contains("expired"))
        XCTAssertTrue(AWSCLIConverseClient.explain(stderr: "An error occurred (AccessDeniedException)").contains("denied"))
    }
}

actor PromptLog {
    private(set) var all: [ApprovalRequest] = []
    func add(_ request: ApprovalRequest) { all.append(request) }
}

final class SafePathTests: XCTestCase {
    func testDanglingSymlinkIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-dangle-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("dangling"),
                                                   withDestinationURL: URL(fileURLWithPath: "/tmp/tristan-does-not-exist-\(UUID().uuidString)"))
        XCTAssertNil(ToolSandbox(root: dir).resolve("dangling"))
        XCTAssertNil(ApprovalRule.make(tool: "Write", input: ["file_path": dir.appendingPathComponent("dangling").path], workingDirectory: dir))
    }

    func testSymlinkedFolderRuleDoesNotEscape() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-rule-\(UUID().uuidString.prefix(8))")
        let work = base.appendingPathComponent("work"), outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertNil(ApprovalRule.make(tool: "Write", input: ["file_path": work.appendingPathComponent("link/x.txt").path], workingDirectory: work))
    }
}
