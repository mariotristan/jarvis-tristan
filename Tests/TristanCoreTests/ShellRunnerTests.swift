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

    /// A child that left the process tree (its parent exited, so it was reparented and the tree kill cannot see it)
    /// still holds the output pipe: run_command stops reading shortly after the command is stopped and says so.
    func testRunCommandReturnsWhenAnEscapedChildHoldsThePipe() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("escape-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            for name in ["timeout.pid", "exited.pid"] {
                if let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8),
                   let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
            }
            try? FileManager.default.removeItem(at: folder)
        }
        let sandbox = ToolSandbox(root: folder)

        // On timeout: the command is stopped, the escaped child keeps the pipe open for 20 s.
        var start = Date()
        let stopped = await sandbox.run("echo before; (sleep 20 & echo $! > timeout.pid); sleep 20", timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 8, stopped.text)
        XCTAssertTrue(stopped.text.hasPrefix("before\n"), stopped.text)
        XCTAssertTrue(stopped.text.contains("\n[output truncated: a process the command started did not exit]\n[exit status "),
                      stopped.text)
        XCTAssertTrue(stopped.isError)

        // The command exits by itself and leaves the child behind: its own status is kept.
        start = Date()
        let left = await sandbox.run("echo started; (sleep 20 & echo $! > exited.pid)")
        XCTAssertLessThan(Date().timeIntervalSince(start), 8, left.text)
        XCTAssertEqual(left.text, "started\n\n[output truncated: a process the command started did not exit]\n[exit status 0]")
        XCTAssertFalse(left.isError)

        // A normal command is unchanged.
        let ok = await sandbox.run("printf 'a\\nb'")
        XCTAssertEqual(ok.text, "a\nb\n[exit status 0]")
    }
    #endif

    func testSystemPromptPerPlatform() {
        XCTAssertEqual(AgentLoop.systemPrompt(for: .posix), "You are Tristan, a coding agent working in a single project folder on the user's Mac. Use the tools to read, list and write files and to run shell commands. All paths are relative to the working folder. Look before you change things, keep edits small, and run tests when they exist. If a tool call is denied, do not try to work around the denial; explain what you could not do. When finished, reply with a short summary of what you changed.")
        XCTAssertEqual(AgentLoop.systemPrompt(for: nil), "You are Tristan, a coding assistant working in a single folder on the user's iPhone or iPad. Use the tools to read, list and write files. You cannot run commands or tests on this device, so say so if the task needs them. All paths are relative to the working folder. Look before you change things and keep edits small. If a tool call is denied, do not try to work around the denial; explain what you could not do. When finished, reply with a short summary of what you changed.")
        let windows = AgentLoop.systemPrompt(for: .powershell)
        XCTAssertTrue(windows.contains("PowerShell"))
        XCTAssertFalse(windows.contains("zsh"))
        XCTAssertFalse(windows.contains("cannot run commands"))
        #if os(macOS)
        XCTAssertEqual(AgentLoop.systemPrompt, AgentLoop.systemPrompt(for: .posix))
        #endif
    }

    func testPrepareWithoutToolPathsKeepsInheritedEnvironment() throws {
        let inherited = try ProcessLauncher.prepare("echo", ["hi"], directory: nil, extraEnvironment: [:], addToolPaths: false)
        XCTAssertNil(inherited.environment)
        let withExtra = try ProcessLauncher.prepare("echo", ["hi"], directory: nil, extraEnvironment: ["TRISTAN_X": "1"], addToolPaths: false)
        XCTAssertEqual(withExtra.environment?["PATH"], ProcessInfo.processInfo.environment["PATH"])
        XCTAssertEqual(withExtra.environment?["TRISTAN_X"], "1")
        #if !os(Windows)
        let providers = try ProcessLauncher.prepare("echo", ["hi"], directory: nil, extraEnvironment: [:])
        XCTAssertTrue(providers.environment?["PATH"]?.hasPrefix("/opt/homebrew/bin:/usr/local/bin:") ?? false)
        #endif
    }
}
