import XCTest
@testable import TristanCore

final class ShellRunnerTests: XCTestCase {
    func testPosixCommand() {
        let command = ShellRunner.command(for: "echo hi", flavor: .posix)
        XCTAssertEqual(command.tool, "/bin/zsh")
        XCTAssertEqual(command.arguments, ["-c", "echo hi"])
    }

    func testPowerShellCommandArguments() {
        let expected = ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "Get-Date"]
        let withPwsh = ShellRunner.command(for: "Get-Date", flavor: .powershell, isAvailable: { $0 == "pwsh" })
        XCTAssertEqual(withPwsh.tool, "pwsh")
        XCTAssertEqual(withPwsh.arguments, expected)
        let without = ShellRunner.command(for: "Get-Date", flavor: .powershell, isAvailable: { _ in false })
        XCTAssertEqual(without.tool, "powershell.exe")
        XCTAssertEqual(without.arguments, expected)
    }

    func testToolSpecNamesTheShell() {
        XCTAssertTrue(AgentToolSpec.shellDescription(for: .posix).contains("zsh"))
        XCTAssertTrue(AgentToolSpec.shellDescription(for: .powershell).contains("PowerShell"))
        XCTAssertEqual(ShellFlavor.posix.ruleToolName, "Bash")
        XCTAssertEqual(ShellFlavor.powershell.ruleToolName, "PowerShell")
        #if os(macOS)
        let run = AgentToolSpec.definitions.first { $0.name == "run_command" }
        XCTAssertNotNil(run)
        XCTAssertTrue(run?.description.contains("zsh") ?? false)
        #endif
    }

    #if os(macOS)
    func testRunCommandCapturesOutputAndExitStatus() async {
        let sandbox = ToolSandbox(root: FileManager.default.temporaryDirectory)
        let ok = await sandbox.run("echo hi")
        XCTAssertTrue(ok.text.contains("hi"))
        XCTAssertTrue(ok.text.contains("[exit status 0]"))
        XCTAssertFalse(ok.isError)
        let bad = await sandbox.run("exit 3")
        XCTAssertTrue(bad.isError)
        XCTAssertTrue(bad.text.contains("[exit status 3]"))
    }
    #endif
}
