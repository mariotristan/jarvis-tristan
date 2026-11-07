import XCTest
import TristanCore
@testable import TristanCLICore

private struct Scripted: AgentProvider {
    var events: [AgentEvent]
    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AsyncStream { c in for e in events { c.yield(e) }; c.finish() }
    }
}

/// Never finishes on its own; ends when the consumer is cancelled.
private struct Endless: AgentProvider {
    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AsyncStream { c in c.yield(.status("THINKING")) }
    }
}

private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func add(_ s: String) { lock.lock(); text += s; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(CLIProvider, ApprovalMode)] = []
    func add(_ p: CLIProvider, _ m: ApprovalMode) { lock.lock(); items.append((p, m)); lock.unlock() }
    var value: [(CLIProvider, ApprovalMode)] { lock.lock(); defer { lock.unlock() }; return items }
}

private struct RecordingProvider: AgentProvider {
    let sink: Sink
    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        sink.add("\(task)@\(workingDirectory.standardizedFileURL.path)")
        return AsyncStream { c in c.yield(.done("ok")); c.finish() }
    }
}

final class HistoryCommandTests: XCTestCase {
    private var saved: SettingsBackend!
    private var scratch: URL!
    private var historyURL: URL { scratch.appendingPathComponent("history.json") }
    private var store: HistoryStore { HistoryStore(url: historyURL) }
    private var registry: SessionRegistry!

    override func setUp() {
        saved = Settings.backend
        Settings.backend = MemoryBackend()
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        registry = SessionRegistry(directory: scratch.appendingPathComponent("sessions"), isAlive: { _ in true })
    }
    override func tearDown() {
        Settings.backend = saved
        try? FileManager.default.removeItem(at: scratch)
    }

    private func env(_ provider: @escaping (CLIProvider, ApprovalMode) -> AgentProvider = { _, _ in Scripted(events: [.done("ok")]) })
        -> CLIEnvironment {
        CLIEnvironment(interactive: false, readPIN: { _ in nil }, makeProvider: provider, installInterrupt: false,
                       historyURL: historyURL, sessions: registry)
    }

    private func exec(_ arguments: [String], _ environment: CLIEnvironment) async throws -> (ExitCode, String) {
        let out = Sink()
        Terminal.capture = { out.add($0) }
        defer { Terminal.capture = nil }
        let command = try XCTUnwrap(TristanCommand.parseAsRoot(arguments) as? CLICommand)
        return (await command.execute(environment: environment), out.value)
    }

    private func record(_ task: String, status: String = "done", summary: String = "s", provider: String = "ollama",
                        folder: String = "/nowhere/at/all") -> MissionRecord {
        MissionRecord(task: task, provider: provider, mode: "ASK", status: status, summary: summary, folder: folder)
    }

    func testHistoryFilterByQueryAndStatus() async throws {
        store.save([record("fix login bug"), record("write docs", status: "failed"), record("fix docs typo", status: "failed")])
        let (code, all) = try await exec(["history"], env())
        XCTAssertEqual(code, .ok)
        XCTAssertTrue(all.contains("fix login bug") && all.contains("write docs") && all.contains("fix docs typo"), all)
        let (_, byQuery) = try await exec(["history", "--query", "docs"], env())
        XCTAssertFalse(byQuery.contains("login"), byQuery)
        XCTAssertTrue(byQuery.contains("write docs") && byQuery.contains("fix docs typo"))
        let (_, byBoth) = try await exec(["history", "--query", "fix", "--status", "failed"], env())
        XCTAssertTrue(byBoth.contains("fix docs typo"))
        XCTAssertFalse(byBoth.contains("login") || byBoth.contains("write docs"), byBoth)
    }

    func testEmptyHistoryMessage() async throws {
        let (code, out) = try await exec(["history"], env())
        XCTAssertEqual(code, .ok)
        XCTAssertTrue(out.contains("No missions"), out)
    }

    func testHistoryOutputIsSanitised() async throws {
        store.save([record("evil \u{1B}[2K task", summary: "sum\u{1B}[31m")])
        let (_, out) = try await exec(["history"], env())
        XCTAssertFalse(out.contains("\u{1B}"), out)
        XCTAssertTrue(out.contains("evil"))
    }

    func testRunRecordsMission() async throws {
        let provider = Scripted(events: [.code("func secret() { let key = \"hunter2\" }\n"), .log("read a.swift"),
                                         .done("Explained the project")])
        let (code, _) = try await exec(["run", "--folder", scratch.path, "explain this"], env { _, _ in provider })
        XCTAssertEqual(code, .ok)
        let records = store.load()
        XCTAssertEqual(records.count, 1)
        let r = try XCTUnwrap(records.first)
        XCTAssertEqual(r.task, "explain this")
        XCTAssertEqual(r.status, "done")
        XCTAssertEqual(r.summary, "Explained the project")
        XCTAssertEqual(r.provider, "ollama")
        XCTAssertEqual(r.mode, "ASK")
        let raw = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("hunter2") || raw.contains("func secret"), raw)
        XCTAssertTrue(registry.active().isEmpty)
    }

    func testRunRecordsFailureAndTruncatesSummary() async throws {
        let provider = Scripted(events: [.failed(String(repeating: "z", count: 1000))])
        let (code, _) = try await exec(["run", "--folder", scratch.path, "t"], env { _, _ in provider })
        XCTAssertEqual(code, .failed)
        let r = try XCTUnwrap(store.load().first)
        XCTAssertEqual(r.status, "failed")
        XCTAssertEqual(r.summary.count, 240)
    }

    func testRunWithoutAnyEventRecordsNothing() async throws {
        _ = try await exec(["run", "--folder", scratch.path, "t"], env { _, _ in Scripted(events: []) })
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertTrue(registry.active().isEmpty)
    }

    func testRunRegistersWhileRunning() async throws {
        let seen = Sink()
        let reg = registry!
        let provider = Scripted(events: [.done("ok")])
        _ = try await exec(["run", "--folder", scratch.path, "t"], env { _, _ in
            seen.add(reg.active().map { "\($0.task)|\($0.provider)" }.joined()); return provider })
        XCTAssertEqual(seen.value, "t|ollama")
        XCTAssertTrue(registry.active().isEmpty)
    }

    func testCancelledRunRecordsAndUnregisters() async throws {
        let command = try XCTUnwrap(TristanCommand.parseAsRoot(["run", "--folder", scratch.path, "long job"]) as? CLICommand)
        let environment = env { _, _ in Endless() }
        let reg = registry!
        let task = Task { await command.execute(environment: environment) }
        for _ in 0..<300 where reg.active().isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(reg.active().count, 1)
        task.cancel()
        _ = await task.value
        let r = try XCTUnwrap(store.load().first)
        XCTAssertEqual(r.status, "aborted")
        XCTAssertEqual(r.task, "long job")
        XCTAssertTrue(reg.active().isEmpty)
    }

    func testRerunOutOfRangeIsUsageError() async throws {
        store.save([record("one")])
        let (code, _) = try await exec(["history", "--rerun", "2"], env())
        XCTAssertEqual(code, .usage)
        let (zero, _) = try await exec(["history", "--rerun", "0"], env())
        XCTAssertEqual(zero, .usage)
    }

    func testRerunUsesRecordsTaskProviderAndFolder() async throws {
        let seen = Seen()
        store.save([record("newest task", provider: "claude", folder: scratch.path), record("older task")])
        let ran = Sink()
        let provider = RecordingProvider(sink: ran)
        let (code, _) = try await exec(["history", "--rerun", "1"], env { p, m in seen.add(p, m); return provider })
        XCTAssertEqual(code, .ok)
        XCTAssertEqual(ran.value, "newest task@\(URL(fileURLWithPath: scratch.path).standardizedFileURL.path)")
        XCTAssertEqual(seen.value.first?.0, .claude)
        XCTAssertEqual(seen.value.first?.1, .ask)
        XCTAssertEqual(store.load().count, 3)
    }

    func testRerunWithMissingFolderRefusesAndNeverStartsProvider() async throws {
        let seen = Seen()
        store.save([record("task", provider: "claude", folder: "/does/not/exist")])
        let (code, _) = try await exec(["history", "--rerun", "1"], env { p, m in seen.add(p, m); return Scripted(events: [.done("ok")]) })
        XCTAssertEqual(code, .usage)
        XCTAssertTrue(seen.value.isEmpty)
        XCTAssertEqual(store.load().count, 1)
        XCTAssertTrue(registry.active().isEmpty)
    }

    func testRerunWithMissingFolderRunsInExplicitFolder() async throws {
        let seen = Seen()
        store.save([record("task", provider: "weird", folder: "/does/not/exist")])
        let ran = Sink()
        let provider = RecordingProvider(sink: ran)
        let (code, _) = try await exec(["history", "--rerun", "1", "--folder", scratch.path], env { p, m in seen.add(p, m); return provider })
        XCTAssertEqual(code, .ok)
        XCTAssertEqual(seen.value.first?.0, .ollama)
        XCTAssertEqual(ran.value, "task@\(URL(fileURLWithPath: scratch.path).standardizedFileURL.path)")
    }

    func testRerunWithNonexistentExplicitFolderIsUsage() async throws {
        let seen = Seen()
        store.save([record("task", folder: scratch.path)])
        let (code, _) = try await exec(["history", "--rerun", "1", "--folder", "/also/not/there"], env { p, m in seen.add(p, m); return Scripted(events: []) })
        XCTAssertEqual(code, .usage)
        XCTAssertTrue(seen.value.isEmpty)
    }

    func testFolderWithoutRerunIsUsage() throws {
        XCTAssertThrowsError(try TristanCommand.parseAsRoot(["history", "--folder", scratch.path]))
    }

    func testRerunIsRefusedInKidsModeForCloudProvider() async throws {
        Settings.set(true, forKey: "kidsMode")
        let seen = Seen()
        store.save([record("task", provider: "claude", folder: scratch.path)])
        let (code, _) = try await exec(["history", "--rerun", "1"], env { p, m in seen.add(p, m); return Scripted(events: [.done("ok")]) })
        XCTAssertEqual(code, .usage)
        XCTAssertTrue(seen.value.isEmpty)
        XCTAssertEqual(store.load().count, 1)
    }

    /// A settings file that cannot be read counts as kids mode on for a rerun too.
    func testRerunIsRefusedForCloudProviderWhenSettingsAreCorrupt() async throws {
        let url = scratch.appendingPathComponent("settings.json")
        let garbage = Data([0xFF, 0x00, 0x7B, 0x22])
        try garbage.write(to: url)
        Settings.backend = JSONFileBackend(url: url)
        let seen = Seen()
        store.save([record("task", provider: "claude", folder: scratch.path)])
        let (code, _) = try await exec(["history", "--rerun", "1"], env { p, m in seen.add(p, m); return Scripted(events: [.done("ok")]) })
        XCTAssertEqual(code, .usage)
        XCTAssertTrue(seen.value.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), garbage)
    }

    func testHistoryStatusAndProviderFieldsAreSanitised() async throws {
        store.save([record("t", status: "do\u{1B}[2Kne", provider: "pro\u{1B}[2Kv")])
        let (_, out) = try await exec(["history"], env())
        XCTAssertFalse(out.contains("\u{1B}"), out)
        XCTAssertTrue(out.contains("do"))
    }
}

final class SessionsCommandTests: XCTestCase {
    func testSessionsListsSanitisedAndEmpty() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = SessionRegistry(directory: dir, isAlive: { _ in true })
        let env = CLIEnvironment(interactive: false, readPIN: { _ in nil }, makeProvider: { _, _ in Scripted(events: []) },
                                 installInterrupt: false, historyURL: dir.appendingPathComponent("h.json"), sessions: registry)
        let out = Sink()
        Terminal.capture = { out.add($0) }
        defer { Terminal.capture = nil }
        let command = try XCTUnwrap(TristanCommand.parseAsRoot(["sessions"]) as? CLICommand)
        let code = await command.execute(environment: env); XCTAssertEqual(code, .ok)
        XCTAssertTrue(out.value.contains("No active sessions."))
        registry.register(pid: 42, task: "do \u{1B}[2K it", provider: "claude", folder: "/w")
        let out2 = Sink()
        Terminal.capture = { out2.add($0) }
        let code2 = await command.execute(environment: env); XCTAssertEqual(code2, .ok)
        XCTAssertTrue(out2.value.contains("42") && out2.value.contains("claude") && out2.value.contains("/w"), out2.value)
        XCTAssertFalse(out2.value.contains("\u{1B}"))
    }

    func testSessionsProviderFieldIsSanitised() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = SessionRegistry(directory: dir, isAlive: { _ in true })
        registry.register(pid: 5, task: "t", provider: "cla\u{1B}[2Kude", folder: "/w")
        let env = CLIEnvironment(interactive: false, readPIN: { _ in nil }, makeProvider: { _, _ in Scripted(events: []) },
                                 installInterrupt: false, historyURL: dir.appendingPathComponent("h.json"), sessions: registry)
        let out = Sink()
        Terminal.capture = { out.add($0) }
        defer { Terminal.capture = nil }
        let command = try XCTUnwrap(TristanCommand.parseAsRoot(["sessions"]) as? CLICommand)
        let code = await command.execute(environment: env)
        XCTAssertEqual(code, .ok)
        XCTAssertFalse(out.value.contains("\u{1B}"), out.value)
        XCTAssertTrue(out.value.contains("cla"))
    }
}
