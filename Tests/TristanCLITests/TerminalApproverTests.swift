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
        let later = TerminalApprover(interactive: false, mode: .ask, input: { XCTFail("should not ask"); return nil }, output: { _ in })
        XCTAssertTrue(later.approve(ApprovalRequest(summary: "Allow Bash?", detail: "ls src", rule: request.rule)))
        XCTAssertEqual(later.denials, 0)

        // Storing it again does not duplicate it; a request without a rule still asks.
        XCTAssertTrue(TerminalApprover(interactive: true, mode: .ask, input: { "always" }, output: { _ in }).approve(request))
        XCTAssertEqual(try JSONDecoder().decode([ApprovalRule].self, from: XCTUnwrap(memory.values["allowRules"] as? Data)).count, 1)
        XCTAssertFalse(later.approve(ApprovalRequest(summary: "Allow Bash?", detail: "rm x")))
        XCTAssertEqual(later.denials, 1)
    }

    func testAlwaysWithoutRuleAllowsOnce() {
        let approver = TerminalApprover(interactive: true, mode: .ask, input: { "a" }, output: { _ in })
        XCTAssertTrue(approver.approve(ApprovalRequest(summary: "Allow Write?", detail: "x")))
        XCTAssertNil(memory.values["allowRules"])
    }
}
