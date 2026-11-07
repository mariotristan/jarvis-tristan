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
}
