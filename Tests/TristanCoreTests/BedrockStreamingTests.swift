import XCTest
@testable import TristanCore

/// Builds event-stream frames exactly as the wire format defines them, so the decoder is tested against the spec.
enum FrameBuilder {
    static func be32(_ value: UInt32) -> Data { Data([UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }

    static func frame(headers: [String: String], payload: Data) -> Data {
        var headerBytes = Data()
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            headerBytes.append(UInt8(name.utf8.count)); headerBytes.append(Data(name.utf8))
            headerBytes.append(7)                                   // string
            headerBytes.append(UInt8(value.utf8.count >> 8)); headerBytes.append(UInt8(value.utf8.count & 255))
            headerBytes.append(Data(value.utf8))
        }
        let total = UInt32(12 + headerBytes.count + payload.count + 4)
        var prelude = be32(total); prelude.append(be32(UInt32(headerBytes.count)))
        var message = prelude
        message.append(be32(EventStreamDecoder.crc32(prelude)))
        message.append(headerBytes); message.append(payload)
        message.append(be32(EventStreamDecoder.crc32(message)))
        return message
    }

    static func event(_ type: String, _ json: [String: Any]) -> Data {
        frame(headers: [":message-type": "event", ":event-type": type, ":content-type": "application/json"],
              payload: try! JSONSerialization.data(withJSONObject: json))
    }
}

final class SigV4Tests: XCTestCase {
    private let credentials = AWSCredentials(accessKey: "AKIDEXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
    private let date = ISO8601DateFormatter().date(from: "2015-08-30T12:36:00Z")!

    private func signature(_ headers: [String: String]) -> String {
        let auth = headers["Authorization"] ?? ""
        return String(auth.split(separator: "=").last ?? "")
    }

    /// AWS Signature V4 test suite, "get-vanilla".
    func testMatchesTheAWSGetVanillaTestVector() {
        let headers = SigV4.sign(method: "GET", host: "example.amazonaws.com", percentEncodedPath: "/", body: Data(),
                                 credentials: credentials, region: "us-east-1", service: "service", date: date)
        XCTAssertEqual(headers["x-amz-date"], "20150830T123600Z")
        XCTAssertEqual(headers["Authorization"],
                       "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    /// The worked example in AWS's IAM documentation ("Create a signed request"): GET ListUsers with a query string.
    func testMatchesTheAWSDocumentationExampleWithQueryAndContentType() {
        let headers = SigV4.sign(method: "GET", host: "iam.amazonaws.com", percentEncodedPath: "/",
                                 query: [("Action", "ListUsers"), ("Version", "2010-05-08")],
                                 headers: ["Content-Type": "application/x-www-form-urlencoded; charset=utf-8"], body: Data(),
                                 credentials: credentials, region: "us-east-1", service: "iam", date: date)
        XCTAssertEqual(signature(headers), "5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7")
        XCTAssertTrue(headers["Authorization"]!.contains("SignedHeaders=content-type;host;x-amz-date"))
    }

    func testSessionTokenIsSignedAndReturned() {
        var withToken = credentials
        withToken.sessionToken = "TOKEN"
        let headers = SigV4.sign(method: "POST", host: "bedrock-runtime.us-east-1.amazonaws.com", percentEncodedPath: "/x",
                                 body: Data("{}".utf8), credentials: withToken, region: "us-east-1", service: "bedrock", date: date)
        XCTAssertEqual(headers["x-amz-security-token"], "TOKEN")
        XCTAssertTrue(headers["Authorization"]!.contains("x-amz-security-token"))
    }

    func testModelIdColonIsEncodedOnceInTheURLAndTwiceInTheCanonicalRequest() {
        let model = "us.anthropic.claude-sonnet-4-20250514-v1:0"
        let path = "/model/\(SigV4.uriEncode(model))/converse-stream"
        XCTAssertTrue(path.contains("v1%3A0"))
        XCTAssertTrue(SigV4.canonicalURI(percentEncodedPath: path).contains("v1%253A0"), "non-S3 services double-encode the path")
        // An inference-profile ARN also contains slashes, which must not split the path.
        XCTAssertFalse(SigV4.uriEncode("arn:aws:bedrock:us-east-1:123:inference-profile/x").contains("/"))
    }

    func testCredentialParsing() throws {
        let json = #"{"Version":1,"AccessKeyId":"AK","SecretAccessKey":"SK","SessionToken":"ST","Expiration":"2030-01-01T00:00:00Z"}"#
        let parsed = try AWSCredentials.parse(Data(json.utf8))
        XCTAssertEqual(parsed.accessKey, "AK"); XCTAssertEqual(parsed.sessionToken, "ST"); XCTAssertNotNil(parsed.expiration)
        XCTAssertThrowsError(try AWSCredentials.parse(Data("{}".utf8)))
    }

    func testRegionValidationStopsHostInjection() {
        XCTAssertTrue(BedrockStreamingClient.isValidRegion("us-east-1"))
        XCTAssertTrue(BedrockStreamingClient.isValidRegion("eu-central-1"))
        XCTAssertTrue(BedrockStreamingClient.isValidRegion("us-gov-west-1"))
        for bad in ["", "evil.com/", "us-east-1.evil.com", "us east 1", "US-EAST-1", "us-east-1\n"] {
            XCTAssertFalse(BedrockStreamingClient.isValidRegion(bad), "\"\(bad)\"")
        }
    }
}

final class EventStreamTests: XCTestCase {
    func testCRC32MatchesTheStandardCheckValue() {
        XCTAssertEqual(EventStreamDecoder.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testDecodesAFrameDeliveredOneByteAtATime() throws {
        let frame = FrameBuilder.event("contentBlockDelta", ["contentBlockIndex": 0, "delta": ["text": "Hi"]])
        var decoder = EventStreamDecoder()
        var messages: [EventStreamMessage] = []
        for byte in frame { messages += try decoder.feed(Data([byte])) }
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].headers[":event-type"], "contentBlockDelta")
        XCTAssertTrue(String(decoding: messages[0].payload, as: UTF8.self).contains("Hi"))
    }

    func testDecodesSeveralFramesInOneChunk() throws {
        var chunk = Data()
        for i in 0..<3 { chunk.append(FrameBuilder.event("contentBlockDelta", ["contentBlockIndex": i, "delta": ["text": "t\(i)"]])) }
        var decoder = EventStreamDecoder()
        XCTAssertEqual(try decoder.feed(chunk).count, 3)
    }

    func testBytesNeededLetsCallersBatchReads() throws {
        let frame = FrameBuilder.event("messageStop", ["stopReason": "end_turn"])
        var decoder = EventStreamDecoder()
        XCTAssertEqual(decoder.bytesNeeded, 12)
        _ = try decoder.feed(frame.prefix(12))
        XCTAssertEqual(decoder.bytesNeeded, frame.count - 12)
    }

    func testCorruptChecksumsAreRejected() {
        var frame = FrameBuilder.event("messageStop", ["stopReason": "end_turn"])
        frame[frame.count - 1] ^= 0xFF
        var decoder = EventStreamDecoder()
        XCTAssertThrowsError(try decoder.feed(frame))

        var prelude = FrameBuilder.event("messageStop", ["stopReason": "end_turn"])
        prelude[9] ^= 0xFF
        var other = EventStreamDecoder()
        XCTAssertThrowsError(try other.feed(prelude))
    }

    func testAbsurdLengthsAreRejectedBeforeAllocating() {
        var frame = FrameBuilder.be32(0xFFFF_FFF0); frame.append(FrameBuilder.be32(0)); frame.append(FrameBuilder.be32(0))
        var decoder = EventStreamDecoder()
        XCTAssertThrowsError(try decoder.feed(frame))
    }
}

final class ConverseStreamAssemblerTests: XCTestCase {
    private func feed(_ assembler: inout ConverseStreamAssembler, _ type: String, _ json: [String: Any]) throws -> String? {
        var decoder = EventStreamDecoder()
        return try decoder.feed(FrameBuilder.event(type, json)).compactMap { try assembler.feed($0) }.first
    }

    func testAssemblesTextAndAToolCallInOrder() throws {
        var assembler = ConverseStreamAssembler()
        var shown: [String] = []
        _ = try feed(&assembler, "messageStart", ["role": "assistant"])
        shown += [try feed(&assembler, "contentBlockDelta", ["contentBlockIndex": 0, "delta": ["text": "Let me "]])].compactMap { $0 }
        shown += [try feed(&assembler, "contentBlockDelta", ["contentBlockIndex": 0, "delta": ["text": "write it."]])].compactMap { $0 }
        _ = try feed(&assembler, "contentBlockStart", ["contentBlockIndex": 1, "start": ["toolUse": ["toolUseId": "t1", "name": "write_file"]]])
        _ = try feed(&assembler, "contentBlockDelta", ["contentBlockIndex": 1, "delta": ["toolUse": ["input": "{\"path\":\"a."]]])
        _ = try feed(&assembler, "contentBlockDelta", ["contentBlockIndex": 1, "delta": ["toolUse": ["input": "txt\",\"content\":\"x\"}"]]])
        _ = try feed(&assembler, "messageStop", ["stopReason": "tool_use"])

        XCTAssertEqual(shown, ["Let me ", "write it."])
        let response = assembler.response
        XCTAssertEqual(response["stopReason"] as? String, "tool_use")
        let content = try XCTUnwrap(((response["output"] as? [String: Any])?["message"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["text"] as? String, "Let me write it.")
        let tool = try XCTUnwrap(content[1]["toolUse"] as? [String: Any])
        XCTAssertEqual(tool["name"] as? String, "write_file")
        XCTAssertEqual((tool["input"] as? [String: Any])?["path"] as? String, "a.txt")
    }

    func testInBandExceptionsBecomeErrors() throws {
        let frame = FrameBuilder.frame(headers: [":message-type": "exception", ":exception-type": "throttlingException"],
                                       payload: Data(#"{"message":"Too many requests"}"#.utf8))
        var decoder = EventStreamDecoder()
        var assembler = ConverseStreamAssembler()
        let message = try XCTUnwrap(decoder.feed(frame).first)
        XCTAssertThrowsError(try assembler.feed(message)) { XCTAssertTrue("\($0)".contains("throttlingException") || ($0 as? BedrockError)?.message.contains("Too many") == true) }
    }

    func testAssembledResponseDrivesTheBackendLikeANormalResponse() async throws {
        // End to end through BedrockBackend: a streaming client returns the assembled shape and the text counts as streamed.
        struct StreamingFake: ConverseClient {
            func converse(_ request: [String: Any]) async throws -> [String: Any] { [:] }
            func converseStreaming(_ request: [String: Any], onText: @escaping @Sendable (String) -> Void) async throws -> [String: Any] {
                var assembler = ConverseStreamAssembler()
                var decoder = EventStreamDecoder()
                for frame in [FrameBuilder.event("contentBlockDelta", ["contentBlockIndex": 0, "delta": ["text": "Done."]]),
                              FrameBuilder.event("messageStop", ["stopReason": "end_turn"])] {
                    for message in try decoder.feed(frame) { if let piece = try assembler.feed(message) { onText(piece) } }
                }
                return assembler.response
            }
        }
        var streamed = ""
        let turn = try await BedrockBackend(client: StreamingFake()).nextTurn(system: "s", history: [.user("hi")]) { streamed += $0 }
        XCTAssertEqual(streamed, "Done.")
        XCTAssertEqual(turn.text, "Done.")
        XCTAssertTrue(turn.streamed)
        XCTAssertEqual(turn.stop == .end, true)
    }
}

final class FallbackClientTests: XCTestCase {
    private struct Failing: ConverseClient {
        var streamFirst = ""
        func converse(_ request: [String: Any]) async throws -> [String: Any] { throw BedrockError(message: "primary down") }
        func converseStreaming(_ request: [String: Any], onText: @escaping @Sendable (String) -> Void) async throws -> [String: Any] {
            if !streamFirst.isEmpty { onText(streamFirst) }
            throw BedrockError(message: "primary down")
        }
    }
    private final class Working: ConverseClient, @unchecked Sendable {
        var calls = 0
        func converse(_ request: [String: Any]) async throws -> [String: Any] { calls += 1; return ["from": "fallback"] }
    }

    func testFallsBackWhenStreamingCannotStart() async throws {
        let fallback = Working()
        let client = FallbackConverseClient(primary: Failing(), fallback: fallback)
        let response = try await client.converseStreaming([:]) { _ in }
        XCTAssertEqual(response["from"] as? String, "fallback")
        XCTAssertEqual(fallback.calls, 1)
    }

    func testDoesNotFallBackAfterTextWasAlreadyShown() async {
        let fallback = Working()
        let client = FallbackConverseClient(primary: Failing(streamFirst: "partial"), fallback: fallback)
        do { _ = try await client.converseStreaming([:]) { _ in }; XCTFail("expected the error to propagate") } catch {
            XCTAssertEqual(fallback.calls, 0, "falling back now would show the text twice")
        }
    }
}
