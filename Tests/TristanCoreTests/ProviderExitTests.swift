#if os(macOS)
import XCTest
@testable import TristanCore

/// Each provider path that starts a program finishes when the program exits and maps its exit status (fake programs
/// written as shell scripts; the Windows fakes in scripts/ci/fakes cover the same paths on Windows).
final class ProviderExitTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("exit-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// An executable shell script named `name` in the test folder.
    @discardableResult
    private func script(_ name: String, _ body: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func events(_ provider: AgentProvider) async -> [AgentEvent] {
        var all: [AgentEvent] = []
        for await event in provider.run(task: "x", workingDirectory: folder, approve: { _ in false }) { all.append(event) }
        return all
    }

    func testClaudeExitStatusIsMapped() async throws {
        var provider = ClaudeCodeProvider(mode: .yolo)
        provider.claudeTool = try script("fake-claude-fail", "echo 'not json'; exit 3").path
        let start = Date()
        var all = await events(provider)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        guard case .failed(let message)? = all.last else { return XCTFail("\(all)") }
        XCTAssertEqual(message, "claude exited with status 3")

        provider.claudeTool = try script("fake-claude-ok", "exit 0").path
        all = await events(provider)
        guard case .done(let text)? = all.last else { return XCTFail("\(all)") }
        XCTAssertEqual(text, "Complete")
    }

    func testCopilotExitStatusIsMapped() async throws {
        let failing = try script("fake-copilot", "echo 'not logged in' 1>&2; exit 4")
        let provider = CopilotProvider(mode: .yolo, model: "", launchOverride: { args in (failing, args) })
        let all = await events(provider)
        guard case .failed(let message)? = all.last else { return XCTFail("\(all)") }
        XCTAssertEqual(message, "not logged in")
        let succeeding = try script("fake-copilot-ok", "echo answer; exit 0")
        let ok = await events(CopilotProvider(mode: .yolo, model: "", launchOverride: { args in (succeeding, args) }))
        guard case .done? = ok.last else { return XCTFail("\(ok)") }
    }

    func testAzureToolStatusAndOutputAreReturned() throws {
        let fake = try script("fake-az", "echo token-text; exit 4")
        let result = try AzureAuth.runTool(fake.path, ["account"])
        XCTAssertEqual(result.status, 4)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "token-text\n")
        let ok = try AzureAuth.runTool(try script("fake-az-ok", "printf tok").path, [])
        XCTAssertEqual(ok.status, 0)
        XCTAssertEqual(String(decoding: ok.output, as: UTF8.self), "tok")
    }

    // `aws configure export-credentials` is not faked here: on the Mac the launcher puts /opt/homebrew/bin and
    // /usr/local/bin before PATH, so a fake on PATH would lose to a real AWS CLI (and read real credentials). The fake
    // `aws` in scripts/ci/fakes covers that path on Windows (testBedrockCredentialsFromFakeAWSWithCRLF,
    // testBedrockErrorsFromTheCLIAreExplained).
}
#endif
