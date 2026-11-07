import XCTest
@testable import TristanCore

/// Windows behaviour is checked with Windows-style strings through pure functions, so it runs on the Mac too.
final class ProcessLauncherTests: XCTestCase {
    static let npmShim = """
    @ECHO off\r
    GOTO start\r
    :find_dp0\r
    SET dp0=%~dp0\r
    EXIT /b\r
    :start\r
    SETLOCAL\r
    CALL :find_dp0\r
    \r
    IF EXIST "%dp0%\\node.exe" (\r
      SET "_prog=%dp0%\\node.exe"\r
    ) ELSE (\r
      SET "_prog=node"\r
      SET PATHEXT=%PATHEXT:;.JS;=;%\r
    )\r
    \r
    endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\\node_modules\\@github\\copilot\\index.js" %*\r

    """

    /// The Azure CLI's `az.cmd` runs Python, not node.
    static let azShim = """
    @IF EXIST "%~dp0\\..\\python.exe" (\r
      "%~dp0\\..\\python.exe" -IBm azure.cli %*\r
    ) ELSE (\r
      python -IBm azure.cli %*\r
    )\r

    """

    // MARK: resolving

    func testResolvesCmdThroughPathExt() {
        let found = ExecutableResolver.resolve("copilot", searchPath: ["C:\\Windows\\system32", "C:\\npm"], pathExt: [".EXE", ".CMD"],
                                               isFile: { $0.lowercased() == "c:\\npm\\copilot.cmd" }, windows: true)
        XCTAssertEqual(found?.lowercased(), "c:\\npm\\copilot.cmd")
    }

    func testExeBeatsCmdInTheSameFolderInPathExtOrder() {
        let files: Set<String> = ["c:\\tools\\claude.exe", "c:\\tools\\claude.cmd"]
        let found = ExecutableResolver.resolve("claude", searchPath: ["C:\\tools\\"], pathExt: [".EXE", ".CMD"],
                                               isFile: { files.contains($0.lowercased()) }, windows: true)
        XCTAssertEqual(found?.lowercased(), "c:\\tools\\claude.exe")
    }

    func testNameWithKnownExtensionIsNotSuffixedAgain() {
        let found = ExecutableResolver.resolve("aws.exe", searchPath: ["C:\\Program Files\\Amazon\\AWSCLIV2"], pathExt: [".EXE", ".CMD"],
                                               isFile: { $0 == "C:\\Program Files\\Amazon\\AWSCLIV2\\aws.exe" }, windows: true)
        XCTAssertEqual(found, "C:\\Program Files\\Amazon\\AWSCLIV2\\aws.exe")
    }

    func testPathWithSeparatorIsNotSearched() {
        var probed: [String] = []
        let windows = ExecutableResolver.resolve("C:\\tools\\az.cmd", searchPath: ["C:\\npm"], pathExt: [".EXE"],
                                                 isFile: { probed.append($0); return false }, windows: true)
        XCTAssertEqual(windows, "C:\\tools\\az.cmd")
        let forward = ExecutableResolver.resolve("tools/az", searchPath: ["C:\\npm"], pathExt: [".EXE"],
                                                 isFile: { probed.append($0); return false }, windows: true)
        XCTAssertEqual(forward, "tools/az")
        let mac = ExecutableResolver.resolve("/bin/bash", searchPath: ["/opt/homebrew/bin"], pathExt: [],
                                             isFile: { probed.append($0); return false }, windows: false)
        XCTAssertEqual(mac, "/bin/bash")
        XCTAssertEqual(probed, [], "a path is used as given, never searched")
    }

    func testMacResolutionUnchanged() {
        let path = ProcessLauncher.searchPath(ProcessLauncher.macPATH(inherited: "/usr/bin:/bin"), windows: false)
        XCTAssertEqual(path, ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
        XCTAssertEqual(ProcessLauncher.macPATH(inherited: nil), "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        let found = ExecutableResolver.resolve("aws", searchPath: path, pathExt: [".EXE"],
                                               isFile: { $0 == "/opt/homebrew/bin/aws" || $0 == "/usr/bin/aws" }, windows: false)
        XCTAssertEqual(found, "/opt/homebrew/bin/aws", "Homebrew comes first, as with /usr/bin/env and the old PATH")
        XCTAssertNil(ExecutableResolver.resolve("aws", searchPath: path, pathExt: [".EXE"],
                                                isFile: { $0 == "/opt/homebrew/bin/aws.exe" }, windows: false),
                     "PATHEXT means nothing on the Mac")
    }

    func testWindowsSearchPathHandlesQuotesAndEmptyEntries() {
        XCTAssertEqual(ProcessLauncher.searchPath("C:\\Windows;;\"C:\\Program Files\\nodejs\";C:\\npm\\", windows: true),
                       ["C:\\Windows", "C:\\Program Files\\nodejs", "C:\\npm\\"])
        XCTAssertEqual(ProcessLauncher.pathExtensions(".COM;.EXE;;.CMD"), [".COM", ".EXE", ".CMD"])
        XCTAssertEqual(ProcessLauncher.pathExtensions(nil), [".COM", ".EXE", ".BAT", ".CMD"])
    }

    func testWindowsEnvironmentLookupIgnoresCase() {
        XCTAssertEqual(ProcessLauncher.value(of: "PATH", in: ["Path": "C:\\x"], windows: true), "C:\\x")
        XCTAssertNil(ProcessLauncher.value(of: "PATH", in: ["Path": "/x"], windows: false))
    }

    func testNotFoundThrowsToolNotFound() {
        XCTAssertThrowsError(try ProcessLauncher.plan("copilot", ["-p", "x"], environment: ["Path": "C:\\npm", "PATHEXT": ".EXE;.CMD"],
                                                      windows: true, isFile: { _ in false }, readFile: { _ in nil })) { error in
            XCTAssertEqual(error as? ToolNotFound, ToolNotFound(name: "copilot"))
        }
        XCTAssertThrowsError(try ProcessLauncher.prepare("tristan-no-such-tool-\(UUID().uuidString.prefix(6))", [], directory: nil,
                                                         extraEnvironment: [:])) { error in
            XCTAssertTrue(error is ToolNotFound)
        }
    }

    // MARK: cmd.exe safety

    func testCmdShimGuardRejectsMetacharacters() {
        for bad in ["100%", "a^b", "fix & del x", "a|b", "<in", "out>", "say \"hi\"", "line\nbreak", "line\rbreak"] {
            XCTAssertFalse(CmdShimGuard.isSafe(["-p", bad]), "\(bad.debugDescription) must be refused")
        }
        XCTAssertTrue(CmdShimGuard.isSafe(["-p", "fix the login bug"]))
        XCTAssertTrue(CmdShimGuard.isSafe(["-p", "corrige el código: añade pruebas 日本語"]))
        XCTAssertTrue(CmdShimGuard.isSafe([]))
    }

    func testParsesTypicalNpmShim() {
        XCTAssertEqual(CmdShim.nodeScript(shimText: Self.npmShim, shimPath: "C:\\Users\\Ana\\AppData\\Roaming\\npm\\copilot.cmd"),
                       "C:\\Users\\Ana\\AppData\\Roaming\\npm\\node_modules\\@github\\copilot\\index.js")
    }

    func testParsesOlderNpmShimStyle() {
        let text = "@IF EXIST \"%~dp0\\node.exe\" (\r\n  \"%~dp0\\node.exe\"  \"%~dp0\\node_modules\\x\\cli.js\" %*\r\n) ELSE (\r\n  node  \"%~dp0\\node_modules\\x\\cli.js\" %*\r\n)\r\n"
        XCTAssertEqual(CmdShim.nodeScript(shimText: text, shimPath: "C:\\npm\\x.cmd"), "C:\\npm\\node_modules\\x\\cli.js")
    }

    func testShimWithNoNodeLineReturnsNil() {
        XCTAssertNil(CmdShim.nodeScript(shimText: Self.azShim, shimPath: "C:\\Program Files\\Azure\\wbin\\az.cmd"))
        XCTAssertNil(CmdShim.nodeScript(shimText: "@echo off\r\n\"%~dp0\\tool.exe\" %*\r\n", shimPath: "C:\\t\\tool.cmd"))
        XCTAssertNil(CmdShim.nodeScript(shimText: "", shimPath: "C:\\t\\tool.cmd"))
    }

    func testNpmShimLaunchesNodeDirectlyEvenWithUnsafeArguments() throws {
        let shim = "C:\\npm\\copilot.cmd"
        let files: Set<String> = [shim, "c:\\program files\\nodejs\\node.exe"]
        let plan = try ProcessLauncher.plan("copilot", ["-p", "fix \"auth\" & 100% done"],
                                            environment: ["Path": "C:\\npm;C:\\Program Files\\nodejs", "PATHEXT": ".COM;.EXE;.BAT;.CMD"],
                                            windows: true, isFile: { files.contains($0.lowercased()) || $0 == shim },
                                            readFile: { $0.lowercased() == shim.lowercased() ? Self.npmShim : nil })
        XCTAssertEqual(plan.executable.lowercased(), "c:\\program files\\nodejs\\node.exe")
        XCTAssertEqual(plan.arguments, ["C:\\npm\\node_modules\\@github\\copilot\\index.js", "-p", "fix \"auth\" & 100% done"])
    }

    func testNpmShimPrefersNodeNextToTheShim() throws {
        let plan = try ProcessLauncher.plan("copilot", ["-p", "x"], environment: ["PATH": "C:\\npm", "PATHEXT": ".EXE;.CMD"],
                                            windows: true, isFile: { ["c:\\npm\\copilot.cmd", "c:\\npm\\node.exe"].contains($0.lowercased()) },
                                            readFile: { _ in Self.npmShim })
        XCTAssertEqual(plan.executable.lowercased(), "c:\\npm\\node.exe")
    }

    func testNodeIsNeverACmdShimEvenWhenOneComesFirstOnPath() throws {
        let files: Set<String> = ["c:\\npm\\copilot.cmd", "c:\\wrappers\\node.cmd", "c:\\program files\\nodejs\\node.exe"]
        let plan = try ProcessLauncher.plan("copilot", ["-p", "fix&calc"],
                                            environment: ["Path": "C:\\wrappers;C:\\npm;C:\\Program Files\\nodejs", "PATHEXT": ".COM;.EXE;.BAT;.CMD"],
                                            windows: true, isFile: { files.contains($0.lowercased()) }, readFile: { _ in Self.npmShim })
        XCTAssertEqual(plan.executable.lowercased(), "c:\\program files\\nodejs\\node.exe")
    }

    func testOnlyACmdNodeFallsBackToTheGuard() {
        let files: Set<String> = ["c:\\npm\\copilot.cmd", "c:\\wrappers\\node.cmd", "c:\\wrappers\\node.bat"]
        XCTAssertThrowsError(try ProcessLauncher.plan("copilot", ["-p", "fix&calc"],
                                                      environment: ["Path": "C:\\wrappers;C:\\npm", "PATHEXT": ".COM;.EXE;.BAT;.CMD"],
                                                      windows: true, isFile: { files.contains($0.lowercased()) }, readFile: { _ in Self.npmShim })) { error in
            XCTAssertEqual(error as? UnsafeArguments, UnsafeArguments(tool: "copilot"))
        }
        let safe = try? ProcessLauncher.plan("copilot", ["-p", "fix the login bug"],
                                             environment: ["Path": "C:\\wrappers;C:\\npm", "PATHEXT": ".COM;.EXE;.BAT;.CMD"],
                                             windows: true, isFile: { files.contains($0.lowercased()) }, readFile: { _ in Self.npmShim })
        XCTAssertEqual(safe?.executable.lowercased(), "c:\\npm\\copilot.cmd", "safe arguments run the shim itself")
    }

    func testWindowsIgnoresRelativePathEntries() throws {
        XCTAssertEqual(ProcessLauncher.searchPath(".;bin;..\\x;C:relative;C:\\npm;\\\\server\\share\\tools;D:/tools", windows: true),
                       ["C:\\npm", "\\\\server\\share\\tools", "D:/tools"])
        let plan = try ProcessLauncher.plan("aws", [], environment: ["Path": ".;bin;C:\\aws", "PATHEXT": ".EXE"], windows: true,
                                            isFile: { $0.lowercased().hasSuffix("aws.exe") }, readFile: { _ in nil })
        XCTAssertEqual(plan.executable, "C:\\aws\\aws.exe", "a tool planted in the current folder is never picked")
        XCTAssertEqual(ProcessLauncher.searchPath(".:bin:/usr/bin", windows: false), [".", "bin", "/usr/bin"], "Mac unchanged")
    }

    func testUnparsableShimRefusesUnsafeArguments() {
        XCTAssertThrowsError(try ProcessLauncher.plan("az", ["account", "show", "--query", "a&b"], environment: ["PATH": "C:\\az", "PATHEXT": ".EXE;.CMD"],
                                                      windows: true, isFile: { $0.lowercased() == "c:\\az\\az.cmd" },
                                                      readFile: { _ in Self.azShim })) { error in
            XCTAssertEqual(error as? UnsafeArguments, UnsafeArguments(tool: "az"))
        }
    }

    func testUnparsableShimWithSafeArgumentsRunsTheShim() throws {
        let plan = try ProcessLauncher.plan("az", ["account", "get-access-token", "-o", "tsv"], environment: ["PATH": "C:\\az", "PATHEXT": ".EXE;.CMD"],
                                            windows: true, isFile: { $0.lowercased() == "c:\\az\\az.cmd" }, readFile: { _ in nil })
        XCTAssertEqual(plan.executable.lowercased(), "c:\\az\\az.cmd")
        XCTAssertEqual(plan.arguments, ["account", "get-access-token", "-o", "tsv"])
    }

    func testBatShimIsGuardedToo() {
        XCTAssertThrowsError(try ProcessLauncher.plan("C:\\t\\run.BAT", ["x|y"], environment: [:], windows: true,
                                                      isFile: { _ in true }, readFile: { _ in nil }))
    }

    func testExeOnWindowsIsNotGuarded() throws {
        let plan = try ProcessLauncher.plan("aws", ["--profile", "a&b"], environment: ["PATH": "C:\\aws", "PATHEXT": ".EXE;.CMD"],
                                            windows: true, isFile: { $0.lowercased() == "c:\\aws\\aws.exe" }, readFile: { _ in nil })
        XCTAssertEqual(plan.arguments, ["--profile", "a&b"], "CreateProcess passes arguments to an .exe without cmd.exe")
    }

    func testMacPlanIsNeverGuarded() throws {
        let plan = try ProcessLauncher.plan("copilot", ["-p", "a & b %x%"], environment: ["PATH": "/usr/bin"], windows: false,
                                            isFile: { $0 == "/opt/homebrew/bin/copilot" }, readFile: { _ in nil })
        XCTAssertEqual(plan.executable, "/opt/homebrew/bin/copilot")
        XCTAssertEqual(plan.arguments, ["-p", "a & b %x%"])
        XCTAssertEqual(plan.environment["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin")
    }

    // MARK: launching for real on the Mac

    #if os(Windows)
    func testPrepareRunsPowerShellWithEnvironmentAndDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
        let process = try ProcessLauncher.prepare("powershell", ["-NoProfile", "-NonInteractive", "-Command",
                                                                 "Write-Output \"hi $env:TRISTAN_LAUNCHER_TEST\"; (Get-Location).ProviderPath"],
                                                  directory: directory, extraEnvironment: ["TRISTAN_LAUNCHER_TEST": "there"])
        XCTAssertFalse(process.isRunning, "prepare configures but never starts")
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(lines.first, "hi there")
        let native = directory.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? directory.path
        XCTAssertEqual(lines.last.map { PathContainment.contains(root: native, path: $0, flavor: .windows) && PathContainment.contains(root: $0, path: native, flavor: .windows) }, true,
                       "ran in \(lines.last ?? "?"), expected \(native)")
    }
    #else   // /bin/sh and `pwd -P`; the Windows twin is above
    func testPrepareRunsEchoWithEnvironmentAndDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
        let process = try ProcessLauncher.prepare("sh", ["-c", "echo hi $TRISTAN_LAUNCHER_TEST; pwd -P"], directory: directory,
                                                  extraEnvironment: ["TRISTAN_LAUNCHER_TEST": "there"])
        XCTAssertFalse(process.isRunning, "prepare configures but never starts")
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "hi there")
        XCTAssertEqual(lines.last.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, directory.resolvingSymlinksInPath().path)
        XCTAssertTrue(process.environment?["PATH"]?.hasPrefix("/opt/homebrew/bin:/usr/local/bin:") == true)
    }
    #endif

    func testPrepareEcho() throws {
        let process = try ProcessLauncher.prepare("echo", ["hi"], directory: nil, extraEnvironment: [:])
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(text, "hi\n")
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
