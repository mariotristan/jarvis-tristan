import Foundation
#if canImport(TristanCore)
import TristanCore
#endif

// Wire protocol between the Mac app (server) and the iPhone/iPad app (client). Version 1.
// Messages are JSON, sent as a 4-byte big-endian length followed by the body (see `Frame`).

let remoteProtocolVersion = 1

enum ApprovalDecision: String, Codable { case allow, deny, always }

struct RemoteFolder: Codable, Equatable, Hashable, Identifiable {
    var path: String
    var name: String
    var id: String { path }
}

struct RemoteNowPlaying: Codable, Equatable {
    var track: String
    var artist: String
    var playing: Bool
    var volume: Int
}

struct RemoteApproval: Codable, Equatable {
    var id: String
    var summary: String
    var detail: String
    var canAlwaysAllow: Bool
}

struct RemoteSnapshot: Codable, Equatable {
    var macName: String
    var missionID: String
    var phase: Phase
    var status: String
    var provider: String
    var providers: [String]
    var mode: String
    var folder: String                  // path of the current working folder
    var folders: [RemoteFolder]         // the only folders a remote device may choose
    var musicOn: Bool
    var nowPlaying: RemoteNowPlaying?
}

enum ClientMessage: Codable, Equatable {
    case hello(deviceName: String, protocolVersion: Int)
    case submit(task: String)
    case cancel
    case approval(id: String, decision: ApprovalDecision)
    case setProvider(String)
    case setMode(String)
    case setFolder(path: String)
    case music(String)
    case requestHistory
    case ping
}

enum ServerMessage: Codable, Equatable {
    case welcome(snapshot: RemoteSnapshot)
    case snapshot(RemoteSnapshot)
    case log(missionID: String, text: String, kind: String)
    case code(missionID: String, text: String)
    case approval(RemoteApproval)
    case approvalCleared(id: String)
    case history([MissionRecord])
    case error(String)
    case pong
}

/// 4-byte big-endian length prefix followed by the payload.
enum Frame {
    static let maxPayload = 1_048_576

    static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        return Data(bytes: &length, count: 4) + payload
    }
}

struct FrameDecoder {
    private var buffer = Data()

    /// Returns every complete payload received so far. Throws if a peer announces an oversized message.
    mutating func feed(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var payloads: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= Frame.maxPayload else { throw RemoteError.messageTooLarge }
            guard buffer.count >= 4 + length else { break }
            payloads.append(Data(buffer[buffer.startIndex + 4 ..< buffer.startIndex + 4 + length]))
            buffer.removeFirst(4 + length)
        }
        return payloads
    }
}

enum RemoteError: LocalizedError {
    case messageTooLarge
    var errorDescription: String? { "The other side sent a message that was too large." }
}

/// The pairing secret: 256 random bits, shown to the user as hex.
enum PairingSecret {
    static func generate() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func data(fromHex text: String) -> Data? {
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}

/// `tristan://pair?host=…&port=…&secret=…`, shown as a QR code on the Mac and opened on the phone.
struct PairingLink: Equatable {
    var name: String        // friendly name of the Mac, for display only
    var host: String
    var port: UInt16
    var secret: Data

    var url: URL {
        var components = URLComponents()
        components.scheme = "tristan"
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "host", value: host),
                                 URLQueryItem(name: "port", value: String(port)), URLQueryItem(name: "secret", value: PairingSecret.hex(secret))]
        return components.url!
    }

    static func parse(_ text: String) -> PairingLink? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "tristan", components.host == "pair" else { return nil }
        func value(_ key: String) -> String? { components.queryItems?.first { $0.name == key }?.value }
        guard let host = value("host"), isPlausibleHost(host),
              let portText = value("port"), let port = UInt16(portText), port > 0,
              let secretText = value("secret"), let secret = PairingSecret.data(fromHex: secretText) else { return nil }
        return PairingLink(name: String((value("name") ?? host).prefix(60)), host: host, port: port, secret: secret)
    }

    /// Hostnames, .local names and IP addresses only, so a crafted link cannot smuggle in anything else.
    static func isPlausibleHost(_ host: String) -> Bool {
        host.count <= 255 && host.range(of: #"^[A-Za-z0-9]([A-Za-z0-9._:\-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil
    }
}
