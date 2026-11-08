import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TristanCore

/// Answers Azure OpenAI chat-completions requests in-process (a URLProtocol), so the real `AzureHTTPClient` (headers,
/// streaming, SSE parsing) runs without a network. The first request gets a streamed `write_file` call for hello.txt,
/// later ones a streamed text answer. Event lines end in CR LF.
final class AzureStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    /// A client for https://stub-resource.openai.azure.com, deployment gpt-stub, whose session answers from here.
    static func start() -> AzureHTTPClient {
        lock.lock(); recorded = []; lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AzureStub.self]
        return AzureHTTPClient(config: AzureConfig(endpoint: "https://stub-resource.openai.azure.com", deployment: "gpt-stub",
                                                   apiVersion: AzureConfig.defaultAPIVersion),
                               session: URLSession(configuration: configuration))
    }

    static func stop() { lock.lock(); recorded = []; lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub-resource.openai.azure.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let first = Self.recorded.count == 1
        Self.lock.unlock()
        let events: [String] = first ? [
            #"{"choices":[{"delta":{"role":"assistant","content":"Writing "},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{"content":"hello.txt."},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"write_file","arguments":"{\"path\":\"hello.txt\","}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"content\":\"hi from azure\"}"}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        ] : [
            #"{"choices":[{"delta":{"role":"assistant","content":"Done: "},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{"content":"hello.txt written."},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
        ]
        let body = (events + ["[DONE]"]).map { "data: \($0)\r\n\r\n" }.joined()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
