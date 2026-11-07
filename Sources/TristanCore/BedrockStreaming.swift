import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

package struct AWSCredentials: Equatable {
    var accessKey: String
    var secretKey: String
    var sessionToken: String?
    var expiration: Date?

    /// Parses the output of `aws configure export-credentials --format process`.
    static func parse(_ data: Data) throws -> AWSCredentials {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["AccessKeyId"] as? String, let secret = object["SecretAccessKey"] as? String else {
            throw BedrockError(message: "Could not read AWS credentials from the AWS CLI")
        }
        var expiration: Date?
        if let text = object["Expiration"] as? String { expiration = ISO8601DateFormatter().date(from: text) }
        return AWSCredentials(accessKey: key, secretKey: secret, sessionToken: object["SessionToken"] as? String, expiration: expiration)
    }
}

/// AWS Signature Version 4. Verified against the examples in AWS's own documentation (see the tests).
package enum SigV4 {
    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~".utf8)

    static func uriEncode(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 { out += unreserved.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte) }
        return out
    }

    /// For every service except S3 the already-encoded path is encoded a second time. This is why a model id
    /// containing ":" appears as "%253A" in the canonical request but "%3A" in the URL.
    static func canonicalURI(percentEncodedPath: String) -> String {
        percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map { uriEncode(String($0)) }.joined(separator: "/")
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    /// Returns the headers to add to the request (`x-amz-date`, `Authorization`, and the session token if any).
    static func sign(method: String, host: String, percentEncodedPath: String, query: [(String, String)] = [],
                     headers: [String: String] = [:], body: Data, credentials: AWSCredentials,
                     region: String, service: String, date: Date) -> [String: String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: date)
        let dateStamp = String(amzDate.prefix(8))

        var toSign = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) })
        toSign["host"] = host
        toSign["x-amz-date"] = amzDate
        if let token = credentials.sessionToken { toSign["x-amz-security-token"] = token }
        let names = toSign.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(toSign[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        var encodedPairs: [(name: String, value: String)] = []
        for (name, value) in query { encodedPairs.append((uriEncode(name), uriEncode(value))) }
        encodedPairs.sort { $0.name == $1.name ? $0.value < $1.value : $0.name < $1.name }
        let canonicalQuery = encodedPairs.map { "\($0.name)=\($0.value)" }.joined(separator: "&")

        let payloadHash = hex(SHA256.hash(data: body))
        let canonicalPath = canonicalURI(percentEncodedPath: percentEncodedPath)
        let canonicalRequest = [method, canonicalPath, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let requestHash = hex(SHA256.hash(data: Data(canonicalRequest.utf8)))
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, requestHash].joined(separator: "\n")

        var key = hmac(Data("AWS4\(credentials.secretKey)".utf8), dateStamp)
        key = hmac(key, region)
        key = hmac(key, service)
        key = hmac(key, "aws4_request")
        let signature = hex(hmac(key, stringToSign))

        var result = ["x-amz-date": amzDate,
                      "Authorization": "AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"]
        if let token = credentials.sessionToken { result["x-amz-security-token"] = token }
        return result
    }
}

/// Decoder for the `application/vnd.amazon.eventstream` binary framing used by streaming AWS APIs.
package struct EventStreamMessage {
    var headers: [String: String]
    var payload: Data
}

package struct EventStreamDecoder {
    private var buffer = Data()

    /// How many more bytes are needed before the next frame can be decoded (lets callers batch their reads).
    var bytesNeeded: Int {
        guard buffer.count >= 12 else { return 12 - buffer.count }
        return max(Int(Self.uint32(buffer, 0)) - buffer.count, 1)
    }

    static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return data[start..<start + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func feed(_ data: Data) throws -> [EventStreamMessage] {
        buffer.append(data)
        var messages: [EventStreamMessage] = []
        while buffer.count >= 12 {
            let total = Int(Self.uint32(buffer, 0))
            let headerLength = Int(Self.uint32(buffer, 4))
            guard total >= 16, headerLength <= total - 16, total < 16 * 1024 * 1024 else {
                throw BedrockError(message: "Corrupt response stream from Bedrock")
            }
            guard Self.crc32(buffer.prefix(8)) == Self.uint32(buffer, 8) else { throw BedrockError(message: "Corrupt response stream from Bedrock (prelude checksum)") }
            guard buffer.count >= total else { break }
            let frame = Data(buffer.prefix(total))
            guard Self.crc32(frame.prefix(total - 4)) == Self.uint32(frame, total - 4) else {
                throw BedrockError(message: "Corrupt response stream from Bedrock (message checksum)")
            }
            messages.append(EventStreamMessage(headers: try Self.headers(frame, from: 12, length: headerLength),
                                               payload: frame.subdata(in: 12 + headerLength..<total - 4)))
            buffer.removeFirst(total)
        }
        return messages
    }

    private static func headers(_ frame: Data, from start: Int, length: Int) throws -> [String: String] {
        var result: [String: String] = [:]
        var i = start
        let end = start + length
        func need(_ count: Int) throws { if i + count > end { throw BedrockError(message: "Corrupt response stream headers") } }
        while i < end {
            try need(1)
            let nameLength = Int(frame[i]); i += 1
            try need(nameLength + 1)
            let name = String(decoding: frame[i..<i + nameLength], as: UTF8.self); i += nameLength
            let type = frame[i]; i += 1
            switch type {
            case 0, 1: break
            case 2: try need(1); i += 1
            case 3: try need(2); i += 2
            case 4: try need(4); i += 4
            case 5, 8: try need(8); i += 8
            case 9: try need(16); i += 16
            case 6, 7:
                try need(2)
                let valueLength = Int(frame[i]) << 8 | Int(frame[i + 1]); i += 2
                try need(valueLength)
                if type == 7 { result[name] = String(decoding: frame[i..<i + valueLength], as: UTF8.self) }
                i += valueLength
            default: throw BedrockError(message: "Unknown header type in response stream")
            }
        }
        return result
    }
}

/// Rebuilds a normal Converse response from the streamed events. Pure, so it is easy to test.
package struct ConverseStreamAssembler {
    private var text: [Int: String] = [:]
    private var tools: [Int: (id: String, name: String, input: String)] = [:]
    private var stopReason = "end_turn"

    /// Handles one event. Returns new text to show, if any. Throws for in-band errors.
    mutating func feed(_ message: EventStreamMessage) throws -> String? {
        let object = (try? JSONSerialization.jsonObject(with: message.payload)) as? [String: Any] ?? [:]
        if message.headers[":message-type"] == "exception" || message.headers[":message-type"] == "error" {
            let kind = message.headers[":exception-type"] ?? message.headers[":error-code"] ?? "error"
            throw BedrockError(message: "Bedrock reported \(kind): \(object["message"] as? String ?? "no details")")
        }
        let index = object["contentBlockIndex"] as? Int ?? 0
        switch message.headers[":event-type"] {
        case "contentBlockStart":
            if let tool = (object["start"] as? [String: Any])?["toolUse"] as? [String: Any] {
                tools[index] = (tool["toolUseId"] as? String ?? "", tool["name"] as? String ?? "", "")
            }
        case "contentBlockDelta":
            let delta = object["delta"] as? [String: Any] ?? [:]
            if let piece = delta["text"] as? String {
                text[index, default: ""] += piece
                return piece.isEmpty ? nil : piece
            }
            if let piece = (delta["toolUse"] as? [String: Any])?["input"] as? String {
                var tool = tools[index] ?? ("", "", "")
                tool.input += piece
                tools[index] = tool
            }
        case "messageStop":
            stopReason = object["stopReason"] as? String ?? stopReason
        default: break
        }
        return nil
    }

    var response: [String: Any] {
        var blocks: [(Int, [String: Any])] = text.map { ($0.key, ["text": $0.value]) }
        for (index, tool) in tools {
            let input = (tool.input.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            blocks.append((index, ["toolUse": ["toolUseId": tool.id, "name": tool.name, "input": input]]))
        }
        let content = blocks.sorted { $0.0 < $1.0 }.map { $0.1 }
        return ["output": ["message": ["role": "assistant", "content": content]], "stopReason": stopReason]
    }
}

package protocol CredentialProvider: Sendable {
    func credentials() async throws -> AWSCredentials
}

#if !os(iOS)   // needs ProcessLauncher (Sources/TristanCore/Processes), which the iOS app does not compile
/// Uses `aws configure export-credentials`, which resolves the whole AWS chain (env, profiles, SSO, SAML helpers).
package final class AWSCLICredentials: CredentialProvider, @unchecked Sendable {
    private let profile: String
    private var cached: AWSCredentials?

    init(profile: String) { self.profile = profile }

    package func credentials() async throws -> AWSCredentials {
        if let cached, (cached.expiration ?? .distantFuture) > Date().addingTimeInterval(120) { return cached }
        let fresh = try await Self.export(profile: profile)
        cached = fresh
        return fresh
    }

    private static func export(profile: String) async throws -> AWSCredentials {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var arguments = ["configure", "export-credentials", "--format", "process"]
                if !profile.isEmpty { arguments += ["--profile", profile] }
                let process: Process
                do {
                    process = try ProcessLauncher.prepare("aws", arguments, directory: nil, extraEnvironment: [:])
                } catch is ToolNotFound {
                    continuation.resume(throwing: BedrockError(message: AWSCLIConverseClient.notInstalled))
                    return
                } catch {
                    continuation.resume(throwing: BedrockError(message: "Could not launch the AWS CLI: \(error.localizedDescription)"))
                    return
                }
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                let exit = ExitWatch(process)   // never waitUntilExit: it can miss the exit and never return
                do { try process.run() } catch {
                    continuation.resume(throwing: BedrockError(message: AWSCLIConverseClient.notInstalled))
                    return
                }
                exit.started(process)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                guard exit.wait(for: process) == 0 else {
                    continuation.resume(throwing: BedrockError(message: AWSCLIConverseClient.explain(stderr: errorText)))
                    return
                }
                continuation.resume(with: Result { try AWSCredentials.parse(data) })
            }
        }
    }
}
#endif

/// Access keys the user typed into the app, kept in the Keychain. This is how the iPhone and iPad get AWS credentials,
/// since there is no AWS CLI there. Prefer short-lived keys with a session token over long-lived ones.
package struct KeychainAWSCredentials: CredentialProvider {
    static let accessKeyAccount = "aws-access-key-id"
    static let secretKeyAccount = "aws-secret-access-key"
    static let sessionTokenAccount = "aws-session-token"

    package func credentials() async throws -> AWSCredentials {
        guard let key = KeychainStore.get(Self.accessKeyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
              let secret = KeychainStore.get(Self.secretKeyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty else {
            throw BedrockError(message: "No AWS access key is set. Add an access key and secret in Settings.")
        }
        let token = KeychainStore.get(Self.sessionTokenAccount)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AWSCredentials(accessKey: key, secretKey: secret, sessionToken: (token?.isEmpty ?? true) ? nil : token, expiration: nil)
    }
}

/// Streams a Bedrock Converse response over HTTPS (ConverseStream), signing the request with SigV4.
package struct BedrockStreamingClient: ConverseClient {
    let config: BedrockConfig
    let credentialProvider: CredentialProvider
    var session: URLSession = .shared
    var now: @Sendable () -> Date = { Date() }

    package static func isValidRegion(_ region: String) -> Bool {
        region.range(of: #"\A[a-z]{2}(-[a-z]+)+-[0-9]\z"#, options: .regularExpression) != nil
    }

    package func converse(_ request: [String: Any]) async throws -> [String: Any] {
        try await converseStreaming(request, onText: { _ in })
    }

    package func converseStreaming(_ request: [String: Any], onText: @escaping @Sendable (String) -> Void) async throws -> [String: Any] {
        guard Self.isValidRegion(config.region) else { throw BedrockError(message: "\"\(config.region)\" is not a valid AWS region") }
        let host = "bedrock-runtime.\(config.region).amazonaws.com"
        let path = "/model/\(SigV4.uriEncode(config.model))/converse-stream"
        guard let url = URL(string: "https://\(host)\(path)") else { throw BedrockError(message: "Could not build the Bedrock URL") }

        var body = request
        body["modelId"] = nil      // the model is part of the URL here
        let payload = try JSONSerialization.data(withJSONObject: body)
        let signed = SigV4.sign(method: "POST", host: host, percentEncodedPath: path,
                                headers: ["content-type": "application/json"], body: payload,
                                credentials: try await credentialProvider.credentials(),
                                region: config.region, service: "bedrock", date: now())

        var urlRequest = URLRequest(url: url, timeoutInterval: 300)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = payload
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in signed { urlRequest.setValue(value, forHTTPHeaderField: name) }

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw BedrockError(message: "No response from Bedrock") }
        guard http.statusCode == 200 else {
            var errorBody = Data()
            for try await byte in bytes { errorBody.append(byte); if errorBody.count > 4096 { break } }
            throw BedrockError(message: Self.explain(status: http.statusCode, body: errorBody))
        }

        var decoder = EventStreamDecoder()
        var assembler = ConverseStreamAssembler()
        var chunk = Data()
        for try await byte in bytes {
            chunk.append(byte)
            guard chunk.count >= decoder.bytesNeeded else { continue }
            for message in try decoder.feed(chunk) {
                if let piece = try assembler.feed(message) { onText(piece) }
            }
            chunk = Data()
        }
        return assembler.response
    }

    static func explain(status: Int, body: Data) -> String {
        let detail = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["message"] as? String
            ?? String(decoding: body.prefix(200), as: UTF8.self)
        switch status {
        case 400: return "Bedrock rejected the request (\(detail)). Check the model id in Configuration."
        case 403: return "AWS denied access (\(detail)). Check your credentials and that model access is enabled in Bedrock."
        case 404: return "Bedrock could not find that model in this region. \(detail)"
        case 429: return "Bedrock is throttling requests. Try again shortly. \(detail)"
        default: return "Bedrock returned HTTP \(status). \(detail)"
        }
    }
}

/// Tries streaming first and falls back to the AWS CLI if streaming cannot start. If it fails after text has
/// already been shown, the error is reported instead, so the same text is never produced twice.
package struct FallbackConverseClient: ConverseClient {
    let primary: ConverseClient
    let fallback: ConverseClient

    package func converse(_ request: [String: Any]) async throws -> [String: Any] {
        do { return try await primary.converse(request) } catch is CancellationError { throw CancellationError() } catch {
            return try await fallback.converse(request)
        }
    }

    package func converseStreaming(_ request: [String: Any], onText: @escaping @Sendable (String) -> Void) async throws -> [String: Any] {
        let tally = StreamTally()
        do {
            return try await primary.converseStreaming(request) { tally.note(); onText($0) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if tally.count > 0 { throw error }
            return try await fallback.converseStreaming(request, onText: onText)
        }
    }
}
