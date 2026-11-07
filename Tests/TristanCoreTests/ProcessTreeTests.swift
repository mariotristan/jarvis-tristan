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

    /// Abort in the Mac app cancels from the main thread: `terminate()` must not block while the tree dies.
    func testTerminateReturnsQuicklyAndTheTreeStillDies() throws {
        let box = ProcessBox()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-tree-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        // The parent ignores SIGTERM, so a synchronous kill would wait out the whole grace period.
        process.arguments = ["-c", "trap '' TERM; sleep 30 & echo $! > '\(pidFile.path)'; wait; wait"]
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        XCTAssertTrue(try box.start(process))
        XCTAssertTrue(eventually { ((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").hasSuffix("\n") })
        let child = Int32(((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let start = Date()
        box.terminate()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "terminate() blocked its caller")
        XCTAssertTrue(eventually(4) { !process.isRunning && !self.isAlive(child) })
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

#if os(Windows)
import WinSDK

final class ProcessTreeWindowsTests: XCTestCase {
    /// True while `tasklist` lists the pid.
    private func isAlive(_ pid: Int32) -> Bool {
        let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        let tasklist = Process()
        tasklist.executableURL = URL(fileURLWithPath: root + "\\System32\\tasklist.exe")
        tasklist.arguments = ["/FI", "PID eq \(pid)", "/NH", "/FO", "CSV"]
        let out = Pipe()
        tasklist.standardOutput = out
        tasklist.standardError = FileHandle.nullDevice
        tasklist.standardInput = FileHandle.nullDevice
        guard (try? tasklist.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        tasklist.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("\"\(pid)\"")
    }

    private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }

    /// Brief Step 4 on Windows: a PowerShell parent starts a sleeping PowerShell child; cancelling through the box
    /// must stop both (taskkill /T).
    func testCancelTerminatesProcessTreeOnWindows() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-tree-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "$c = Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 30' "
            + "-NoNewWindow -PassThru; Set-Content -LiteralPath '\(pidFile.path)' -Value $c.Id; Wait-Process -Id $c.Id"
        let process = try ProcessLauncher.prepare("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script],
                                                  directory: nil, extraEnvironment: [:])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let box = ProcessBox()
        XCTAssertTrue(try box.start(process))
        func childPid() -> Int32? {
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return nil }
            return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        XCTAssertTrue(eventually(15) { childPid() != nil }, "the child never wrote its pid")
        let child = try XCTUnwrap(childPid())
        XCTAssertTrue(isAlive(child))
        box.terminate()
        XCTAssertTrue(eventually { !process.isRunning && !self.isAlive(child) }, "parent or child still running")
    }
}
#endif
