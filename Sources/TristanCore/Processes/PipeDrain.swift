import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
        var read: DWORD = 0
        let ok = buffer.withUnsafeMutableBytes { ReadFile(handle._handle, $0.baseAddress, DWORD($0.count), &read, nil) }
        if ok { return Int(read) }
        return GetLastError() == DWORD(109) /* ERROR_BROKEN_PIPE: every writer closed */ ? 0 : nil
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
