import XCTest
@testable import TristanCore

/// Characterization tests: they pin today's approval-policy and sandbox behaviour.
final class PolicyTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func bash(_ command: String) -> ApprovalRule? {
        ApprovalRule.make(tool: "Bash", input: ["command": command], workingDirectory: temp)
    }

    func testBashPlainProgramGeneralises() {
        let rule = bash("ls -la")
        XCTAssertEqual(rule?.key, "Bash:ls")
        XCTAssertEqual(rule?.label, "Bash: ls …")
    }

    func testBashOperatorsNeverGeneralise() {
        let commands = [
            "ls; echo hi", "ls & echo hi", "ls | wc", "ls > out.txt", "cat < in.txt",
            "echo `whoami`", "echo $(whoami)", "ls\necho hi", "ls \\ foo",
        ]
        for command in commands {
            XCTAssertNil(bash(command), "should not generalise: \(command)")
        }
    }

    func testNeverGeneraliseList() {
        let names = [
            "rm", "sudo", "dd", "chmod", "chown", "mv", "kill", "killall", "shred", "mkfs", "diskutil",
            "launchctl", "curl", "wget", "sh", "bash", "zsh", "eval", "exec", "ssh", "scp", "env", "xargs",
        ]
        for name in names {
            XCTAssertNil(bash("\(name) x"), "should not generalise: \(name)")
        }
    }

    func testEditInsideFolderGeneralises() throws {
        let root = try XCTUnwrap(SafePath.real(temp))
        let rule = ApprovalRule.make(tool: "Edit", input: ["file_path": temp.appendingPathComponent("a.txt").path],
                                     workingDirectory: temp)
        XCTAssertEqual(rule?.key, "Edit@\(root)")
        XCTAssertEqual(rule?.label, "Edit inside \(temp.lastPathComponent)")
    }

    func testEditOutsideFolderDoesNot() throws {
        let proj = temp.appendingPathComponent("Proj", isDirectory: true)
        let evil = temp.appendingPathComponent("Proj-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
        func rule(_ path: String) -> ApprovalRule? {
            ApprovalRule.make(tool: "Write", input: ["file_path": path], workingDirectory: proj)
        }
        XCTAssertNotNil(rule(proj.appendingPathComponent("a.txt").path))
        XCTAssertNil(rule(proj.path + "/../x"))
        XCTAssertNil(rule(evil.appendingPathComponent("a.txt").path))
        XCTAssertNil(rule("/etc/hosts"))
    }

    func testAutoModeAsksForRiskyAndAllowsPlain() {
        let rule = ApprovalRule(key: "Bash:ls", label: "Bash: ls …")
        let auto = ToolPolicy(mode: .auto)
        XCTAssertTrue(auto.needsApproval(tool: "run_command", rule: nil))
        XCTAssertFalse(auto.needsApproval(tool: "run_command", rule: rule))
        XCTAssertTrue(ToolPolicy(mode: .ask).needsApproval(tool: "run_command", rule: rule))
        XCTAssertTrue(ToolPolicy(mode: .ask).needsApproval(tool: "run_command", rule: nil))
        XCTAssertFalse(ToolPolicy(mode: .yolo).needsApproval(tool: "run_command", rule: nil))
        XCTAssertFalse(ToolPolicy(mode: .yolo).needsApproval(tool: "write_file", rule: nil))
    }

    func testSandboxRejectsSymlinkEscape() throws {
        let root = temp.appendingPathComponent("root", isDirectory: true)
        let outside = temp.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret".write(to: outside.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        let sandbox = ToolSandbox(root: root)
        XCTAssertNil(sandbox.resolve("link/s.txt"))
        XCTAssertNil(sandbox.resolve("link/new.txt"))
        XCTAssertNil(sandbox.resolve("../outside/s.txt"))
        XCTAssertNotNil(sandbox.resolve("inside.txt"))
    }

    // MARK: - Windows inputs (Task 8). These run on the Mac.

    private func powershell(_ command: String) -> ApprovalRule? {
        ApprovalRule.make(tool: "PowerShell", input: ["command": command], workingDirectory: temp)
    }

    /// The never-generalise names exactly as the Task 8 brief lists them for PowerShell.
    private static let briefPowerShellNames = [
        "del", "erase", "rd", "rmdir", "remove-item", "ri", "invoke-expression", "iex", "invoke-webrequest", "iwr",
        "invoke-restmethod", "irm", "curl", "curl.exe", "wget", "powershell", "pwsh", "cmd", "reg", "format",
        "taskkill", "stop-process", "start-process", "set-executionpolicy", "net", "netsh", "schtasks", "sc",
        "bitsadmin", "certutil", "mshta", "wscript", "cscript", "rundll32", "regsvr32", "ssh", "scp", "sh", "bash",
        "env", "xargs",
    ]

    func testShellFlavorListsKeepThePosixValues() {
        XCTAssertEqual(ShellFlavor.posix.neverGeneralise, [
            "rm", "sudo", "dd", "chmod", "chown", "mv", "kill", "killall", "shred", "mkfs", "diskutil",
            "launchctl", "curl", "wget", "sh", "bash", "zsh", "eval", "exec", "ssh", "scp", "env", "xargs",
        ])
        XCTAssertEqual(ShellFlavor.posix.operators, [";", "&", "|", ">", "<", "`", "$(", "\n", "\\"])
        XCTAssertTrue(ShellFlavor.powershell.neverGeneralise.isSuperset(of: ShellFlavor.posix.neverGeneralise))
        XCTAssertTrue(ShellFlavor.powershell.neverGeneralise.isSuperset(of: Self.briefPowerShellNames))
        for op in ShellFlavor.posix.operators + ["$", "{", "}", "@(", "-encodedcommand", "\r"] {
            XCTAssertTrue(ShellFlavor.powershell.operators.contains(op), "missing PowerShell operator \(op.debugDescription)")
        }
    }

    func testPowerShellNeverGeneralise() {
        XCTAssertNil(powershell("DEL.EXE x"))
        XCTAssertNil(powershell("Remove-Item x"))
        XCTAssertNil(powershell("iex"))
        XCTAssertNil(powershell("Invoke-WebRequest u"))
        for name in Self.briefPowerShellNames.sorted() + ShellFlavor.powershell.neverGeneralise.sorted() {
            XCTAssertNil(powershell("\(name) x"), "should not generalise: \(name)")
            XCTAssertNil(powershell(name), "should not generalise: \(name)")
            XCTAssertNil(powershell("\(name.uppercased()) x"), "should not generalise: \(name.uppercased())")
            for ext in [".exe", ".EXE", ".cmd", ".bat", ".ps1", ".com"] {
                XCTAssertNil(powershell("\(name)\(ext) x"), "should not generalise: \(name)\(ext)")
            }
        }
    }

    func testPowerShellAdversarialProgramNames() {
        let commands = [
            "ReMoVe-ItEm x", "rm.exe x", "RM x", "Rm.Exe x", "curl.exe.exe u", "format.com C:", "rm.exe. x",
            #".\evil.exe"#, #"C:\x\evil.exe"#, "./evil.exe", "C:/x/evil.exe", ". evil.ps1", ".. x", ".exe x",
            "\"git\" status", "'git' status", "iex\tx", "iex\u{a0}x", "Microsoft.PowerShell.Management\\Remove-Item x",
            "start evil.exe", "saps evil.exe", "wsl rm -rf /mnt/c", "ii evil.lnk", "icm { x }", "move a b",
            "Move-Item a b", "spps 1", "Set-Content a b", "gsudo x", "runas x", "diskpart", "Add-Type x",
        ]
        for command in commands {
            XCTAssertNil(powershell(command), "should not generalise: \(command)")
        }
    }

    func testPowerShellOperatorsNeverGeneralise() {
        let commands = [
            "Get-Item $(x)", "Get-Item `x", "git { x }", "x -EncodedCommand y", "git -eNcOdEdCoMmAnD y", "a; b",
            "git $env:PATH", "git @(1)", "git }", "git status\rdel x", "git (Remove-Item x)",
            "git log | Out-File x", "git log > x", "git < x", "git & x", "git && x", "git \\x", "git\nx",
        ]
        for command in commands {
            XCTAssertNil(powershell(command), "should not generalise: \(command.debugDescription)")
        }
        for op in ShellFlavor.powershell.operators {
            XCTAssertNil(powershell("git \(op) x"), "operator should block: \(op.debugDescription)")
            XCTAssertNil(powershell("git \(op.uppercased()) x"), "operator should block: \(op.uppercased().debugDescription)")
        }
    }

    // MARK: Fix round 1

    private func bashOnWindows(_ command: String) -> ApprovalRule? {
        ApprovalRule.make(tool: "Bash", input: ["command": command], workingDirectory: temp, host: .windows)
    }

    func testPowerShellExpressionModeAndKeywordsNeverGeneralise() {
        let commands = [
            "-join 'C:/x/a.docx' -as [IO.StreamWriter]",
            "return 'C:/x' -as [IO.StreamWriter]",
            "0 -replace '0','//attacker/share/x' -as [IO.StreamWriter]",
            "throw 'x'",
            "1..2000000000",
            "using module ./evil.psm1",
            "using assembly C:/x/evil.dll",
            "_x y",
        ]
        XCTAssertNil(powershell("git [IO.File]::Delete('x')"), "`[` is a PowerShell operator")
        for command in commands {
            XCTAssertNil(powershell(command), "should not generalise: \(command)")
            XCTAssertNil(bashOnWindows(command), "Bash on Windows should not generalise: \(command)")
        }
        let keywords = [
            "return", "throw", "exit", "break", "continue", "using", "data", "trap", "filter", "function", "param",
            "begin", "process", "end", "dynamicparam", "switch", "foreach", "for", "while", "do", "until", "if", "try",
            "class", "enum", "configuration", "workflow", "parallel", "sequence", "inlinescript",
        ]
        for keyword in keywords {
            XCTAssertNil(powershell("\(keyword) x"), "keyword should not generalise: \(keyword)")
            XCTAssertNil(powershell(keyword.uppercased()), "keyword should not generalise: \(keyword)")
            XCTAssertNil(bashOnWindows("\(keyword) x"), "keyword should not generalise on Windows Bash: \(keyword)")
        }
        XCTAssertTrue(ShellFlavor.powershell.operators.contains("["))
        XCTAssertEqual(powershell("git status")?.key, "PowerShell:git")
    }

    func testPowerShellMissedWindowsCounterpartsNeverGeneralise() {
        let names = [
            "ren", "rni", "rename-item", "format-volume", "clear-disk", "initialize-disk", "remove-partition",
            "stop-service", "spsv", "remove-service", "restart-service", "restart-computer", "stop-computer",
            "set-acl", "conhost", "explorer", "forfiles", "wt", "pwsh-preview", "cmd", "start",
        ]
        for name in names {
            XCTAssertNil(powershell("\(name) x"), "should not generalise: \(name)")
            XCTAssertNil(powershell("\(name).exe x"), "should not generalise: \(name).exe")
        }
    }

    /// Programs that load code, start hidden work, write files or change the system (final fix wave).
    func testPowerShellLoadersAndWritersNeverGeneralise() {
        let names = [
            "import-module", "ipmo", "new-object", "tee-object", "tee", "new-itemproperty", "register-scheduledjob",
            "start-threadjob", "tskill", "fsutil",
        ]
        let mixed = ["Import-Module", "IpMo", "New-Object", "Tee-Object", "TEE", "New-ItemProperty",
                     "Register-ScheduledJob", "Start-ThreadJob", "TsKill", "FsUtil"]
        for name in names + mixed {
            XCTAssertTrue(ShellFlavor.powershell.neverGeneralise.contains(name.lowercased()), name)
            XCTAssertNil(powershell("\(name) x"), "should not generalise: \(name)")
            XCTAssertNil(powershell(name), "should not generalise: \(name)")
            XCTAssertNil(powershell("\(name.uppercased()) x"), "should not generalise: \(name.uppercased())")
            for ext in [".exe", ".EXE", ".Exe", ".cmd", ".bat", ".ps1", ".com"] {
                XCTAssertNil(powershell("\(name)\(ext) x"), "should not generalise: \(name)\(ext)")
            }
        }
        XCTAssertFalse(ShellFlavor.posix.neverGeneralise.contains("tee"), "the Mac list is unchanged")
    }

    func testPowerShellRejectsUnicodeSeparatorsAndControls() {
        let commands = [
            "git status\u{2028}Remove-Item -Recurse C:/x", "git status\u{2029}calc", "git status\u{0085}calc",
            "git\u{00A0}status", "git\u{3000}status", "git\u{200B}status", "git\u{200E}status", "git\u{200F}status",
            "git\u{FEFF}status", "git\tstatus", "git status\u{7F}", "git status\u{1680}x", "git\u{2009}status",
            "git status\u{000B}calc", "git status\u{000C}calc",
        ]
        for command in commands {
            XCTAssertNil(powershell(command), "should not generalise: \(command.debugDescription)")
            XCTAssertNil(bashOnWindows(command), "Bash on Windows should not generalise: \(command.debugDescription)")
        }
        XCTAssertEqual(powershell("git commit -m café")?.key, "PowerShell:git", "plain non-ASCII letters are fine")
        XCTAssertEqual(powershell("git log --oneline -5")?.key, "PowerShell:git")
    }

    func testPowerShellEncodedCommandAbbreviations() {
        let flags = [
            "-e", "-ec", "-en", "-enc", "-enco", "-encod", "-encode", "-encoded", "-encodedc", "-encodedco",
            "-encodedcom", "-encodedcomm", "-encodedcomma", "-encodedcomman", "-encodedcommand",
            "-EC", "-Enc", "-ENCODEDCOMMAND", "\u{2013}enc", "\u{2014}enc", "\u{2013}e", "\u{2014}EncodedCommand",
            "-enc:abc", "\u{2015}enc",
        ]
        for flag in flags {
            XCTAssertNil(powershell("git \(flag) ZQBjAGgAbwA="), "should not generalise: \(flag)")
        }
        XCTAssertEqual(powershell("git log -n 5")?.key, "PowerShell:git", "unrelated flags still generalise")
    }

    func testPowerShellPlainProgramGeneralises() {
        XCTAssertEqual(powershell("git status")?.key, "PowerShell:git")
        XCTAssertEqual(powershell("git status")?.label, "PowerShell: git …")
        XCTAssertEqual(powershell("Git.exe status")?.key, "PowerShell:git", "case and extension fold into one rule")
        XCTAssertEqual(powershell("  npm test  ")?.key, "PowerShell:npm")
        XCTAssertEqual(powershell("Get-ChildItem -Force")?.key, "PowerShell:get-childitem")
        // The PowerShell tool never produces a Bash key, and vice versa.
        XCTAssertNotEqual(powershell("ls")?.key, bash("ls")?.key)
    }

    /// Claude Code on Windows runs its Bash tool through Git Bash, where the file system is case-insensitive,
    /// `.exe` resolves, and `powershell`/`cmd` are one word away. On a Windows host, Bash commands use the
    /// Windows name folding and the PowerShell list; on the Mac they keep today's behaviour.
    func testBashOnWindowsHostUsesWindowsNames() {
        func bashOn(_ host: PathFlavor, _ command: String) -> ApprovalRule? {
            ApprovalRule.make(tool: "Bash", input: ["command": command], workingDirectory: temp, host: host)
        }
        for command in ["RM x", "rm.exe x", "powershell -c x", "cmd /c x", "Remove-Item x", "wsl x", "iex x"] {
            XCTAssertNil(bashOn(.windows, command), "should not generalise on Windows: \(command)")
        }
        XCTAssertEqual(bashOn(.windows, "git status")?.key, "Bash:git")
        XCTAssertEqual(bashOn(.windows, "Git.exe status")?.key, "Bash:git")
        XCTAssertEqual(bashOn(.posix, "Git status")?.key, "Bash:Git", "the Mac keeps today's keys")
        XCTAssertEqual(bashOn(.posix, "powershell x")?.key, "Bash:powershell", "the Mac keeps today's list")
    }

    func testAutoModeWithPowerShellRules() {
        let auto = ToolPolicy(mode: .auto)
        XCTAssertTrue(auto.needsApproval(tool: "run_command", rule: powershell("Remove-Item x")))
        XCTAssertTrue(auto.needsApproval(tool: "run_command", rule: powershell("git $(iex x)")))
        XCTAssertFalse(auto.needsApproval(tool: "run_command", rule: powershell("git status")))
    }

    /// `SafePath.real` walks up to the deepest existing ancestor. On Windows a missing drive (`Q:\`) is its own
    /// parent and never equals "/", so the walk must stop when the parent stops changing.
    func testSafePathRealTerminatesAtDriveRoot() throws {
        let missing = URL(fileURLWithPath: "/no-such-drive-\(UUID().uuidString)", isDirectory: true)
        let deep = missing.appendingPathComponent("a/b/c.txt")
        // A parent function that behaves like Windows at a drive root: the root is its own parent.
        let windowsLikeParent: (URL) -> URL = { url in
            url.standardizedFileURL.path == missing.path ? url : url.deletingLastPathComponent()
        }
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        DispatchQueue.global().async {
            box.value = SafePath.real(deep, parent: windowsLikeParent)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success, "SafePath.real must return within a second")
        XCTAssertNil(box.value, "a path on a missing drive root cannot be resolved")

        // An existing root that is its own parent still resolves, even when the walk's existence probe fails on it
        // (as `attributesOfItem` may for a bare drive root on Windows): the walk stops at the self-parent root and
        // the root is then confirmed with `fileExists`. The probe below says nothing exists, so the walk really
        // reaches the self-parent branch.
        let root = try XCTUnwrap(SafePath.real(temp))
        let existingRootParent: (URL) -> URL = { url in
            url.standardizedFileURL.path == self.temp.standardizedFileURL.path ? url : url.deletingLastPathComponent()
        }
        let nothingExists: (String) -> Bool = { _ in false }
        XCTAssertEqual(SafePath.real(temp, parent: existingRootParent, exists: nothingExists), root)
        XCTAssertEqual(SafePath.real(temp.appendingPathComponent("x/y.txt"), parent: existingRootParent, exists: nothingExists),
                       root + "/x/y.txt")

        // A parent function that never settles still terminates.
        let runaway: (URL) -> URL = { $0.appendingPathComponent("..") }
        let done2 = DispatchSemaphore(value: 0)
        let box2 = ResultBox()
        DispatchQueue.global().async {
            box2.value = SafePath.real(missing.appendingPathComponent("z"), parent: runaway)
            done2.signal()
        }
        XCTAssertEqual(done2.wait(timeout: .now() + 1), .success)
        XCTAssertNil(box2.value)
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: String?
}
