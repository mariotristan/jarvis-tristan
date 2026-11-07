#if os(Windows)
import XCTest
import WinSDK
@testable import TristanCore

/// The Windows path and policy rules with the real file system (the pure-string cases are in PathContainmentTests and
/// PolicyTests): real `C:\` folders, a junction and a directory symlink pointing out of the working folder, 8.3 short
/// names, and approval rules for the PowerShell tool.
final class WindowsSafetyTests: XCTestCase {
    private var base: URL!
    private var proj: URL { base.appendingPathComponent("proj", isDirectory: true) }
    private var links: [URL] = []

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-win-\(UUID().uuidString.prefix(8))", isDirectory: true)
        for name in ["proj", "proj-evil", "other"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("secret".utf8).write(to: base.appendingPathComponent("other\\secret.txt"))
        try Data("mine".utf8).write(to: proj.appendingPathComponent("mine.txt"))
    }

    override func tearDown() {
        // Remove links with rmdir first so deleting the tree never follows them into `other`.
        for link in links { _ = cmd(["/c", "rmdir", native(link)]) }
        try? FileManager.default.removeItem(at: base)
    }

    private func native(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
    }

    @discardableResult
    private func cmd(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: (ProcessInfo.processInfo.environment["ComSpec"] ?? "C:\\Windows\\System32\\cmd.exe"))
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// `mklink <flag> proj\<name> other`; false when Windows refuses (symlinks need a privilege).
    private func link(_ name: String, flag: String) -> URL? {
        let url = proj.appendingPathComponent(name)
        guard cmd(["/c", "mklink", flag, native(url), native(base.appendingPathComponent("other"))]) == 0 else { return nil }
        links.append(url)
        return url
    }

    func testPlatformFlavours() {
        XCTAssertEqual(PathFlavor.current, .windows)
        XCTAssertEqual(ShellFlavor.current, .powershell)
        XCTAssertEqual(ApprovalTransportKind.platformDefault, .loopback)
    }

    func testSandboxResolvesInsideAndRefusesOutside() {
        let sandbox = ToolSandbox(root: proj)
        let root = native(proj)
        XCTAssertNotNil(sandbox.resolve("mine.txt"))
        XCTAssertNotNil(sandbox.resolve("sub\\new\\b.txt"), "a file that does not exist yet")
        XCTAssertNotNil(sandbox.resolve("sub/new/b.txt"))
        XCTAssertNotNil(sandbox.resolve(root + "\\c.txt"))
        XCTAssertNotNil(sandbox.resolve(root.uppercased() + "\\MINE.TXT"), "drive and ASCII case do not matter")
        XCTAssertNil(sandbox.resolve("..\\other\\secret.txt"))
        XCTAssertNil(sandbox.resolve(root + "\\..\\other\\secret.txt"))
        XCTAssertNil(sandbox.resolve(native(base) + "\\proj-evil\\a.txt"), "a sibling with the root as a name prefix")
        XCTAssertNil(sandbox.resolve("C:foo"), "drive-relative")
        XCTAssertNil(sandbox.resolve("\\foo"), "root-relative")
        XCTAssertNil(sandbox.resolve("\\\\server\\share\\proj\\a.txt"), "UNC")
        XCTAssertNil(sandbox.resolve("mine.txt:stream"), "alternate data stream")
    }

    func testSafePathOnADriveRootTerminates() {
        XCTAssertNotNil(SafePath.real(URL(fileURLWithPath: "C:\\")))
        XCTAssertNotNil(SafePath.real(URL(fileURLWithPath: "C:\\no-such-\(UUID().uuidString)\\x.txt")))
    }

    func testJunctionOutOfTheRootIsOutside() throws {
        guard let junction = link("junction", flag: "/J") else { throw XCTSkip("mklink /J failed on this machine") }
        let sandbox = ToolSandbox(root: proj)
        XCTAssertNil(sandbox.resolve("junction\\secret.txt"), "a junction to a folder outside the root must not count as inside")
        XCTAssertNil(sandbox.resolve("junction\\new.txt"))
        XCTAssertNil(sandbox.resolve(native(junction) + "\\secret.txt"))
        XCTAssertNil(ApprovalRule.make(tool: "Edit", input: ["file_path": native(junction) + "\\secret.txt"], workingDirectory: proj))
    }

    func testDirectorySymlinkOutOfTheRootIsOutside() throws {
        guard let symlink = link("symlink", flag: "/D") else { throw XCTSkip("mklink /D needs the symlink privilege") }
        let sandbox = ToolSandbox(root: proj)
        XCTAssertNil(sandbox.resolve("symlink\\secret.txt"))
        XCTAssertNil(sandbox.resolve(native(symlink) + "\\new.txt"))
    }

    func testShortNameRootContainsLongNamePaths() throws {
        let long = native(base.appendingPathComponent("proj-evil"))
        let needed = long.withCString(encodedAs: UTF16.self) { GetShortPathNameW($0, nil, 0) }
        guard needed > 0 else { throw XCTSkip("no short name") }
        var buffer = [WCHAR](repeating: 0, count: Int(needed))
        let written = long.withCString(encodedAs: UTF16.self) { GetShortPathNameW($0, &buffer, needed) }
        let short = String(decoding: buffer[..<Int(written)], as: UTF16.self)
        guard short.uppercased() != long.uppercased() else { throw XCTSkip("8.3 names are off on this volume") }
        let sandbox = ToolSandbox(root: URL(fileURLWithPath: short, isDirectory: true))
        XCTAssertNotNil(sandbox.resolve(long + "\\a.txt"), "the same folder by its long name is inside (short \(short))")
        XCTAssertNil(sandbox.resolve(native(proj) + "\\a.txt"))
    }

    func testApprovalRulesForThePowerShellTool() {
        func rule(_ command: String) -> ApprovalRule? {
            ApprovalRule.make(tool: "PowerShell", input: ["command": command], workingDirectory: proj)
        }
        XCTAssertEqual(rule("git status")?.key, "PowerShell:git")
        XCTAssertEqual(rule("Get-ChildItem")?.key, "PowerShell:get-childitem")
        for unsafe in ["Remove-Item x", "DEL.EXE x", "iex x", "Get-Item $(x)", "git status; rm x", "git `\nx",
                       "& { rm x }", "powershell -EncodedCommand AAAA", "rm -r x", "cmd /c del x"] {
            XCTAssertNil(rule(unsafe), unsafe)
        }
        XCTAssertNotNil(ApprovalRule.make(tool: "Edit", input: ["file_path": native(proj) + "\\a.txt"], workingDirectory: proj))
        XCTAssertNil(ApprovalRule.make(tool: "Edit", input: ["file_path": native(base) + "\\proj-evil\\a.txt"], workingDirectory: proj))
        XCTAssertNil(ApprovalRule.make(tool: "Edit", input: ["file_path": native(proj) + "\\..\\other\\a.txt"], workingDirectory: proj))
    }
}
#endif
