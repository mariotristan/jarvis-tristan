import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// stream-client <url>
// Prints the time (ms since the request) of the response head, every body chunk and every line. The server sends
// line 1, waits a second, then line 2: PASS means line 1 arrived at least 700 ms before line 2.
final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let start = Date()
    let done = DispatchSemaphore(value: 0)
    var pending: [UInt8] = []
    var lineTimes: [Double] = []

    var now: Double { Date().timeIntervalSince(start) * 1000 }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        print(String(format: "%7.1f ms  head: status %d", now, (response as? HTTPURLResponse)?.statusCode ?? -1))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        print(String(format: "%7.1f ms  chunk: %d bytes", now, data.count))
        pending += data
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeSubrange(...newline)
            lineTimes.append(now)
            print(String(format: "%7.1f ms  line: %@", now, line))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        print(String(format: "%7.1f ms  complete: %@", now, error.map { "\($0)" } ?? "ok"))
        done.signal()
    }
}

guard CommandLine.arguments.count == 2, let url = URL(string: CommandLine.arguments[1]) else {
    print("usage: stream-client <url>")
    exit(2)
}
let receiver = Receiver()
let session = URLSession(configuration: .ephemeral, delegate: receiver, delegateQueue: nil)
session.dataTask(with: url).resume()
if receiver.done.wait(timeout: .now() + 30) == .timedOut { print("TIMEOUT"); exit(1) }
let times = receiver.lineTimes
if times.count >= 2, times[1] - times[0] >= 700 {
    print(String(format: "PASS: line 1 at %.0f ms, line 2 at %.0f ms (URLSession delegate streams incrementally)", times[0], times[1]))
} else {
    print("FAIL: line times \(times) (lines did not arrive incrementally)")
    exit(1)
}
