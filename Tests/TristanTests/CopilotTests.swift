import XCTest
@testable import Tristan

final class CopilotTests: XCTestCase {
    private func run(mode: ApprovalMode, script: String, allow: Bool = true) async -> (events: [AgentEvent], prompts: [ApprovalRequest]) {
        var provider = CopilotProvider(mode: mode, model: "")
        provider.launchOverride = { _ in (URL(fileURLWithPath: "/bin/sh"), ["-c", script]) }
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

    func testANSIIsStripped() {
        XCTAssertEqual(CopilotArguments.stripANSI("\u{001B}[32mgreen\u{001B}[0m text"), "green text")
    }

    // MARK: process handling

    func testAskModeRequiresUpFrontApprovalAndDenialStopsTheRun() async {
        let (events, prompts) = await run(mode: .ask, script: "echo should-not-run", allow: false)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertFalse(events.contains { if case .code = $0 { return true } else { return false } }, "nothing may run after a denial")
        if case .failed? = events.last {} else { XCTFail("expected a failure event") }
    }

    func testOutputStreamsAndSuccessFinishes() async {
        let (events, prompts) = await run(mode: .yolo, script: "echo first; echo; echo final answer")
        XCTAssertTrue(prompts.isEmpty)
        let code = events.compactMap { event -> String? in if case .code(let text) = event { return text } else { return nil } }.joined()
        XCTAssertTrue(code.contains("first") && code.contains("final answer"))
        if case .done(let summary)? = events.last { XCTAssertTrue(summary.contains("final answer")) } else { XCTFail("expected done") }
    }

    func testNonZeroExitReportsStderr() async {
        let (events, _) = await run(mode: .yolo, script: "echo 'not logged in' 1>&2; exit 3")
        if case .failed(let message)? = events.last { XCTAssertTrue(message.contains("not logged in")) } else { XCTFail("expected failure") }
    }
}
