import Foundation

/// Stops a process together with everything it started. Provider CLIs (`claude`, `copilot`) are node programs that
/// start their own children; stopping only the top process would leave those running and holding the working folder.
package enum ProcessTree {
    /// Ends `process` and all of its descendants. Blocks for at most about `grace` seconds plus the time to list
    /// processes. Does nothing when the process is not running.
    package static func terminate(_ process: Process, grace: TimeInterval = 1) {
        guard process.isRunning else { return }
        #if os(Windows)
        // taskkill walks the tree itself. Started by full path so a planted taskkill on PATH is never picked.
        let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: root + "\\System32\\taskkill.exe")
        killer.arguments = ["/T", "/F", "/PID", String(process.processIdentifier)]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        killer.standardInput = FileHandle.nullDevice
        // Waited for with ExitWatch, never waitUntilExit (which can miss the exit and never return).
        let killed = ExitWatch(killer)
        if (try? killer.run()) != nil {
            killed.started(killer)
            _ = killed.wait(for: killer)
        }
        if process.isRunning { process.terminate() }
        #else
        let root = process.processIdentifier
        // Freeze the tree first, so nothing forks or exits (and reparents its children) while it is collected.
        var pids = descendants(of: root, in: processTable())
        kill(root, SIGSTOP)
        for pid in pids { kill(pid, SIGSTOP) }
        for pid in descendants(of: root, in: processTable()) where !pids.contains(pid) {
            kill(pid, SIGSTOP)
            pids.append(pid)
        }
        let all = [root] + pids
        for pid in all { kill(pid, SIGTERM); kill(pid, SIGCONT) }
        let deadline = Date().addingTimeInterval(grace)
        func remaining() -> [Int32] {
            all.filter { $0 == root ? process.isRunning : kill($0, 0) == 0 }
        }
        while Date() < deadline, !remaining().isEmpty { Thread.sleep(forTimeInterval: 0.02) }
        for pid in remaining() { kill(pid, SIGKILL) }
        #endif
    }

    /// Every process below `pid` in a (pid, parent pid) table, children before grandchildren.
    static func descendants(of pid: Int32, in table: [(pid: Int32, ppid: Int32)]) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for row in table where row.pid != row.ppid { children[row.ppid, default: []].append(row.pid) }
        var result: [Int32] = []
        var seen: Set<Int32> = [pid]
        var queue = [pid]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            for child in children[next] ?? [] where seen.insert(child).inserted {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    #if !os(Windows)
    /// (pid, parent pid) for every process, from `ps`. Empty if `ps` cannot be run.
    static func processTable() -> [(pid: Int32, ppid: Int32)] {
        guard let ps = ["/bin/ps", "/usr/bin/ps"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ps)
        process.arguments = ["-A", "-o", "pid=", "-o", "ppid="]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        // End of output is all that is needed (its exit status is not used). No waitUntilExit: it can miss the exit
        // and never return, which here would leave a frozen (SIGSTOPped) tree and the caller stuck.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { return nil }
            return (pid, ppid)
        }
    }
    #endif
}
