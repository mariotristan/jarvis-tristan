// Apple's Foundation streams bytes with `URLSession.bytes(for:)`, `FileHandle.bytes` and `.lines`. The open-source
// Foundation used on Windows and Linux has none of the three, so this file supplies them there with the same shape
// (`for try await byte in bytes`, `for try await line in bytes.lines`). On Apple platforms it compiles to nothing.
#if !canImport(Darwin)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif

/// A stream of bytes fed by chunks as they arrive.
package struct PortableAsyncBytes: AsyncSequence, Sendable {
    package typealias Element = UInt8
    let chunks: AsyncThrowingStream<Data, Error>

    package struct AsyncIterator: AsyncIteratorProtocol {
        var chunks: AsyncThrowingStream<Data, Error>.AsyncIterator
        var buffer: [UInt8] = []
        var index = 0

        package mutating func next() async throws -> UInt8? {
            while index >= buffer.count {
                try Task.checkCancellation()
                // A cancelled consumer ends the stream early; like Apple's AsyncBytes, report that as cancellation
                // rather than as a normal end of the body.
                guard let chunk = try await chunks.next() else {
                    try Task.checkCancellation()
                    return nil
                }
                buffer = [UInt8](chunk)
                index = 0
            }
            defer { index += 1 }
            return buffer[index]
        }
    }

    package func makeAsyncIterator() -> AsyncIterator { AsyncIterator(chunks: chunks.makeAsyncIterator()) }
}

/// Lines of UTF-8 text, split at LF, CR LF or CR, without the line ending. Empty lines are skipped, as Apple's
/// `AsyncLineSequence` does.
package struct PortableAsyncLines<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    package typealias Element = String
    let base: Base

    package struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        var pendingCR = false
        var finished = false

        package mutating func next() async throws -> String? {
            var line: [UInt8] = []
            while !finished {
                guard let byte = try await base.next() else {
                    finished = true
                    break
                }
                if pendingCR {
                    pendingCR = false
                    if byte == 10 { continue }   // the LF of a CR LF
                }
                if byte == 10 || byte == 13 {
                    pendingCR = byte == 13
                    if line.isEmpty { continue }
                    return String(decoding: line, as: UTF8.self)
                }
                line.append(byte)
            }
            return line.isEmpty ? nil : String(decoding: line, as: UTF8.self)
        }
    }

    package func makeAsyncIterator() -> AsyncIterator { AsyncIterator(base: base.makeAsyncIterator()) }
}

extension AsyncSequence where Element == UInt8 {
    package var lines: PortableAsyncLines<Self> { PortableAsyncLines(base: self) }
}

extension URLSession {
    /// Starts `request` and returns once the response head has arrived; the body follows as it is received.
    /// Uses a private session with this session's configuration, so a delegate can see each chunk.
    package func bytes(for request: URLRequest) async throws -> (PortableAsyncBytes, URLResponse) {
        let (chunks, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let receiver = StreamingReceiver(chunks: continuation)
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        let task = session.dataTask(with: request)
        continuation.onTermination = { _ in
            task.cancel()
            session.invalidateAndCancel()
        }
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<URLResponse, Error>) in
                receiver.setWaiter(waiter)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (PortableAsyncBytes(chunks: chunks), response)
    }
}

/// The delegate behind `URLSession.bytes(for:)`: hands over the response head once, then every body chunk.
private final class StreamingReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<URLResponse, Error>?
    private var earlyResult: Result<URLResponse, Error>?
    private let chunks: AsyncThrowingStream<Data, Error>.Continuation

    init(chunks: AsyncThrowingStream<Data, Error>.Continuation) {
        self.chunks = chunks
    }

    func setWaiter(_ waiter: CheckedContinuation<URLResponse, Error>) {
        lock.lock()
        if let earlyResult {
            self.earlyResult = nil
            lock.unlock()
            waiter.resume(with: earlyResult)
            return
        }
        self.waiter = waiter
        lock.unlock()
    }

    /// Resumes the waiter once; a result that comes before the waiter is kept for it.
    private func deliver(_ result: Result<URLResponse, Error>) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(with: result)
            return
        }
        if earlyResult == nil { earlyResult = result }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        deliver(.success(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        chunks.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            deliver(.failure(error))
            chunks.finish(throwing: error)
        } else {
            if let response = task.response { deliver(.success(response)) } else { deliver(.failure(URLError(.badServerResponse))) }
            chunks.finish()
        }
        session.finishTasksAndInvalidate()
    }
}

/// A failed read in `FileHandle.bytes`.
package struct FileReadError: Error, LocalizedError {
    package let code: Int
    package var errorDescription: String? { "reading from the process failed (error \(code))" }
}

extension FileHandle {
    /// Everything read from this handle until end of file, chunk by chunk, read on a thread of its own.
    /// Each chunk is one system read (whatever has arrived), not `read(upToCount:)`, which waits for the full count;
    /// `availableData` is not used because Foundation stops the program on a read error there.
    package var bytes: PortableAsyncBytes {
        let (chunks, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                switch readSome(into: &buffer) {
                case .success(0):
                    continuation.finish()
                    return
                case .success(let count):
                    continuation.yield(Data(buffer[..<count]))
                case .failure(let error):
                    continuation.finish(throwing: error)
                    return
                }
            }
        }
        thread.name = "tristan.filehandle.bytes"
        thread.start()
        return PortableAsyncBytes(chunks: chunks)
    }

    /// One blocking read: the byte count (0 at end of file) or the error.
    private func readSome(into buffer: inout [UInt8]) -> Result<Int, FileReadError> {
        #if os(Windows)
        var read: DWORD = 0
        let ok = buffer.withUnsafeMutableBytes { ReadFile(_handle, $0.baseAddress, DWORD($0.count), &read, nil) }
        if ok { return .success(Int(read)) }
        let error = GetLastError()
        return error == DWORD(109) /* ERROR_BROKEN_PIPE: the writer closed */ ? .success(0) : .failure(FileReadError(code: Int(error)))
        #else
        while true {
            let count = buffer.withUnsafeMutableBytes { Glibc.read(fileDescriptor, $0.baseAddress, $0.count) }
            if count >= 0 { return .success(count) }
            if errno == EINTR { continue }
            return .failure(FileReadError(code: Int(errno)))
        }
        #endif
    }
}
#endif
