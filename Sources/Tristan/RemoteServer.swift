import Foundation
import Network
import Combine

/// Lets a paired iPhone or iPad watch and drive this Mac's Session over a TLS-PSK connection (see the iOS design doc).
@MainActor
final class RemoteServer: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var port: UInt16?
    @Published private(set) var devices: [String] = []
    @Published private(set) var problem: String?
    /// Loaded on first use, so merely creating a Session never touches the Keychain.
    @Published private(set) var storedSecret: Data?

    static let secretAccount = "remote-secret"
    nonisolated static let defaultPort: UInt16 = 47613
    static let maxClients = 4
    static let maxTaskLength = 4_000

    private final class Client {
        let framed: FramedConnection
        var name: String?                   // set by `hello`; nil means not yet introduced
        var missionID = ""
        var sentLog = 0
        var sentCodeBytes = 0
        var lastSnapshot: RemoteSnapshot?
        var sentApprovalID: String?
        init(_ framed: FramedConnection) { self.framed = framed }
    }

    private weak var session: Session?
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var bag = Set<AnyCancellable>()
    private var pumpScheduled = false
    private let advertise: Bool
    private let preferredPort: UInt16?
    private let persistSecret: Bool
    private let allowedFolderProvider: (() -> [RemoteFolder])?

    /// `secret: nil` loads (or creates) the secret in the Keychain. Tests pass one explicitly and turn Bonjour off.
    init(secret: Data? = nil, advertise: Bool = true, preferredPort: UInt16? = RemoteServer.defaultPort,
         allowedFolders: (() -> [RemoteFolder])? = nil) {
        self.advertise = advertise
        self.preferredPort = preferredPort
        self.persistSecret = secret == nil
        self.allowedFolderProvider = allowedFolders
        self.storedSecret = secret
    }

    var secret: Data {
        if let storedSecret { return storedSecret }
        let loaded: Data
        if let stored = KeychainStore.get(Self.secretAccount), let data = PairingSecret.data(fromHex: stored) {
            loaded = data
        } else {
            loaded = PairingSecret.generate()
            KeychainStore.set(PairingSecret.hex(loaded), account: Self.secretAccount)
        }
        storedSecret = loaded
        return loaded
    }

    func attach(to session: Session) {
        self.session = session
        bag.removeAll()
        // Anything that changes what a phone shows triggers one coalesced update.
        session.objectWillChange.sink { [weak self] in self?.schedulePump() }.store(in: &bag)
        session.music.objectWillChange.sink { [weak self] in self?.schedulePump() }.store(in: &bag)
    }

    // MARK: lifecycle

    func start() {
        guard listener == nil else { return }
        problem = nil
        startListener(port: preferredPort.flatMap { NWEndpoint.Port(rawValue: $0) })
    }

    private func startListener(port requested: NWEndpoint.Port?) {
        do {
            let listener = try NWListener(using: RemoteTransport.parameters(secret: secret), on: requested ?? .any)
            if advertise {
                listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: RemoteTransport.serviceType)
            }
            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.accept(connection) } }
            }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.listenerChanged(state, listener: listener, requested: requested) } }
            }
            self.listener = listener
            listener.start(queue: DispatchQueue(label: "com.tristan.remote.listener"))
        } catch {
            problem = "Could not start remote control: \(error.localizedDescription)"
        }
    }

    private func listenerChanged(_ state: NWListener.State, listener: NWListener, requested: NWEndpoint.Port?) {
        guard listener === self.listener else { return }
        switch state {
        case .ready:
            running = true
            port = listener.port?.rawValue
        case .failed(let error):
            listener.cancel()
            self.listener = nil
            running = false
            port = nil
            if requested != nil {
                startListener(port: nil)        // the usual port is taken; let the system choose one
            } else {
                problem = "Remote control stopped: \(error.localizedDescription)"
            }
        default:
            break
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for client in clients.values { client.framed.cancel() }
        clients.removeAll()
        devices = []
        running = false
        port = nil
    }

    /// Invalidates every paired device: they hold the old secret and can no longer connect.
    func regenerateSecret() {
        let wasRunning = listener != nil
        stop()
        let fresh = PairingSecret.generate()
        storedSecret = fresh
        if persistSecret { KeychainStore.set(PairingSecret.hex(fresh), account: Self.secretAccount) }
        if wasRunning { start() }
    }

    var pairingLink: PairingLink? {
        guard let port else { return nil }
        let host = ProcessInfo.processInfo.hostName
        return PairingLink(name: Host.current().localizedName ?? host, host: host, port: port, secret: secret)
    }

    // MARK: connections

    private func accept(_ connection: NWConnection) {
        guard clients.count < Self.maxClients else { connection.cancel(); return }
        let framed = FramedConnection(connection)
        let client = Client(framed)
        let id = ObjectIdentifier(framed)
        clients[id] = client
        framed.onPayload = { [weak self] data in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data, from: id) } }
        }
        framed.onClose = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.drop(id) } }
        }
        framed.start()
        // Whoever connects must introduce themselves promptly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                if let client = self?.clients[id], client.name == nil { client.framed.cancel() }
            }
        }
    }

    private func drop(_ id: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: id) else { return }
        if let name = client.name {
            refreshDevices()
            session?.noteRemote("\(name) disconnected")
        }
    }

    private func refreshDevices() {
        devices = clients.values.compactMap(\.name).sorted()
    }

    // MARK: messages from a device

    private func receive(_ data: Data, from id: ObjectIdentifier) {
        guard let client = clients[id], let session, let message = try? JSONDecoder().decode(ClientMessage.self, from: data) else { return }

        if client.name == nil {
            guard case .hello(let deviceName, let version) = message else { client.framed.cancel(); return }
            guard version == remoteProtocolVersion else {
                client.framed.sendAndClose(ServerMessage.error("This version of Tristan is not compatible with the app. Update both."))
                return
            }
            client.name = Self.cleanDeviceName(deviceName)
            refreshDevices()
            session.noteRemote("\(client.name!) connected")
            client.framed.send(ServerMessage.welcome(snapshot: snapshot(of: session)))
            client.missionID = session.missionID
            client.lastSnapshot = snapshot(of: session)
            replay(to: client, session: session)
            return
        }

        func fail(_ text: String) { client.framed.send(ServerMessage.error(text)) }

        switch message {
        case .hello, .ping:
            if case .ping = message { client.framed.send(ServerMessage.pong) }
        case .submit(let task):
            let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return }
            if text.count > Self.maxTaskLength { return fail("That task is too long.") }
            if session.approvalMode == .yolo { return fail("The Mac is in YOLO mode, so remote tasks are refused. Switch it to ASK or AUTO on the Mac.") }
            if session.busy, MusicCommand.parse(text) == nil { return fail("A mission is already running.") }
            session.submit(text)
            session.noteRemote("Started from \(client.name ?? "a remote device")")
        case .cancel:
            session.cancel()
        case .approval(let approvalID, let decision):
            guard session.pending?.id.uuidString == approvalID else { return }
            session.resolve(decision != .deny, always: decision == .always)
        case .setProvider(let name):
            guard !session.busy else { return fail("Wait for the current mission to finish.") }
            guard let kind = ProviderKind(rawValue: name) else { return fail("Unknown provider.") }
            session.provider = kind
        case .setMode(let name):
            guard !session.busy else { return fail("Wait for the current mission to finish.") }
            guard let mode = ApprovalMode(rawValue: name) else { return fail("Unknown mode.") }
            guard mode != .yolo else { return fail("YOLO can only be switched on from the Mac itself.") }
            guard !session.kidsMode else { return fail("Kids safe mode is on. A parent has to change the mode on the Mac.") }
            session.approvalMode = mode
        case .setFolder(let path):
            guard !session.busy else { return fail("Wait for the current mission to finish.") }
            guard allowedFolders(for: session).contains(where: { $0.path == path }) else { return fail("That folder is not on the Mac's allowed list.") }
            session.workingDirectory = URL(fileURLWithPath: path)
        case .music(let name):
            guard session.musicOn else { return fail("Spotify control is off on the Mac.") }
            guard let command = Self.musicCommand(named: name) else { return fail("Unknown music command.") }
            Task { _ = await session.music.perform(command) }
        case .requestHistory:
            client.framed.send(ServerMessage.history(Array(session.records.prefix(50))))
        }
    }

    nonisolated static func cleanDeviceName(_ raw: String) -> String {
        let cleaned = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init).prefix(40))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Remote device" : cleaned
    }

    nonisolated static func musicCommand(named name: String) -> MusicCommand? {
        ["play": .play, "pause": .pause, "next": .next, "previous": .previous, "volumeUp": .volumeUp,
         "volumeDown": .volumeDown, "focus": .focusPlaylist, "nowPlaying": .nowPlaying][name]
    }

    // MARK: updates to devices

    func allowedFolders(for session: Session) -> [RemoteFolder] {
        if let allowedFolderProvider { return allowedFolderProvider() }
        var paths = [session.workingDirectory.path]
        for record in session.records.prefix(30) where !paths.contains(record.folder) { paths.append(record.folder) }
        return paths.filter { var isDirectory: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue }
            .map { RemoteFolder(path: $0, name: ($0 as NSString).lastPathComponent) }
    }

    func snapshot(of session: Session) -> RemoteSnapshot {
        let playing = session.music.nowPlaying
        return RemoteSnapshot(
            macName: Host.current().localizedName ?? "Mac", missionID: session.missionID, phase: session.phase, status: session.status,
            provider: session.provider.rawValue, providers: ProviderKind.allCases.map(\.rawValue), mode: session.approvalMode.rawValue,
            folder: session.workingDirectory.path, folders: allowedFolders(for: session), musicOn: session.musicOn,
            nowPlaying: playing.map { RemoteNowPlaying(track: $0.track, artist: $0.artist, playing: $0.isPlaying, volume: $0.volume) })
    }

    private func schedulePump() {
        guard !pumpScheduled, !clients.isEmpty else { return }
        pumpScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.pumpScheduled = false
                self?.pump()
            }
        }
    }

    private func pump() {
        guard let session else { return }
        let current = snapshot(of: session)
        for client in clients.values where client.name != nil {
            if current.missionID != client.missionID {
                client.missionID = current.missionID
                client.sentLog = 0
                client.sentCodeBytes = 0
            }
            if client.lastSnapshot != current {
                client.lastSnapshot = current
                client.framed.send(ServerMessage.snapshot(current))
            }
            replay(to: client, session: session)
        }
    }

    /// Sends whatever the device has not seen yet: new log lines, new code, and approval changes.
    private func replay(to client: Client, session: Session) {
        while client.sentLog < session.log.count {
            let entry = session.log[client.sentLog]
            client.framed.send(ServerMessage.log(missionID: session.missionID, text: entry.text, kind: Self.kindName(entry.kind)))
            client.sentLog += 1
        }
        let bytes = Array(session.code.utf8)
        if bytes.count > client.sentCodeBytes {
            let delta = String(decoding: bytes[client.sentCodeBytes...], as: UTF8.self)
            client.framed.send(ServerMessage.code(missionID: session.missionID, text: delta))
            client.sentCodeBytes = bytes.count
        }
        if let pending = session.pending {
            if client.sentApprovalID != pending.id.uuidString {
                client.sentApprovalID = pending.id.uuidString
                client.framed.send(ServerMessage.approval(RemoteApproval(id: pending.id.uuidString, summary: pending.summary,
                                                                        detail: pending.detail, canAlwaysAllow: pending.rule != nil)))
            }
        } else if let sent = client.sentApprovalID {
            client.sentApprovalID = nil
            client.framed.send(ServerMessage.approvalCleared(id: sent))
        }
    }

    private static func kindName(_ kind: LogEntry.Kind) -> String {
        switch kind {
        case .info: return "info"
        case .step: return "step"
        case .warn: return "warn"
        case .ok: return "ok"
        }
    }
}
