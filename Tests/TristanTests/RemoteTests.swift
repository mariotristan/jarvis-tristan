import XCTest
import Network
@testable import Tristan

final class RemoteProtocolTests: XCTestCase {
    func testFramesSurviveArbitrarySplittingAndMerging() throws {
        let first = Frame.encode(Data("hello".utf8)), second = Frame.encode(Data("world!".utf8))
        var decoder = FrameDecoder()
        var out: [String] = []
        for byte in first + second { out += try decoder.feed(Data([byte])).map { String(decoding: $0, as: UTF8.self) } }
        XCTAssertEqual(out, ["hello", "world!"])
        var merged = FrameDecoder()
        XCTAssertEqual(try merged.feed(first + second).count, 2)
    }

    func testOversizedFramesAreRejectedBeforeBuffering() {
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.feed(Data([0x7F, 0xFF, 0xFF, 0xFF])))
    }

    func testMessagesRoundTripThroughJSON() throws {
        let client: [ClientMessage] = [.hello(deviceName: "iPhone", protocolVersion: 1), .submit(task: "add login"), .cancel,
                                       .approval(id: "x", decision: .always), .setFolder(path: "/tmp"), .music("next"), .ping]
        for message in client { XCTAssertEqual(try JSONDecoder().decode(ClientMessage.self, from: JSONEncoder().encode(message)), message) }
        let snapshot = RemoteSnapshot(macName: "Mac", missionID: "m", phase: .awaitingApproval, status: "WAITING", provider: "CLAUDE",
                                      providers: ["CLAUDE"], mode: "ASK", folder: "/tmp", folders: [RemoteFolder(path: "/tmp", name: "tmp")],
                                      musicOn: true, nowPlaying: RemoteNowPlaying(track: "T", artist: "A", playing: true, volume: 40))
        let record = MissionRecord(task: "t", provider: "DEMO", mode: "ASK", status: "done", summary: "s", folder: "/tmp")
        let server: [ServerMessage] = [.welcome(snapshot: snapshot), .snapshot(snapshot), .log(missionID: "m", text: "x", kind: "ok"),
                                       .code(missionID: "m", text: "let x = 1"), .history([record]), .error("no"), .pong,
                                       .approval(RemoteApproval(id: "i", summary: "s", detail: "d", canAlwaysAllow: true)), .approvalCleared(id: "i")]
        for message in server { XCTAssertEqual(try JSONDecoder().decode(ServerMessage.self, from: JSONEncoder().encode(message)), message) }
    }

    func testPairingLinkRoundTripAndValidation() throws {
        let secret = PairingSecret.generate()
        let link = PairingLink(name: "Mario's Mac", host: "marios-mac.local", port: 47613, secret: secret)
        XCTAssertEqual(PairingLink.parse(link.url.absoluteString), link)
        XCTAssertEqual(PairingSecret.data(fromHex: PairingSecret.hex(secret)), secret)
        let hex = PairingSecret.hex(secret)
        for bad in ["", "https://pair?host=a&port=1&secret=\(hex)", "tristan://pair?host=a&port=0&secret=\(hex)",
                    "tristan://pair?host=a&port=1&secret=abcd", "tristan://pair?host=a%20b&port=1&secret=\(hex)",
                    "tristan://pair?host=evil.com/%0A&port=1&secret=\(hex)", "tristan://other?host=a&port=1&secret=\(hex)",
                    "tristan://pair?host=a&port=99999&secret=\(hex)", "tristan://pair?host=a&port=1&secret=\(String(repeating: "z", count: 64))"] {
            XCTAssertNil(PairingLink.parse(bad), "\(bad) must be rejected")
        }
        XCTAssertNotNil(PairingLink.parse("tristan://pair?host=192.168.1.20&port=5&secret=\(hex)"))
    }

    func testSecretsAreRandomAndLongEnough() {
        XCTAssertEqual(PairingSecret.generate().count, 32)
        XCTAssertNotEqual(PairingSecret.generate(), PairingSecret.generate())
    }

    func testDeviceNamesAreSanitised() {
        XCTAssertEqual(RemoteServer.cleanDeviceName("  Mario’s iPhone \n"), "Mario’s iPhone")
        XCTAssertEqual(RemoteServer.cleanDeviceName("\u{07}\u{1B}"), "Remote device")
        XCTAssertEqual(RemoteServer.cleanDeviceName(String(repeating: "x", count: 500)).count, 40)
    }
}

/// A real client talking to a real server over loopback, with the real TLS-PSK handshake.
@MainActor
final class RemoteEndToEndTests: XCTestCase {
    private var folder: URL!
    private var other: URL!
    private var session: Session!
    private var server: RemoteServer!
    private var secret = PairingSecret.generate()
    private var fakeSpotify = FakeSpotify()
    private var clients: [RemoteClient] = []

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-remote-\(UUID().uuidString.prefix(8))")
        folder = base.appendingPathComponent("allowed")
        other = base.appendingPathComponent("not-allowed")
        for url in [folder!, other!] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let music = SpotifyController(runner: fakeSpotify, isRunning: { true }, releaseDelay: .zero)
        session = Session(history: nil, music: music)
        session.soundsOn = false; session.voiceOn = false; session.notificationsOn = false
        session.approvalMode = .ask
        session.workingDirectory = folder
        let allowed = [RemoteFolder(path: folder.path, name: "allowed")]
        server = RemoteServer(secret: secret, advertise: false, preferredPort: nil, allowedFolders: { allowed })
        server.attach(to: session)
        server.start()
        try await eventually { self.server.port != nil }
    }

    override func tearDown() async throws {
        clients.forEach { $0.disconnect() }
        server.stop()
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    private func eventually(timeout: Double = 10, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    }

    private func connectedClient(name: String = "TestPhone", secret override: Data? = nil) async throws -> RemoteClient {
        let client = RemoteClient()
        client.deviceName = name
        clients.append(client)
        client.connect(host: "127.0.0.1", port: server.port!, secret: override ?? secret)
        try await eventually { client.state == .connected }
        return client
    }

    func testPairedClientConnectsAndSeesTheMacState() async throws {
        let client = try await connectedClient()
        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(client.snapshot?.mode, "ASK")
        XCTAssertEqual(client.snapshot?.folder, folder.path)
        XCTAssertEqual(client.snapshot?.providers.contains("CLAUDE"), true)
        XCTAssertEqual(server.devices, ["TestPhone"])
        XCTAssertTrue(session.log.contains { $0.text.contains("TestPhone connected") }, "the Mac must announce who connected")
        client.disconnect()
        try await eventually { self.server.devices.isEmpty }
        XCTAssertTrue(server.devices.isEmpty)
    }

    func testWrongSecretIsRefusedAndNotRetriedForever() async throws {
        let client = RemoteClient()
        clients.append(client)
        client.connect(host: "127.0.0.1", port: server.port!, secret: PairingSecret.generate())
        try await eventually { if case .failed = client.state { return true } else { return false } }
        guard case .failed(let reason) = client.state else { return XCTFail("a wrong secret must fail the connection, got \(client.state)") }
        XCTAssertTrue(reason.contains("pairing secret"))
        XCTAssertTrue(server.devices.isEmpty)
        XCTAssertNil(client.snapshot)
    }

    func testRegeneratingTheSecretLocksOutOldDevices() async throws {
        let client = try await connectedClient()
        XCTAssertEqual(client.state, .connected)
        server.regenerateSecret()
        try await eventually { self.server.port != nil }
        let stale = RemoteClient()
        clients.append(stale)
        stale.connect(host: "127.0.0.1", port: server.port!, secret: secret)       // the old secret
        try await eventually { if case .failed = stale.state { return true } else { return false } }
        guard case .failed = stale.state else { return XCTFail("the old secret must no longer work") }
    }

    func testMissionWithApprovalFromTheRemote() async throws {
        let client = try await connectedClient()
        client.setProvider("DEMO")
        try await eventually { client.snapshot?.provider == "DEMO" }
        client.submit("write a login function")
        try await eventually(timeout: 15) { client.approval != nil }
        XCTAssertEqual(client.approval?.summary, "Write Sources/auth.ts")
        XCTAssertNotNil(client.snapshot.map { $0.phase == .awaitingApproval || $0.phase == .working })
        client.respond(.allow)
        try await eventually(timeout: 20) { client.snapshot?.phase == .done }
        XCTAssertEqual(client.snapshot?.phase, .done)
        XCTAssertTrue(client.code.contains("export function login"), "code should stream to the phone")
        XCTAssertTrue(client.log.contains { $0.text.contains("Authorization granted") })
        XCTAssertNil(client.approval)

        // A device that connects later gets the whole mission replayed.
        let late = try await connectedClient(name: "SecondDevice")
        try await eventually { !late.code.isEmpty && !late.log.isEmpty }
        XCTAssertEqual(late.code, client.code, "the whole code stream is replayed")
        XCTAssertTrue(late.log.contains { $0.text.contains("Authorization granted") }, "the mission log is replayed")
    }

    func testRemoteDenialStopsTheMission() async throws {
        let client = try await connectedClient()
        client.setProvider("DEMO")
        try await eventually { client.snapshot?.provider == "DEMO" }
        client.submit("do something")
        try await eventually(timeout: 15) { client.approval != nil }
        client.respond(.deny)
        try await eventually(timeout: 10) { client.snapshot?.phase == .failed }
        XCTAssertEqual(client.snapshot?.phase, .failed)
        XCTAssertTrue(client.log.contains { $0.text.contains("Authorization denied") })
    }

    func testYoloIsOffLimitsRemotely() async throws {
        let client = try await connectedClient()
        client.setMode("YOLO")
        try await eventually { client.notice?.contains("YOLO") == true }
        XCTAssertEqual(session.approvalMode, .ask, "a phone must not be able to turn YOLO on")

        session.approvalMode = .yolo
        client.clearNotice()
        client.submit("delete everything")
        try await eventually { client.notice?.contains("YOLO") == true }
        XCTAssertEqual(session.phase, .idle, "remote tasks are refused while the Mac is in YOLO mode")
    }

    func testFoldersOutsideTheAllowListAreRefused() async throws {
        let client = try await connectedClient()
        client.setFolder(other.path)
        try await eventually { client.notice?.contains("allowed list") == true }
        XCTAssertEqual(session.workingDirectory.path, folder.path)
        client.setFolder("/etc")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(session.workingDirectory.path, folder.path)
        client.clearNotice()
        client.setFolder(folder.path)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(client.notice, "the allowed folder is accepted")
    }

    func testMusicCommandsReachSpotify() async throws {
        session.musicOn = true
        let client = try await connectedClient()
        client.music("next")
        try await eventually { self.fakeSpotify.scripts.contains(SpotifyScripts.next) }
        XCTAssertTrue(fakeSpotify.scripts.contains(SpotifyScripts.next))
        session.musicOn = false
    }

    func testEmptyAndOverlongTasksAreIgnoredOrRefused() async throws {
        let client = try await connectedClient()
        client.submit("   ")
        client.submit(String(repeating: "x", count: RemoteServer.maxTaskLength + 1))
        try await eventually { client.notice?.contains("too long") == true }
        XCTAssertEqual(session.phase, .idle)
    }

    func testAConnectionThatDoesNotIntroduceItselfIsDropped() async throws {
        let raw = FramedConnection(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: server.port!)!, using: RemoteTransport.parameters(secret: secret)))
        let closed = expectation(description: "closed")
        raw.onState = { state in if case .ready = state { raw.send(ClientMessage.submit(task: "sneak in without hello")) } }
        raw.onClose = { _ in closed.fulfill() }
        raw.start()
        await fulfillment(of: [closed], timeout: 8)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertTrue(server.devices.isEmpty)
    }

    func testAnIncompatibleProtocolVersionIsToldAndDropped() async throws {
        let raw = FramedConnection(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: server.port!)!, using: RemoteTransport.parameters(secret: secret)))
        let closed = expectation(description: "closed")
        let sawError = LockedFlag()
        raw.onState = { state in if case .ready = state { raw.send(ClientMessage.hello(deviceName: "Old", protocolVersion: 99)) } }
        raw.onPayload = { data in if case .error? = try? JSONDecoder().decode(ServerMessage.self, from: data) { sawError.set() } }
        raw.onClose = { _ in closed.fulfill() }
        raw.start()
        await fulfillment(of: [closed], timeout: 8)
        XCTAssertTrue(sawError.value, "the device should be told why it was dropped")
        XCTAssertTrue(server.devices.isEmpty)
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
