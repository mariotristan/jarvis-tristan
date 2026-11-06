import Foundation
import Network
import Security

/// TLS 1.2 with a pre-shared-key cipher suite from Apple's Network framework. Both sides must hold the same
/// secret or the handshake fails, so this gives mutual authentication and encryption without certificates.
enum RemoteTransport {
    static let serviceType = "_tristan._tcp"
    private static let identity = "tristan-remote"

    static func parameters(secret: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let key = secret.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
        let hint = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
        sec_protocol_options_add_pre_shared_key(options, key, hint)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true      // notice a vanished phone or Mac within about 25 seconds
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        return NWParameters(tls: tls, tcp: tcp)
    }
}

/// An NWConnection that speaks length-prefixed messages.
final class FramedConnection: @unchecked Sendable {
    let connection: NWConnection
    private var decoder = FrameDecoder()
    private let queue: DispatchQueue
    private var closed = false

    var onState: ((NWConnection.State) -> Void)?
    var onPayload: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    init(_ connection: NWConnection, queue: DispatchQueue = DispatchQueue(label: "com.tristan.remote.connection")) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.onState?(state)
            switch state {
            case .ready: self.receive()
            case .failed(let error): self.finish(error)
            case .cancelled: self.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send<T: Encodable>(_ message: T) {
        guard let payload = try? JSONEncoder().encode(message), payload.count <= Frame.maxPayload else { return }
        connection.send(content: Frame.encode(payload), completion: .contentProcessed { _ in })
    }

    /// Sends a final message and closes only after it has actually been written.
    func sendAndClose<T: Encodable>(_ message: T) {
        guard let payload = try? JSONEncoder().encode(message), payload.count <= Frame.maxPayload else { connection.cancel(); return }
        connection.send(content: Frame.encode(payload), completion: .contentProcessed { [weak self] _ in self?.connection.cancel() })
    }

    func cancel() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                do {
                    for payload in try self.decoder.feed(data) { self.onPayload?(payload) }
                } catch {
                    self.connection.cancel()
                    self.finish(error)
                    return
                }
            }
            if let error { self.finish(error); return }
            if isComplete { self.finish(nil); return }
            self.receive()
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        onClose?(error)
    }
}
