import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TristanCore

/// `URLSession.bytes(for:)` as the providers use it: Apple's on the Mac, the AsyncBytesCompat one on Windows. A local
/// server (the approval transport's loopback socket) writes one line, waits, then writes another.
final class HTTPStreamingTests: XCTestCase {
    /// Serves one request on 127.0.0.1 with a chunked body: each element of `chunks` after `pause` seconds.
    private func serve(status: String, contentType: String, chunks: [String], pause: TimeInterval) throws -> (port: UInt16, done: XCTestExpectation) {
        let listener = try XCTUnwrap(Socket.listenLoopback())
        let port = try XCTUnwrap(listener.localIPv4()?.port)
        let done = expectation(description: "served")
        Thread {
            defer { listener.shutdownAndClose(); done.fulfill() }
            guard let client = listener.acceptClient() else { return }
            let connection = LineConnection(socket: client)
            // The request head ends with an empty line.
            while let line = connection.readLineBytes(limit: 8192, deadline: Date().addingTimeInterval(5), requireNewline: true),
                  !(line.count == 1 && line[0] == 13) {}
            connection.writeRaw(Array("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8))
            for (index, chunk) in chunks.enumerated() {
                if index > 0 { Thread.sleep(forTimeInterval: pause) }
                let bytes = Array(chunk.utf8)
                connection.writeRaw(Array((String(bytes.count, radix: 16) + "\r\n").utf8) + bytes + Array("\r\n".utf8))
            }
            connection.writeRaw(Array("0\r\n\r\n".utf8))
            client.shutdownWrite()
            Thread.sleep(forTimeInterval: 0.2)
            connection.close()
        }.start()
        return (port, done)
    }

    func testStreamsLinesIncrementally() async throws {
        let (port, done) = try serve(status: "200 OK", contentType: "application/x-ndjson",
                                     chunks: ["{\"n\":1}\n", "{\"n\":2}\r\n"], pause: 0.8)
        let start = Date()
        let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        var arrivals: [(String, TimeInterval)] = []
        for try await line in bytes.lines { arrivals.append((line, Date().timeIntervalSince(start))) }
        XCTAssertEqual(arrivals.map(\.0), ["{\"n\":1}", "{\"n\":2}"])
        if arrivals.count == 2 {
            XCTAssertLessThan(arrivals[0].1, 0.6, "the first line must arrive before the second is sent")
            XCTAssertGreaterThan(arrivals[1].1 - arrivals[0].1, 0.4, "lines arrive as they are sent, not all at the end")
        }
        await fulfillment(of: [done], timeout: 5)
    }

    /// Off Apple platforms, a consumer cancelled in the middle of the body gets CancellationError, never a normal
    /// (truncated) end of the stream.
    func testCancellingTheConsumerThrows() async throws {
        let (port, done) = try serve(status: "200 OK", contentType: "text/plain", chunks: ["one\n", "two\n"], pause: 1.5)
        let first = expectation(description: "first line")
        let task = Task { () -> String in
            let (bytes, _) = try await URLSession.shared.bytes(for: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
            var lines: [String] = []
            for try await line in bytes.lines {
                lines.append(line)
                if lines.count == 1 { first.fulfill() }
            }
            return "ended normally after \(lines)"
        }
        await fulfillment(of: [first], timeout: 5)
        task.cancel()
        #if canImport(Darwin)
        // Observed: Apple's AsyncBytes ignores the cancel and delivers the rest of the body. Recorded, not asserted.
        let outcome: String
        do { outcome = try await task.value } catch { outcome = "threw \(error)" }
        print("Apple AsyncBytes after cancel: \(outcome)")
        #else
        do {
            XCTFail(try await task.value)
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        #endif
        await fulfillment(of: [done], timeout: 5)
    }

    func testReportsStatusAndErrorBody() async throws {
        let body = "{\"error\":{\"message\":\"bad key\"}}"
        let (port, done) = try serve(status: "401 Unauthorized", contentType: "application/json", chunks: [body], pause: 0)
        let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        var received = Data()
        for try await byte in bytes { received.append(byte) }
        XCTAssertEqual(String(decoding: received, as: UTF8.self), body)
        await fulfillment(of: [done], timeout: 5)
    }
}
