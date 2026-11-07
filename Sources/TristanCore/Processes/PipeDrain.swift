import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Waits for a started process to end, without `Process.waitUntilExit`.
///
/// `waitUntilExit` turned out not to be safe to rely on: on the Mac it now and then never returned for a command that
/// had already exited (the thread sat in its run loop, seen in full test runs), and on Windows it did not return after
/// the tree kill until a child that escaped the kill closed the output pipe. Here the end is noticed by whichever
/// comes first: the termination handler, `isRunning` turning false (checked every 50 ms), or on Windows the process
/// handle itself becoming signalled (WaitForSingleObject), with the exit code read from that handle.
final class ExitWatch: @unchecked Sendable {
    private let ended = DispatchSemaphore(value: 0)
    #if os(Windows)
    private var handle: HANDLE?
    #endif

    /// Call before the process is started: installs the termination handler.
    init(_ process: Process) {
        process.terminationHandler = { [ended] _ in ended.signal() }
    }

    /// Call once the process has started.
    func started(_ process: Process) {
        #if os(Windows)
        // SYNCHRONIZE (0x00100000) | PROCESS_QUERY_LIMITED_INFORMATION (0x1000)
        handle = OpenProcess(DWORD(0x0010_1000), false, DWORD(process.processIdentifier))
        #endif
    }

    /// Blocks until the process has ended; returns its exit status.
    func wait(for process: Process) -> Int32 {
        #if os(Windows)
        // The handle was opened by PID after the start. Never wait on it alone: in 50 ms slices, Foundation's own
        // signals (termination handler, isRunning) are checked too, and they win when they come first.
        if let handle {
            defer { CloseHandle(handle); self.handle = nil }
            while true {
                if ended.wait(timeout: .now()) == .success { ended.signal(); break }
                if !process.isRunning { break }
                if WaitForSingleObject(handle, 50) == DWORD(0) /* WAIT_OBJECT_0 */ {
                    var code: DWORD = 0
                    if GetExitCodeProcess(handle, &code) { return Int32(bitPattern: code) }
                    break
                }
            }
        }
        #endif
        while ended.wait(timeout: .now() + 0.05) == .timedOut, process.isRunning {}
        return process.terminationStatus
    }
}

/// Reads everything written to a pipe on a thread of its own, so the reader can stop waiting for end of file.
///
/// End of file only comes when every process holding the pipe's write end has closed it. A process a command started
/// and left behind (or one that escaped the tree kill, its parent gone) can keep it open long after the command
/// ended; `collect(within:)` returns what has arrived by then instead of blocking until that process exits. The
/// reading thread itself ends when the pipe finally closes.
final class PipeDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var capped = false
    private let finished = DispatchSemaphore(value: 0)

    /// Keeps at most `limit` bytes (later output is read and dropped, so the writer never blocks on a full pipe).
    init(_ handle: FileHandle, limit: Int = 1 << 20) {
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while let count = Self.readSome(handle, into: &buffer), count > 0 {
                lock.lock()
                let room = max(0, limit - data.count)
                if count > room { capped = true }
                if room > 0 { data.append(contentsOf: buffer[..<min(count, room)]) }
                lock.unlock()
            }
            finished.signal()
        }
        thread.name = "tristan.pipe.drain"
        thread.start()
    }

    /// Waits at most `grace` for end of file. `complete` is false when the pipe was still open (what arrived so far is
    /// returned); `capped` is true when output past the limit was dropped.
    func collect(within grace: TimeInterval) -> (data: Data, complete: Bool, capped: Bool) {
        let complete = finished.wait(timeout: .now() + grace) == .success
        lock.lock(); defer { lock.unlock() }
        return (data, complete, capped)
    }

    /// One blocking read: the byte count (0 at end of file), or nil on a read error (treated as the end).
    private static func readSome(_ handle: FileHandle, into buffer: inout [UInt8]) -> Int? {
        #if os(Windows)
        while true {
            var read: DWORD = 0
            let ok = buffer.withUnsafeMutableBytes { ReadFile(handle._handle, $0.baseAddress, DWORD($0.count), &read, nil) }
            // On a pipe a successful read of 0 bytes is a zero-length write, not the end: only a broken pipe is.
            // (On a file it is the end.) FILE_TYPE_PIPE is 3.
            if ok, read == 0, GetFileType(handle._handle) == DWORD(3) { Thread.sleep(forTimeInterval: 0.001); continue }
            if ok { return Int(read) }
            return GetLastError() == DWORD(109) /* ERROR_BROKEN_PIPE: every writer closed */ ? 0 : nil
        }
        #else
        while true {
            let count = buffer.withUnsafeMutableBytes { read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if count >= 0 { return count }
            if errno == EINTR { continue }
            return nil
        }
        #endif
    }
}
