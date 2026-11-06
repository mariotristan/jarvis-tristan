import Foundation
import Network

struct RemoteLogLine: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let kind: String      // "info", "step", "warn" or "ok"
}

/// The phone's side of the remote: connects to the Mac, mirrors its state and sends commands.
@MainActor
final class RemoteClient: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)      // terminal: retrying will not help (for example a wrong pairing secret)
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var snapshot: RemoteSnapshot?
    @Published private(set) var log: [RemoteLogLine] = []
    @Published private(set) var code = ""
    @Published private(set) var approval: RemoteApproval?
    @Published private(set) var history: [MissionRecord] = []
    @Published private(set) var notice: String?      // transient problems ("Can't reach your Mac, retrying") and server errors

    var deviceName = "iPhone"

    private enum Target { case hostPort(String, UInt16), endpoint(NWEndpoint) }
    private var target: Target?
    private var secret: Data?
    private var framed: FramedConnection?
    private var wantConnected = false
    private var attempt = 0
    private var missionID: String?
    private var timeout: Task<Void, Never>?
    private var retry: Task<Void, Never>?

    static let backoff: [Double] = [1, 2, 4, 8, 15]

    // MARK: connecting

    func connect(host: String, port: UInt16, secret: Data) {
        start(.hostPort(host, port), secret: secret)
    }

    func connect(endpoint: NWEndpoint, secret: Data) {
        start(.endpoint(endpoint), secret: secret)
    }

    func disconnect() {
        wantConnected = false
        retry?.cancel()
        timeout?.cancel()
        framed?.cancel()
        framed = nil
        state = .disconnected
        approval = nil
    }

    private func start(_ target: Target, secret: Data) {
        disconnect()
        self.target = target
        self.secret = secret
        wantConnected = true
        attempt = 0
        open()
    }

    private func open() {
        guard wantConnected, let target, let secret else { return }
        state = .connecting
        let endpoint: NWEndpoint
        switch target {
        case .hostPort(let host, let port):
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { state = .failed("Invalid port"); return }
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        case .endpoint(let value):
            endpoint = value
        }
        let connection = FramedConnection(NWConnection(to: endpoint, using: RemoteTransport.parameters(secret: secret)))
        framed = connection
        // Callbacks hop to the main queue with DispatchQueue (not Task) because that keeps messages in order.
        connection.onState = { [weak self] value in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(state: value, from: connection) } }
        }
        connection.onPayload = { [weak self] data in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(payload: data, from: connection) } }
        }
        connection.onClose = { [weak self] error in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.closed(connection, error: error) } }
        }
        connection.start()

        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.framed === connection, self.state == .connecting else { return }
            connection.cancel()
            self.scheduleRetry("Your Mac did not answer.")
        }
    }

    private func handle(state value: NWConnection.State, from connection: FramedConnection) {
        guard connection === framed else { return }
        switch value {
        case .ready:
            connection.send(ClientMessage.hello(deviceName: deviceName, protocolVersion: remoteProtocolVersion))
        case .waiting(let error):
            if case .tls = error {
                // The handshake was refused: the secret is wrong, or the Mac regenerated it.
                wantConnected = false
                timeout?.cancel()
                connection.cancel()
                framed = nil
                state = .failed("The pairing secret was rejected. Pair again from the Mac's Remote settings.")
            } else {
                connection.cancel()
                scheduleRetry("Can't reach your Mac.")
            }
        default:
            break
        }
    }

    private func closed(_ connection: FramedConnection, error: Error?) {
        guard connection === framed else { return }
        framed = nil
        guard wantConnected else { return }
        scheduleRetry("Connection lost.")
    }

    private func scheduleRetry(_ message: String) {
        guard wantConnected else { return }
        framed = nil
        timeout?.cancel()
        state = .connecting
        let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
        attempt += 1
        notice = "\(message) Retrying in \(Int(delay))s."
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.open()
        }
    }

    // MARK: messages from the Mac

    private func handle(payload: Data, from connection: FramedConnection) {
        guard connection === framed, let message = try? JSONDecoder().decode(ServerMessage.self, from: payload) else { return }
        switch message {
        case .welcome(let snapshot):
            timeout?.cancel()
            attempt = 0
            notice = nil
            resetMission(to: snapshot.missionID)
            self.snapshot = snapshot
            state = .connected
        case .snapshot(let snapshot):
            if snapshot.missionID != missionID { resetMission(to: snapshot.missionID) }
            self.snapshot = snapshot
        case .log(let id, let text, let kind):
            if id != missionID { resetMission(to: id) }
            log.append(RemoteLogLine(text: text, kind: kind))
        case .code(let id, let text):
            if id != missionID { resetMission(to: id) }
            code += text
        case .approval(let request):
            approval = request
        case .approvalCleared(let id):
            if approval?.id == id { approval = nil }
        case .history(let records):
            history = records
        case .error(let text):
            if state == .connecting {
                // An error before the welcome means the Mac refused us (for example an incompatible version); retrying will not help.
                wantConnected = false
                timeout?.cancel()
                framed?.cancel()
                framed = nil
                state = .failed(text)
            } else {
                notice = text
            }
        case .pong:
            break
        }
    }

    private func resetMission(to id: String) {
        missionID = id
        log = []
        code = ""
        approval = nil
    }

    // MARK: commands

    private func send(_ message: ClientMessage) {
        guard state == .connected else { return }
        framed?.send(message)
    }

    func submit(_ task: String) { send(.submit(task: task)) }
    func cancel() { send(.cancel) }
    func respond(_ decision: ApprovalDecision) {
        guard let approval else { return }
        send(.approval(id: approval.id, decision: decision))
        self.approval = nil
    }
    func setProvider(_ name: String) { send(.setProvider(name)) }
    func setMode(_ name: String) { send(.setMode(name)) }
    func setFolder(_ path: String) { send(.setFolder(path: path)) }
    func music(_ command: String) { send(.music(command)) }
    func requestHistory() { send(.requestHistory) }
    func clearNotice() { notice = nil }
}
