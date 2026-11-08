import XCTest
@testable import TristanCore

/// Claude Code on Windows (plan Task 16). The MCP config tests (token in `env`, TCP endpoint) live in
/// ApprovalTransportTests (ruling R6).
final class ClaudeProviderTests: XCTestCase {
    func testStreamParserToleratesCRLFLines() {
        let lines = [
            "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s1\"}\r",
            "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Hi there\"}]}}\r\n",
            "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"All done\"}\r",
        ]
        let events = lines.flatMap(ClaudeStream.parse)
        XCTAssertEqual(events.count, 4, "\(events)")
        guard events.count == 4 else { return }
        if case .log(let text) = events[0] { XCTAssertEqual(text, "Session started") } else { XCTFail("\(events[0])") }
        if case .code(let text) = events[2] { XCTAssertEqual(text, "Hi there\n") } else { XCTFail("\(events[2])") }
        if case .done(let text) = events[3] { XCTAssertEqual(text, "All done") } else { XCTFail("\(events[3])") }
        XCTAssertTrue(ClaudeStream.parse("\r\n").isEmpty)
    }

    func testInitReportsTheModelWhenTheCLISaysWhich() {
        let events = ClaudeStream.parse("{\"type\":\"system\",\"subtype\":\"init\",\"model\":\"claude-sonnet-x\"}")
        XCTAssertEqual(events.count, 2, "\(events)")
        guard events.count == 2, case .model(let name) = events[1] else { return XCTFail("\(events)") }
        XCTAssertEqual(name, "claude-sonnet-x")
        XCTAssertEqual(ClaudeStream.parse("{\"type\":\"system\",\"subtype\":\"init\",\"model\":\"\"}").count, 1)
    }

    func testClaudeNotFoundMessageMentionsGitForWindows() {
        let windows = ClaudeCodeProvider.launchFailure(ToolNotFound(name: "claude"), windows: true)
        XCTAssertTrue(windows.hasPrefix("Could not launch claude: claude was not found on PATH."), windows)
        XCTAssertTrue(windows.contains("Git for Windows"), windows)
        XCTAssertTrue(windows.contains("winget install -e --id Git.Git"), windows)
        XCTAssertTrue(windows.contains("npm install -g @anthropic-ai/claude-code"), windows)
        // The Mac wording is unchanged.
        XCTAssertEqual(ClaudeCodeProvider.launchFailure(ToolNotFound(name: "claude"), windows: false),
                       "Could not launch claude: claude was not found on PATH")
        XCTAssertEqual(ClaudeCodeProvider.launchFailure(UnsafeArguments(tool: "claude"), windows: true),
                       "Could not launch claude safely: refusing to pass text containing % ^ & | < > \" or a line break to claude "
                       + "through cmd.exe. Remove those characters from the task and retry.")
    }

    func testMissingClaudeFailsWithTheMessage() async {
        var provider = ClaudeCodeProvider(mode: .yolo)
        provider.claudeTool = "tristan-no-such-claude-\(UUID().uuidString.prefix(8))"
        var last: AgentEvent?
        for await event in provider.run(task: "x", workingDirectory: FileManager.default.temporaryDirectory, approve: { _ in false }) {
            last = event
        }
        guard case .failed(let message)? = last else { return XCTFail("expected a failure, got \(String(describing: last))") }
        XCTAssertTrue(message.hasPrefix("Could not launch claude: tristan-no-such-claude-"), message)
        #if os(Windows)
        XCTAssertTrue(message.contains("Git for Windows"), message)
        #endif
    }
}
