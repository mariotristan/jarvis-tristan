import XCTest
@testable import TristanCore

// Moved from Tests/TristanTests/BacklogTests.swift so the Windows CI runs them.

final class HistoryTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tristan-history-\(UUID().uuidString.prefix(8))/history.json")
    }

    func testRoundTripAndPrivatePermissions() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HistoryStore(url: url)
        XCTAssertEqual(store.load(), [])
        let record = MissionRecord(task: "add login", provider: "CLAUDE", mode: "ASK", status: "done", summary: "ok", folder: "/tmp/x")
        store.save([record])
        XCTAssertEqual(store.load().first?.task, "add login")
        #if !os(Windows)   // Windows has no POSIX mode bits; the file sits in the user's own profile folder instead
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600, "history may contain task text, so keep it private")
        #endif
    }

    func testLimitKeepsTheNewestRecords() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HistoryStore(url: url, limit: 3)
        store.save((0..<10).map { MissionRecord(task: "t\($0)", provider: "DEMO", mode: "ASK", status: "done", summary: "", folder: "/") })
        XCTAssertEqual(store.load().map(\.task), ["t0", "t1", "t2"], "records are stored newest first")
    }

    func testCorruptFileLoadsAsEmpty() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(HistoryStore(url: url).load(), [])
    }
}

final class HistoryFilterTests: XCTestCase {
    private let records = [
        MissionRecord(task: "add login to the API", provider: "CLAUDE", mode: "ASK", status: "done", summary: "Added auth.ts", folder: "/code/my-api"),
        MissionRecord(task: "upgrade dependencies", provider: "COPILOT", mode: "ASK", status: "failed", summary: "Denied by operator", folder: "/code/my-api"),
        MissionRecord(task: "write a README", provider: "AZURE", mode: "YOLO", status: "aborted", summary: "Aborted by operator", folder: "/code/scripts"),
    ]

    func testEmptyQueryAndAllShowsEverything() {
        XCTAssertEqual(records.filtered(query: "", status: .all).count, 3)
    }

    func testStatusFilter() {
        XCTAssertEqual(records.filtered(query: "", status: .failed).map(\.task), ["upgrade dependencies"])
        XCTAssertEqual(records.filtered(query: "", status: .aborted).count, 1)
    }

    func testEveryWordMustMatchAcrossAllFieldsIgnoringCase() {
        XCTAssertEqual(records.filtered(query: "LOGIN api", status: .all).count, 1)
        XCTAssertEqual(records.filtered(query: "copilot denied", status: .all).count, 1)
        XCTAssertEqual(records.filtered(query: "my-api", status: .all).count, 2, "matches the folder name")
        XCTAssertEqual(records.filtered(query: "yolo readme", status: .all).count, 1)
        XCTAssertTrue(records.filtered(query: "login scripts", status: .all).isEmpty)
    }

    func testSearchAndStatusCombine() {
        XCTAssertEqual(records.filtered(query: "operator", status: .failed).count, 1)
        XCTAssertTrue(records.filtered(query: "login", status: .failed).isEmpty)
    }
}
