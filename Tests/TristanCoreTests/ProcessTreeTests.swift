import XCTest
@testable import TristanCore

#if !os(Windows)
final class ProcessTreeTests: XCTestCase {
    private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// Polls for up to `seconds` until `condition` holds.
    private func eventually(_ seconds: Double = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    /// A shell that starts a sleeping child, prints the child's pid and waits for it.
    private func shellWithChild() throws -> (Process, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30 & echo $!; wait"]
        let out = Pipe()
        process.standardOutput = out
        process.standardInput = FileHandle.nullDevice
        try process.run()
        var text = ""
        let handle = out.fileHandleForReading
        while !text.contains("\n") {
            let data = handle.availableData
            if data.isEmpty { break }
            text += String(decoding: data, as: UTF8.self)
        }
        let child = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(child, 0)
        return (process, child)
    }

    func testDescendantsWalkTheWholeTree() {
        let table: [(pid: Int32, ppid: Int32)] = [(10, 1), (11, 10), (12, 11), (13, 10), (20, 1), (21, 20)]
        XCTAssertEqual(Set(ProcessTree.descendants(of: 10, in: table)), [11, 12, 13])
        XCTAssertEqual(ProcessTree.descendants(of: 21, in: table), [])
    }

    func testCancelTerminatesProcessTree() throws {
        let (process, child) = try shellWithChild()
        XCTAssertTrue(isAlive(child))
        ProcessTree.terminate(process)
        XCTAssertTrue(eventually { !process.isRunning && !self.isAlive(child) }, "parent or child still running")
    }

    func testBoxTerminateStopsTheWholeTree() throws {
        let box = ProcessBox()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-tree-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        process.arguments = ["-c", "sleep 30 & echo $! > '\(pidFile.path)'; wait"]
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        XCTAssertTrue(try box.start(process))
        XCTAssertTrue(eventually { ((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").hasSuffix("\n") })
        let child = Int32(((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(child, 0)
        box.terminate()
        XCTAssertTrue(eventually { !process.isRunning && !self.isAlive(child) })
    }

    func testBoxCancelledFirstNeverStarts() throws {
        let box = ProcessBox()
        box.terminate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        XCTAssertFalse(try box.start(process))
        XCTAssertFalse(process.isRunning)
    }

    /// The M-4 race: `terminate()` arriving while `run()` is in progress must still stop the process.
    func testCancelDuringStartStillStopsTheProcess() throws {
        let box = ProcessBox()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardInput = FileHandle.nullDevice
        let started = DispatchSemaphore(value: 0)
        let finished = expectation(description: "start returned")
        DispatchQueue.global().async {
            // A slow start: the cancel below arrives after the box accepted the process, before run() returned.
            _ = try? box.start(process) { process in
                started.signal()
                Thread.sleep(forTimeInterval: 0.3)
                try process.run()
            }
            finished.fulfill()
        }
        started.wait()
        box.terminate()
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(eventually { !process.isRunning }, "the process started after cancel kept running")
    }

    func testCancelledClaudeRunStopsItsChildren() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pidFile = folder.appendingPathComponent("child.pid")
        let script = folder.appendingPathComponent("fake-claude")
        try "#!/bin/sh\nsleep 30 &\necho $! > '\(pidFile.path)'\necho '{\"type\":\"system\",\"subtype\":\"init\"}'\nwait\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var provider = ClaudeCodeProvider(mode: .yolo)
        provider.claudeTool = script.path
        let consumer = Task {
            for await _ in provider.run(task: "x", workingDirectory: folder, approve: { _ in false }) {}
        }
        XCTAssertTrue(eventually(5) { ((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").hasSuffix("\n") })
        let child = Int32(((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(child, 0)
        consumer.cancel()
        _ = await consumer.value
        XCTAssertTrue(eventually { !self.isAlive(child) }, "claude's child survived the cancel")
    }

    func testTerminateAllStopsLiveBoxes() throws {
        let box = ProcessBox()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardInput = FileHandle.nullDevice
        XCTAssertTrue(try box.start(process))
        ProcessBox.terminateAll()
        XCTAssertTrue(eventually { !process.isRunning })
    }
}
#endif
