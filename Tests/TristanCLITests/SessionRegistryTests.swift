import XCTest
@testable import TristanCLICore

final class SessionRegistryTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    func testRegistryListsAliveAndDropsStale() {
        let registry = SessionRegistry(directory: dir, isAlive: { $0 == 100 })
        registry.register(pid: 100, task: "alive task", provider: "ollama", folder: "/work")
        registry.register(pid: 200, task: "stale task", provider: "claude", folder: "/old")
        XCTAssertEqual(files(), ["100.json", "200.json"])
        let active = registry.active()
        XCTAssertEqual(active.map(\.pid), [100])
        XCTAssertEqual(active.first?.task, "alive task")
        XCTAssertEqual(active.first?.provider, "ollama")
        XCTAssertEqual(active.first?.folder, "/work")
        XCTAssertEqual(files(), ["100.json"])
    }

    func testRegistryUnregisterOnExit() {
        let registry = SessionRegistry(directory: dir, isAlive: { _ in true })
        registry.register(pid: 7, task: "t", provider: "ollama", folder: "/f")
        XCTAssertEqual(registry.active().count, 1)
        registry.unregister(pid: 7)
        XCTAssertTrue(registry.active().isEmpty)
        XCTAssertEqual(files(), [])
    }

    func testCorruptRegistryFileIgnoredAndRemoved() throws {
        let registry = SessionRegistry(directory: dir, isAlive: { _ in true })
        registry.register(pid: 1, task: "good", provider: "ollama", folder: "/f")
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("2.json"))
        XCTAssertEqual(registry.active().map(\.pid), [1])
        XCTAssertEqual(files(), ["1.json"])
    }

    func testTaskTruncatedTo200() {
        let registry = SessionRegistry(directory: dir, isAlive: { _ in true })
        registry.register(pid: 3, task: String(repeating: "x", count: 500), provider: "ollama", folder: "/f")
        XCTAssertEqual(registry.active().first?.task.count, 200)
    }

    func testMissingDirectoryIsEmpty() {
        XCTAssertTrue(SessionRegistry(directory: dir, isAlive: { _ in true }).active().isEmpty)
    }
}
