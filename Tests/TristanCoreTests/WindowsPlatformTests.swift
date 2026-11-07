#if os(Windows)
import XCTest
import WinSDK
@testable import TristanCore

/// Windows behaviour the code assumes, checked on a real machine: arguments through an npm `.cmd` shim, PowerShell
/// for `run_command`, and the loopback approval port held exclusively.
final class WindowsPlatformTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-winproc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func native(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
    }

    private func output(of process: Process) throws -> (text: String, status: Int32) {
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    /// Review focus 4: awkward arguments to an npm shim reach the node program unchanged, because the launcher runs
    /// node on the shim's script directly and cmd.exe never sees them.
    func testNpmShimArgumentsReachNodeUnchanged() throws {
        guard let node = ProcessLauncher.locate("node") else { throw XCTSkip("node is not installed") }
        let shim = """
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
        endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\\node_modules\\dump\\cli.js" %*\r

        """
        try Data(shim.utf8).write(to: folder.appendingPathComponent("dumptool.cmd"))
        let script = folder.appendingPathComponent("node_modules\\dump", isDirectory: true)
        try FileManager.default.createDirectory(at: script, withIntermediateDirectories: true)
        try Data("process.stdout.write(JSON.stringify(process.argv.slice(2)))".utf8).write(to: script.appendingPathComponent("cli.js"))

        let tricky = ["two words", "quote\"inside", "a&b", "100%", "%PATH%", "trail\\", "caf\u{e9} \u{65E5}\u{672C}",
                      "^caret", "pipe|x", "(paren)", "!bang!", "back\\\\\"slash"]
        // Not tested: an empty argument. Foundation.Process on Windows drops it (spike notes), shim or not.
        var environment = ProcessInfo.processInfo.environment
        let nodeFolder = URL(fileURLWithPath: node).deletingLastPathComponent()
        environment["PATH"] = native(folder) + ";" + native(nodeFolder)
        let plan = try ProcessLauncher.plan("dumptool", tricky, environment: environment, windows: true,
                                            isFile: { FileManager.default.fileExists(atPath: $0) },
                                            readFile: { try? String(contentsOfFile: $0, encoding: .utf8) })
        XCTAssertTrue(plan.executable.lowercased().hasSuffix("node.exe"), plan.executable)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        let (text, status) = try output(of: process)
        XCTAssertEqual(status, 0, text)
        let received = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String]
        XCTAssertEqual(received, tricky)
    }

    func testRunCommandUsesPowerShellAndReportsExitStatus() async {
        let sandbox = ToolSandbox(root: folder)
        let ok = await sandbox.run("Write-Output 'hi there'")
        XCTAssertTrue(ok.text.contains("hi there"), ok.text)
        XCTAssertTrue(ok.text.contains("[exit status 0]"), ok.text)
        XCTAssertFalse(ok.isError)
        let bad = await sandbox.run("exit 3")
        XCTAssertTrue(bad.isError)
        XCTAssertTrue(bad.text.contains("[exit status 3]"), bad.text)
        let piped = await sandbox.run("'a & b' | Write-Output; '100%'")
        XCTAssertTrue(piped.text.contains("a & b") && piped.text.contains("100%"), piped.text)
    }

    /// Ruling (Task 7): non-ASCII output may come back in the OEM code page. Recorded, not asserted, until decided.
    func testRunCommandNonASCIIOutput() async {
        let sandbox = ToolSandbox(root: folder)
        let result = await sandbox.run("Write-Output ('caf' + [char]0xE9 + ' ' + [char]0x65E5 + [char]0x672C)")
        print("run_command non-ASCII output: \(result.text.debugDescription)")
        XCTAssertFalse(result.isError, result.text)
    }

    /// The per-run approval folder is restricted to the user named by the process token's SID.
    func testCurrentUserSIDComesFromTheToken() {
        let sid = PermissionServer.currentUserSID()
        XCTAssertTrue(sid?.hasPrefix("S-1-5-") == true, sid ?? "nil")
    }

    /// The approval folder's ACL as icacls shows it: no inherited entries and exactly one entry, full control for the
    /// process token's SID, inherited by what is created inside.
    func testApprovalFolderGrantsOnlyTheCurrentUser() throws {
        let server = PermissionServer(workingDirectory: folder, transport: .loopback) { _, _, _ in false }
        XCTAssertTrue(server.start())
        defer { server.stop() }
        let path = native(server.directory)
        let icacls = (ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows") + "\\System32\\icacls.exe"

        let show = Process()
        show.executableURL = URL(fileURLWithPath: icacls)
        show.arguments = [path]
        let (text, status) = try output(of: show)
        XCTAssertEqual(status, 0, text)
        let listing = text.components(separatedBy: "Successfully processed").first ?? ""
        var entries = listing.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let first = entries.first, first.lowercased().hasPrefix(path.lowercased()) {
            entries[0] = String(first.dropFirst(path.count)).trimmingCharacters(in: .whitespaces)
        }
        entries = entries.filter { !$0.isEmpty }
        XCTAssertEqual(entries.count, 1, text)
        XCTAssertFalse(text.contains("(I)"), "no inherited entries: \(text)")
        XCTAssertTrue(entries.first?.hasSuffix(":(OI)(CI)(F)") == true, text)

        let sid = try XCTUnwrap(PermissionServer.currentUserSID())
        let find = Process()
        find.executableURL = URL(fileURLWithPath: icacls)
        find.arguments = [path, "/findsid", "*" + sid]
        let (found, _) = try output(of: find)
        XCTAssertTrue(found.contains("SID Found"), "the one entry is for \(sid): \(found)")
    }

    /// A socket asking to share the address (SO_REUSEADDR) on `host`:`port`, listening if the bind worked.
    private func rogueBind(host: UInt32, port: UInt16) -> (socket: SOCKET, bound: Bool) {
        let other = WinSDK.socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        _ = withUnsafePointer(to: &one) {
            $0.withMemoryRebound(to: CChar.self, capacity: 4) { setsockopt(other, SOL_SOCKET, SO_REUSEADDR, $0, 4) }
        }
        var address = sockaddr_in()
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.S_un.S_addr = host.bigEndian
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { WinSDK.bind(other, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc == 0 { _ = WinSDK.listen(other, 4) }
        return (other, rc == 0)
    }

    /// SO_EXCLUSIVEADDRUSE: while the host holds 127.0.0.1:port, no other socket can bind that address, even one that
    /// asks to share it. Windows does let another socket bind the wildcard address on the same port (observed on the
    /// runner), but connections to 127.0.0.1 still reach the more specific binding, the host's.
    func testLoopbackPortCannotBeTakenWhileHeld() throws {
        let listener = try XCTUnwrap(LoopbackListener())
        defer { listener.close() }
        var data = WSADATA()
        XCTAssertEqual(WSAStartup(WORD(0x0202), &data), 0)
        defer { WSACleanup() }

        let exact = rogueBind(host: 0x7F00_0001, port: listener.port)
        defer { closesocket(exact.socket) }
        XCTAssertFalse(exact.bound, "another socket bound the held 127.0.0.1 port")

        let wildcard = rogueBind(host: 0, port: listener.port)
        defer { closesocket(wildcard.socket) }
        print("wildcard bind on the held port: \(wildcard.bound ? "allowed" : "refused")")
        let client = ApprovalTransport.connect(endpoint: listener.endpoint, token: listener.token,
                                               serverToken: listener.serverToken, handshakeTimeout: 5, replyTimeout: 5)
        XCTAssertNotNil(client, "the shim must still reach the real host")
        client?.close()
    }
}
#endif
