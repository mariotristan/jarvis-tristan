import XCTest
@testable import TristanCore

// Moved from Tests/TristanTests/MultiSessionTests.swift so the Windows CI runs them.

final class ConversationMemoryTests: XCTestCase {
    func testNothingRememberedLeavesTheTaskAlone() {
        XCTAssertEqual(ConversationMemory().compose(task: "add login", folder: "/a"), "add login")
    }

    func testBriefingCarriesEarlierMissionsOldestFirstAndTheNewTaskLast() {
        var memory = ConversationMemory()
        memory.record(task: "create auth.ts", actions: ["write_file auth.ts"], outcome: "Created auth.ts", status: "done", folder: "/a")
        memory.record(task: "add tests", actions: [], outcome: "Tests green", status: "done", folder: "/a")
        let text = memory.compose(task: "now rename login", folder: "/a")
        XCTAssertTrue(text.contains("create auth.ts"))
        XCTAssertTrue(text.contains("write_file auth.ts"))
        XCTAssertLessThan(text.range(of: "create auth.ts")!.lowerBound, text.range(of: "add tests")!.lowerBound)
        XCTAssertTrue(text.hasSuffix("now rename login"))
    }

    func testOtherFoldersAreNotMixedIn() {
        var memory = ConversationMemory()
        memory.record(task: "secret project work", actions: [], outcome: "ok", status: "done", folder: "/b")
        XCTAssertEqual(memory.compose(task: "hi", folder: "/a"), "hi")
    }

    func testOnlyTheLastMissionsArekeptAndOldOnesShrink() {
        var memory = ConversationMemory()
        for i in 1...20 { memory.record(task: "task \(i)", actions: ["a\(i)"], outcome: String(repeating: "x", count: 500), status: "done", folder: "/a") }
        XCTAssertEqual(memory.exchanges.count, ConversationMemory.maxExchanges)
        let text = memory.compose(task: "next", folder: "/a")
        XCTAssertFalse(text.contains("task 1 "))
        XCTAssertTrue(text.contains("Actions: a20"))
        XCTAssertFalse(text.contains("Actions: a10"), "older missions are reduced to one line")
        XCTAssertLessThan(text.count, ConversationMemory.maxBriefing + 400)
    }

    func testCodableRoundTrip() throws {
        var memory = ConversationMemory()
        memory.record(task: "t", actions: ["x"], outcome: "o", status: "done", folder: "/a")
        let again = try JSONDecoder().decode(ConversationMemory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(again, memory)
    }
}
