import XCTest
@testable import TristanCore

/// The approval channel between the Claude Code MCP shim and the host. The loopback (Windows default) transport is
/// exercised directly here so it runs on the Mac too.
final class ApprovalTransportTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        super.tearDown()
    }

    /// Short, so a Unix socket path fits in `sun_path`.
    private func makeFolder() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        folders.append(folder)
        return folder
    }

    private func loopback(handshakeTimeout: TimeInterval = 5) throws -> LoopbackListener {
        try XCTUnwrap(LoopbackListener(handshakeTimeout: handshakeTimeout))
    }

    /// Accepts one connection in the background, records its first line, answers `got:<line>` and closes.
    private func serveOne(_ listener: ApprovalListener, received: @escaping @Sendable (String?) -> Void) -> XCTestExpectation {
        let done = expectation(description: "served")
        nonisolated(unsafe) let listener = listener
        DispatchQueue.global().async {
            if let connection = listener.accept() {
                let line = connection.readLine()
                received(line)
                // A huge echo would block on a client that is not reading.
                connection.writeLine("got:\(line.map { $0.count > 1000 ? "long" : $0 } ?? "nil")")
                connection.close()
            } else {
                received(nil)
            }
            done.fulfill()
        }
        return done
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String?] = []
        func add(_ item: String?) { lock.lock(); items.append(item); lock.unlock() }
        var all: [String?] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func port(of endpoint: String) -> UInt16? {
        guard endpoint.hasPrefix("tcp:127.0.0.1:") else { return nil }
        return UInt16(endpoint.dropFirst("tcp:127.0.0.1:".count))
    }

    /// A shim-side connection through the real handshake, with a read timeout so a bypass fails instead of hanging.
    private func connect(_ listener: ApprovalListener, token: String?, serverToken: String? = nil) -> LineConnection? {
        let connection = ApprovalTransport.connect(endpoint: listener.endpoint, token: token,
                                                   serverToken: serverToken ?? listener.serverToken,
                                                   handshakeTimeout: 2, replyTimeout: 5) as? LineConnection
        return connection
    }

    /// A TCP connection that skips the handshake, reads time out after 5 s.
    private func raw(_ port: UInt16) throws -> LineConnection {
        let connection = try XCTUnwrap(LoopbackConnection.open(port: port))
        connection.socket.setReceiveTimeout(5)
        return connection
    }

    /// `token` with the character at `index` changed to another hex digit.
    private func flip(_ token: String, at index: Int) -> String {
        var chars = Array(token)
        chars[index] = chars[index] == "0" ? "1" : "0"
        return String(chars)
    }

    // MARK: - Loopback

    func testConstantTimeEqual() {
        let a = Array("0123456789abcdef0123456789abcdef".utf8)
        XCTAssertTrue(LoopbackListener.constantTimeEqual(a, a))
        XCTAssertTrue(LoopbackListener.constantTimeEqual([], []))
        for index in [0, a.count / 2, a.count - 1] {
            var b = a
            b[index] ^= 0x01
            XCTAssertFalse(LoopbackListener.constantTimeEqual(a, b), "difference at \(index)")
            XCTAssertFalse(LoopbackListener.constantTimeEqual(b, a), "difference at \(index)")
        }
        var twoDifferences = a
        twoDifferences[0] ^= 0x01
        twoDifferences[a.count - 1] ^= 0x01
        XCTAssertFalse(LoopbackListener.constantTimeEqual(a, twoDifferences))
        XCTAssertFalse(LoopbackListener.constantTimeEqual(a, Array(a.dropLast())))
        XCTAssertFalse(LoopbackListener.constantTimeEqual(Array(a.dropLast()), a))
        XCTAssertFalse(LoopbackListener.constantTimeEqual(a, a + [0]))
        XCTAssertFalse(LoopbackListener.constantTimeEqual(a, []))
    }

    func testLoopbackRoundTrip() throws {
        let listener = try loopback()
        defer { listener.close() }
        let token = try XCTUnwrap(listener.token)
        let serverToken = try XCTUnwrap(listener.serverToken)
        for secret in [token, serverToken] {
            XCTAssertEqual(secret.count, 64, "256-bit token as hex")
            XCTAssertTrue(secret.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
        }
        XCTAssertNotEqual(token, serverToken)
        XCTAssertTrue(listener.endpoint.hasPrefix("tcp:127.0.0.1:"))
        XCTAssertEqual(port(of: listener.endpoint), listener.port)

        let box = Box()
        let served = serveOne(listener) { box.add($0) }
        let client = try XCTUnwrap(connect(listener, token: token))
        client.writeLine(#"{"tool_name":"Bash"}"#)
        XCTAssertEqual(client.readLine(), #"got:{"tool_name":"Bash"}"#)
        XCTAssertNil(client.readLine(), "the server closed the connection")
        client.close()
        wait(for: [served], timeout: 5)
        XCTAssertEqual(box.all, [#"{"tool_name":"Bash"}"#])
    }

    func testTokensAreFreshPerListener() throws {
        let a = try loopback(), b = try loopback()
        defer { a.close(); b.close() }
        XCTAssertNotEqual(a.token, b.token)
        XCTAssertNotEqual(a.serverToken, b.serverToken)
        XCTAssertNotEqual(a.port, b.port)
    }

    func testWrongTokenIsDropped() throws {
        let listener = try loopback()
        defer { listener.close() }
        let box = Box()
        let served = serveOne(listener) { box.add($0) }

        let token = try XCTUnwrap(listener.token)
        let wrongs = [String(token.reversed()), flip(token, at: 0), flip(token, at: 31), flip(token, at: 63),
                      String(token.dropLast()), token + "0", token.uppercased()]
        for wrong in wrongs {
            XCTAssertNil(connect(listener, token: wrong), "the host never answers a wrong token: \(wrong)")
            // The same, seen from a raw client: the host closes without sending its token.
            let intruder = try raw(listener.port)
            intruder.writeLine(wrong)
            intruder.writeLine(#"{"tool_name":"Bash","input":{"command":"rm -rf ~"}}"#)
            XCTAssertNil(intruder.readLine(), "a client with a wrong token gets nothing back: \(wrong)")
            intruder.close()
        }

        let client = try XCTUnwrap(connect(listener, token: token))
        client.writeLine("good")
        XCTAssertEqual(client.readLine(), "got:good", "the next valid client is still accepted")
        client.close()
        wait(for: [served], timeout: 5)
        XCTAssertEqual(box.all, ["good"])
    }

    func testMissingTokenIsDropped() throws {
        let listener = try loopback()
        defer { listener.close() }
        let box = Box()
        let served = serveOne(listener) { box.add($0) }
        let port = listener.port

        // The request first, no token line.
        let bare = try raw(port)
        bare.writeLine(#"{"tool_name":"Bash","input":{"command":"ls"}}"#)
        XCTAssertNil(bare.readLine())
        bare.close()

        // An empty first line.
        let empty = try raw(port)
        empty.writeLine("")
        empty.writeLine(try XCTUnwrap(listener.token))
        XCTAssertNil(empty.readLine())
        empty.close()

        // The token without its newline, then end of stream.
        let unterminated = try raw(port)
        unterminated.writeRaw(Array(try XCTUnwrap(listener.token).utf8))
        unterminated.socket.shutdownWrite()
        XCTAssertNil(unterminated.readLine())
        unterminated.close()

        // Connects and hangs up.
        try raw(port).close()

        // A long first line with no newline is not buffered without limit.
        let flood = try raw(port)
        flood.writeRaw(Array(repeating: UInt8(ascii: "a"), count: 64 * 1024))
        XCTAssertNil(flood.readLine())
        flood.close()

        // The connect side refuses to talk TCP without both tokens.
        XCTAssertNil(connect(listener, token: nil))
        XCTAssertNil(connect(listener, token: ""))
        XCTAssertNil(ApprovalTransport.connect(endpoint: listener.endpoint, token: listener.token, serverToken: nil))
        XCTAssertNil(ApprovalTransport.connect(endpoint: listener.endpoint, token: listener.token, serverToken: ""))

        let client = try XCTUnwrap(connect(listener, token: listener.token))
        client.writeLine("ok")
        XCTAssertEqual(client.readLine(), "got:ok")
        client.close()
        wait(for: [served], timeout: 10)
        XCTAssertEqual(box.all, ["ok"])
    }

    func testListensOnLoopbackOnly() throws {
        let listener = try loopback()
        defer { listener.close() }
        let bound = try XCTUnwrap(listener.boundAddress())
        XCTAssertEqual(bound.host, "127.0.0.1")
        XCTAssertEqual(bound.port, listener.port)
        XCTAssertNotEqual(bound.port, 0)
        XCTAssertEqual(listener.endpoint, "tcp:127.0.0.1:\(listener.port)")
    }

    func testConnectOnlyAcceptsWellFormedEndpoints() throws {
        let listener = try loopback()
        defer { listener.close() }
        let port = listener.port
        for endpoint in ["tcp:0.0.0.0:\(port)", "tcp:localhost:\(port)", "tcp:192.168.1.10:\(port)", "tcp:127.0.0.1:",
                         "tcp:127.0.0.1:0", "tcp:127.0.0.1:70000", "tcp:127.0.0.1:+\(port)", "tcp:127.0.0.1: \(port)",
                         "tcp:127.0.0.1:\(port)x", "udp:127.0.0.1:\(port)", "unix:", "", "relative/path"] {
            XCTAssertNil(ApprovalTransport.connect(endpoint: endpoint, token: listener.token, serverToken: listener.serverToken), endpoint)
        }
        XCTAssertEqual(ApprovalEndpoint.parse("tcp:127.0.0.1:\(port)"), .loopback(port: port))
        XCTAssertEqual(ApprovalEndpoint.parse("unix:/tmp/x/s"), .unix("/tmp/x/s"))
    }

    func testOversizedLineIsRejected() throws {
        let listener = try loopback()
        defer { listener.close() }
        let box = Box()
        let served = serveOne(listener) { box.add($0) }
        let client = try XCTUnwrap(connect(listener, token: listener.token))
        DispatchQueue.global().async {
            client.writeRaw(Array(repeating: UInt8(ascii: "a"), count: ApprovalTransport.maxLineLength + 1) + [10])
        }
        wait(for: [served], timeout: 20)
        XCTAssertEqual(box.all, [nil], "the server gives up on a line over the cap")
        client.close()
    }

    func testLineAtTheCapIsAccepted() throws {
        let listener = try loopback()
        defer { listener.close() }
        let box = Box()
        let served = serveOne(listener) { box.add($0.map { "\($0.count)" }) }
        let client = try XCTUnwrap(connect(listener, token: listener.token))
        DispatchQueue.global().async {
            client.writeLine(String(repeating: "a", count: ApprovalTransport.maxLineLength))
        }
        wait(for: [served], timeout: 20)
        XCTAssertEqual(box.all, ["\(ApprovalTransport.maxLineLength)"])
        client.close()
    }

    func testSilentClientDoesNotBlockAccept() throws {
        let listener = try loopback(handshakeTimeout: 0.5)
        defer { listener.close() }
        let box = Box()
        let served = serveOne(listener) { box.add($0) }

        let silent = try raw(listener.port)
        defer { silent.close() }
        // A slow client that dribbles bytes is held to the same overall deadline.
        let slow = try raw(listener.port)
        defer { slow.close() }
        DispatchQueue.global().async {
            for _ in 0..<40 { slow.writeRaw([UInt8(ascii: "0")]); Thread.sleep(forTimeInterval: 0.1) }
        }

        let start = Date()
        let client = try XCTUnwrap(connect(listener, token: listener.token))
        client.writeLine("hello")
        XCTAssertEqual(client.readLine(), "got:hello")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        client.close()
        wait(for: [served], timeout: 5)
        XCTAssertEqual(box.all, ["hello"])
    }

    /// More silent clients than there are handshake threads: evicted handshakes stop within a wait slice and the
    /// accept loop waits for them instead of dropping clients, so the real shim still completes its handshake.
    func testFortySilentClientsStillLetTheRealShimThrough() throws {
        let listener = try loopback()
        defer { listener.close() }
        let box = Box()
        let served = serveOne(listener) { box.add($0) }
        let silent = try (0..<40).map { _ in try raw(listener.port) }
        defer { silent.forEach { $0.close() } }

        let start = Date()
        let client = try XCTUnwrap(connect(listener, token: listener.token), "handshake did not complete within 2 s")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        client.writeLine("through")
        XCTAssertEqual(client.readLine(), "got:through")
        client.close()
        wait(for: [served], timeout: 5)
        XCTAssertEqual(box.all, ["through"])
    }

    /// The eviction rule itself: a handshake may be cut off only once it has been pending the minimum age (50 ms).
    func testEvictionNeedsTheMinimumAge() {
        XCTAssertEqual(LoopbackListener.minimumEvictionAge, 0.05, accuracy: 0.0001)
        XCTAssertFalse(LoopbackListener.mayEvict(pendingFor: 0))
        XCTAssertFalse(LoopbackListener.mayEvict(pendingFor: 0.049))
        XCTAssertTrue(LoopbackListener.mayEvict(pendingFor: 0.050))
        XCTAssertTrue(LoopbackListener.mayEvict(pendingFor: 0.051))
        // With another minimum the same rule applies.
        XCTAssertFalse(LoopbackListener.mayEvict(pendingFor: 0.1, minimumAge: 0.2))
        XCTAssertTrue(LoopbackListener.mayEvict(pendingFor: 0.2, minimumAge: 0.2))
    }

    /// A stream of rapid silent clients cannot evict a real shim that connects in the middle of it: only handshakes
    /// pending longer than `minimumEvictionAge` are cut off, and a real shim sends its token at once.
    func testRapidSilentClientsCannotEvictARealShim() throws {
        final class Opened: @unchecked Sendable {
            private let lock = NSLock()
            private var all: [LineConnection] = []
            func add(_ connection: LineConnection) { lock.lock(); all.append(connection); lock.unlock() }
            func closeAll() { lock.lock(); let list = all; all = []; lock.unlock(); list.forEach { $0.close() } }
            var count: Int { lock.lock(); defer { lock.unlock() }; return all.count }
        }
        XCTAssertGreaterThanOrEqual(LoopbackListener.minimumEvictionAge, 0.03)
        XCTAssertLessThanOrEqual(LoopbackListener.minimumEvictionAge, 0.2)
        for round in 0..<5 {
            let listener = try loopback()
            defer { listener.close() }
            let box = Box()
            let served = serveOne(listener) { box.add($0) }
            let opened = Opened()
            let flood = DispatchGroup()
            let port = listener.port
            DispatchQueue.global().async(group: flood) {
                for _ in 0..<100 {
                    guard let connection = LoopbackConnection.open(port: port) else { continue }
                    connection.socket.setReceiveTimeout(5)
                    opened.add(connection)
                }
            }
            while opened.count < 30 { Thread.sleep(forTimeInterval: 0.001) }   // the shim connects mid-burst

            let start = Date()
            let client = connect(listener, token: listener.token)
            XCTAssertNotNil(client, "round \(round): the real shim was cut off")
            XCTAssertLessThan(Date().timeIntervalSince(start), 2, "round \(round)")
            client?.writeLine("through")
            XCTAssertEqual(client?.readLine(), "got:through", "round \(round)")
            client?.close()
            if client == nil { listener.close() }
            wait(for: [served], timeout: 5)
            flood.wait()
            opened.closeAll()
        }
    }

    /// Handshakes run side by side, so many silent clients (default 5 s handshake timeout) cost a slot each, not the line.
    func testManySilentClientsDoNotStallAValidOne() throws {
        let listener = try loopback()
        defer { listener.close() }
        let box = Box()
        let served = serveOne(listener) { box.add($0) }
        let silent = try (0..<16).map { _ in try raw(listener.port) }
        defer { silent.forEach { $0.close() } }
        Thread.sleep(forTimeInterval: 0.1)

        let start = Date()
        let client = try XCTUnwrap(connect(listener, token: listener.token))
        client.writeLine("through")
        XCTAssertEqual(client.readLine(), "got:through")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        client.close()
        wait(for: [served], timeout: 5)
        XCTAssertEqual(box.all, ["through"])
    }

    // MARK: - The host proves itself too

    /// A process that grabbed the port: reads one line (the client token), then answers with `reply` (or nothing),
    /// and records anything else the client sends.
    private func rogue(reply: String?) throws -> (port: UInt16, received: Box, done: XCTestExpectation) {
        let socket = try XCTUnwrap(Socket.listenLoopback())
        let port = try XCTUnwrap(socket.localIPv4()).port
        let received = Box()
        let done = expectation(description: "rogue finished")
        DispatchQueue.global().async {
            defer { socket.shutdownAndClose(); done.fulfill() }
            guard let client = socket.acceptClient() else { return }
            let connection = LineConnection(socket: client)
            client.setReceiveTimeout(3)
            received.add(connection.readLine())
            if let reply { connection.writeLine(reply) }
            received.add(connection.readLine())
            connection.close()
        }
        return (port, received, done)
    }

    func testRogueListenerCannotAnswer() throws {
        let token = LoopbackListener.makeToken(), serverToken = LoopbackListener.makeToken()
        let unreachable = #"{"behavior":"deny","message":"Tristan is not reachable."}"#
        let replies: [String?] = [
            #"{"behavior":"allow","updatedInput":{"command":"rm -rf ~"}}"#,
            flip(serverToken, at: 0), flip(serverToken, at: 63), String(serverToken.dropLast()), token, "",
            nil,
        ]
        for reply in replies {
            let rogue = try rogue(reply: reply)
            let decision = PermissionShim.decide(["tool_name": "Bash", "input": ["command": "rm -rf ~"]],
                                                 endpoint: "tcp:127.0.0.1:\(rogue.port)", token: token,
                                                 serverToken: serverToken, handshakeTimeout: 0.5)
            XCTAssertEqual(decision, unreachable, "reply: \(reply ?? "nothing")")
            wait(for: [rogue.done], timeout: 10)
            XCTAssertEqual(rogue.received.all.first ?? nil, token, "the rogue only ever saw the client token")
            XCTAssertEqual(rogue.received.all.dropFirst().compactMap { $0 }, [], "no request was sent: \(reply ?? "nothing")")
        }
    }

    func testShimTimesOutOnASilentHost() throws {
        let rogue = try rogue(reply: nil)
        let start = Date()
        XCTAssertNil(ApprovalTransport.connect(endpoint: "tcp:127.0.0.1:\(rogue.port)", token: LoopbackListener.makeToken(),
                                               serverToken: LoopbackListener.makeToken(), handshakeTimeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        wait(for: [rogue.done], timeout: 10)
    }

    func testCloseWakesAPendingAccept() throws {
        let listener = try loopback()
        let returned = expectation(description: "accept returned")
        let pending = listener
        DispatchQueue.global().async {
            XCTAssertNil(pending.accept())
            returned.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        listener.close()
        wait(for: [returned], timeout: 5)
    }

    // MARK: - Unix

    #if !os(Windows)   // Windows has no Unix-socket transport (listen/connect return nil there by design)
    func testUnixTransportStillRoundTrips() throws {
        let folder = try makeFolder()
        let listener = try XCTUnwrap(ApprovalTransport.listen(directory: folder, kind: .unix))
        defer { listener.close() }
        XCTAssertNil(listener.token)
        XCTAssertEqual(listener.endpoint, "unix:" + folder.appendingPathComponent("s").path)

        let box = Box()
        let served = serveOne(listener) { box.add($0) }
        let client = try XCTUnwrap(ApprovalTransport.connect(endpoint: listener.endpoint, token: nil))
        client.writeLine("ping")
        XCTAssertEqual(client.readLine(), "got:ping")
        client.close()
        wait(for: [served], timeout: 5)
        XCTAssertEqual(box.all, ["ping"])
    }
    #endif

    func testPlatformDefaultTransport() throws {
        #if os(Windows)
        XCTAssertEqual(ApprovalTransportKind.platformDefault, .loopback)
        #else
        XCTAssertEqual(ApprovalTransportKind.platformDefault, .unix)
        let folder = try makeFolder()
        let listener = try XCTUnwrap(ApprovalTransport.listen(directory: folder))
        defer { listener.close() }
        XCTAssertTrue(listener.endpoint.hasPrefix("unix:"))
        XCTAssertNil(listener.token)
        #endif
    }

    // MARK: - Permission server and shim

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, String)] = []
        func add(_ tool: String, _ detail: String) { lock.lock(); items.append((tool, detail)); lock.unlock() }
        var all: [(String, String)] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func decision(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private func checkServer(kind: ApprovalTransportKind) throws {
        let calls = Calls()
        let server = PermissionServer(workingDirectory: try makeFolder(), transport: kind) { tool, detail, _ in
            calls.add(tool, detail)
            return tool == "Bash"
        }
        XCTAssertTrue(server.start())
        defer { server.stop() }
        let endpoint = try XCTUnwrap(server.endpoint)

        if kind == .unix {
            XCTAssertNil(server.token)
            XCTAssertNil(server.serverToken)
        }
        let allowed = PermissionShim.decide(["tool_name": "Bash", "input": ["command": "ls -la"]], endpoint: endpoint,
                                            token: server.token, serverToken: server.serverToken)
        let allow = try XCTUnwrap(decision(allowed))
        XCTAssertEqual(allow["behavior"] as? String, "allow")
        XCTAssertEqual((allow["updatedInput"] as? [String: Any])?["command"] as? String, "ls -la")

        let denied = PermissionShim.decide(["tool_name": "Write", "input": ["file_path": "/tmp/x"]], endpoint: endpoint,
                                           token: server.token, serverToken: server.serverToken)
        let deny = try XCTUnwrap(decision(denied))
        XCTAssertEqual(deny["behavior"] as? String, "deny")
        XCTAssertEqual(deny["message"] as? String, "Denied by the operator in Tristan.")

        XCTAssertEqual(calls.all.map(\.0), ["Bash", "Write"])
        XCTAssertEqual(calls.all.map(\.1), ["ls -la", "/tmp/x"])
    }

    func testPermissionServerOverLoopback() throws {
        try checkServer(kind: .loopback)
    }

    #if !os(Windows)   // no Unix-socket transport on Windows
    func testPermissionServerOverUnix() throws {
        try checkServer(kind: .unix)
    }
    #endif

    func testShimWithWrongTokenIsDeniedAndNeverReachesTheOperator() throws {
        let calls = Calls()
        let server = PermissionServer(workingDirectory: try makeFolder(), transport: .loopback) { tool, detail, _ in
            calls.add(tool, detail)
            return true
        }
        XCTAssertTrue(server.start())
        defer { server.stop() }
        let endpoint = try XCTUnwrap(server.endpoint)
        let unreachable = #"{"behavior":"deny","message":"Tristan is not reachable."}"#
        let token = try XCTUnwrap(server.token), serverToken = try XCTUnwrap(server.serverToken)
        let request: [String: Any] = ["tool_name": "Bash", "input": ["command": "ls"]]
        for wrong in ["00", flip(token, at: 0), flip(token, at: 63), serverToken] {
            XCTAssertEqual(PermissionShim.decide(request, endpoint: endpoint, token: wrong, serverToken: serverToken), unreachable)
        }
        XCTAssertEqual(PermissionShim.decide(request, endpoint: endpoint, token: nil, serverToken: serverToken), unreachable)
        // The right client token but the shim expects another host: it stops before sending the request.
        XCTAssertEqual(PermissionShim.decide(request, endpoint: endpoint, token: token, serverToken: flip(serverToken, at: 63)), unreachable)
        XCTAssertEqual(PermissionShim.decide(request, endpoint: endpoint, token: token, serverToken: nil), unreachable)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(calls.all.isEmpty)
        // The host is still serving.
        XCTAssertEqual(decision(PermissionShim.decide(request, endpoint: endpoint, token: token, serverToken: serverToken))?["behavior"] as? String,
                       "allow")
    }

    func testStoppedServerIsUnreachable() throws {
        let server = PermissionServer(workingDirectory: try makeFolder(), transport: .loopback) { _, _, _ in true }
        XCTAssertTrue(server.start())
        let endpoint = try XCTUnwrap(server.endpoint)
        let token = server.token, serverToken = server.serverToken
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.directory.path))
        XCTAssertEqual(PermissionShim.decide(["tool_name": "Bash", "input": [:]], endpoint: endpoint, token: token, serverToken: serverToken),
                       #"{"behavior":"deny","message":"Tristan is not reachable."}"#)
    }

    // MARK: - MCP config

    private func readConfig(_ url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let servers = try XCTUnwrap(object?["mcpServers"] as? [String: Any])
        return try XCTUnwrap(servers["tristan"] as? [String: Any])
    }

    func testMCPConfigCarriesTheTokenInEnvNeverInArgs() throws {
        let folder = try makeFolder()
        let listener = try loopback()
        defer { listener.close() }
        let token = try XCTUnwrap(listener.token)
        let serverToken = try XCTUnwrap(listener.serverToken)
        let url = try XCTUnwrap(ClaudeCodeProvider.writeMCPConfig(executable: "/Applications/Tristan.app/Contents/MacOS/Tristan",
                                                                  endpoint: listener.endpoint, token: token,
                                                                  serverToken: serverToken, in: folder))
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, folder.standardizedFileURL.path)
        let server = try readConfig(url)
        XCTAssertEqual(server["command"] as? String, "/Applications/Tristan.app/Contents/MacOS/Tristan")
        let args = try XCTUnwrap(server["args"] as? [String])
        XCTAssertEqual(args, ["--mcp-permission", listener.endpoint])
        XCTAssertTrue(args[1].hasPrefix("tcp:127.0.0.1:"))
        XCTAssertFalse(args.contains { $0.contains(token) || $0.contains(serverToken) })
        XCTAssertEqual(server["env"] as? [String: String],
                       ["TRISTAN_APPROVAL_TOKEN": token, "TRISTAN_APPROVAL_SERVER_TOKEN": serverToken])
        XCTAssertEqual(ApprovalTransport.tokenEnvironmentKey, "TRISTAN_APPROVAL_TOKEN")
        XCTAssertEqual(ApprovalTransport.serverTokenEnvironmentKey, "TRISTAN_APPROVAL_SERVER_TOKEN")
    }

    /// mcp.json is created new (CREATE_NEW / O_EXCL): a file already there, for example one planted by another user
    /// in a shared temporary folder, is never written through or replaced.
    func testMCPConfigIsNeverWrittenOverAnExistingFile() throws {
        let folder = try makeFolder()
        let planted = Data(#"{"mcpServers":{"tristan":{"command":"/tmp/evil","args":[]}}}"#.utf8)
        let target = folder.appendingPathComponent("mcp.json")
        try planted.write(to: target)
        XCTAssertNil(ClaudeCodeProvider.writeMCPConfig(executable: "/x/Tristan", endpoint: "tcp:127.0.0.1:1", token: "t",
                                                       serverToken: "s", in: folder))
        XCTAssertEqual(try Data(contentsOf: target), planted)
        // A fresh folder works, once.
        let fresh = try makeFolder()
        XCTAssertNotNil(ClaudeCodeProvider.writeMCPConfig(executable: "/x/Tristan", endpoint: "tcp:127.0.0.1:1", token: "t",
                                                          serverToken: "s", in: fresh))
        XCTAssertNil(ClaudeCodeProvider.writeMCPConfig(executable: "/x/Tristan", endpoint: "tcp:127.0.0.1:2", token: "t",
                                                       serverToken: "s", in: fresh))
    }

    #if !os(Windows)   // the platform default is loopback on Windows, covered by the env-block test above
    func testMCPConfigOnTheMacDefaultHasNoEnvBlock() throws {
        let folder = try makeFolder()
        let listener = try XCTUnwrap(ApprovalTransport.listen(directory: folder))
        defer { listener.close() }
        let url = try XCTUnwrap(ClaudeCodeProvider.writeMCPConfig(executable: "/x/Tristan", endpoint: listener.endpoint,
                                                                  token: listener.token, serverToken: listener.serverToken,
                                                                  in: folder))
        let server = try readConfig(url)
        XCTAssertEqual(server["args"] as? [String], ["--mcp-permission", "unix:" + folder.appendingPathComponent("s").path])
        XCTAssertNil(server["env"])
        XCTAssertEqual(server.keys.sorted(), ["args", "command"])
    }
    #endif

    func testShimExecutableIsAbsolute() {
        let isFile: (String) -> Bool = { $0 == "/usr/local/bin/tristan" }
        XCTAssertEqual(ClaudeCodeProvider.absoluteExecutable("/opt/t/tristan", currentDirectory: "/w", path: "", windows: false, isFile: isFile),
                       "/opt/t/tristan")
        XCTAssertEqual(ClaudeCodeProvider.absoluteExecutable("bin/tristan", currentDirectory: "/w", path: "", windows: false, isFile: isFile),
                       "/w/bin/tristan")
        XCTAssertEqual(ClaudeCodeProvider.absoluteExecutable("./tristan", currentDirectory: "/w/", path: "", windows: false, isFile: isFile),
                       "/w/tristan")
        XCTAssertEqual(ClaudeCodeProvider.absoluteExecutable("tristan", currentDirectory: "/w", path: "/usr/bin:/usr/local/bin", windows: false, isFile: isFile),
                       "/usr/local/bin/tristan")
        XCTAssertNil(ClaudeCodeProvider.absoluteExecutable("tristan", currentDirectory: "/w", path: "/usr/bin", windows: false, isFile: isFile))
        XCTAssertNil(ClaudeCodeProvider.absoluteExecutable("", currentDirectory: "/w", path: "/usr/bin", windows: false, isFile: isFile))

        let winFile: (String) -> Bool = { $0 == "C:\\Tools\\tristan.exe" }
        XCTAssertEqual(ClaudeCodeProvider.absoluteExecutable("C:\\Tools\\tristan.exe", currentDirectory: "C:\\w", path: "", windows: true, isFile: winFile),
                       "C:\\Tools\\tristan.exe")
        XCTAssertEqual(ClaudeCodeProvider.absoluteExecutable("tristan", currentDirectory: "C:\\w", path: "C:\\Windows;C:\\Tools", windows: true, isFile: winFile),
                       "C:\\Tools\\tristan.exe")
        XCTAssertEqual(ClaudeCodeProvider.absoluteExecutable("bin\\tristan.exe", currentDirectory: "C:\\w", path: "", windows: true, isFile: winFile),
                       "C:\\w\\bin\\tristan.exe")
    }

    // MARK: - Provider end to end, with a fake `claude` playing the MCP shim's part

    /// A zsh stand-in for `claude`: reads the MCP config it was given, connects to the endpoint the way the shim does
    /// (token line first for TCP), sends one Bash request and reports the decision as a stream-json result.
    private func fakeClaude(in folder: URL) throws -> URL {
        #if os(Windows)
        return try fakeClaudeForWindows(in: folder)
        #else
        let script = folder.appendingPathComponent("fake-claude")
        let text = #"""
        #!/bin/zsh
        cfg=""
        for ((i = 1; i <= $#; i++)); do [[ ${@[i]} == --mcp-config ]] && cfg=${@[i+1]}; done
        [[ -n $cfg ]] || { print -r -- '{"type":"result","result":"no config","is_error":true}'; exit 2 }
        endpoint=$(/usr/bin/plutil -extract mcpServers.tristan.args.1 raw -o - "$cfg")
        token=$(/usr/bin/plutil -extract mcpServers.tristan.env.TRISTAN_APPROVAL_TOKEN raw -o - "$cfg" 2>/dev/null)
        expected=$(/usr/bin/plutil -extract mcpServers.tristan.env.TRISTAN_APPROVAL_SERVER_TOKEN raw -o - "$cfg" 2>/dev/null)
        if [[ $endpoint == tcp:127.0.0.1:* ]]; then
          zmodload zsh/net/tcp
          ztcp 127.0.0.1 ${endpoint##*:} || exit 3
          fd=$REPLY
          print -r -u $fd -- "$token"
          IFS= read -r -t 5 -u $fd answer
          if [[ ${#expected} != 64 || $answer != $expected ]]; then
            print -r -- '{"type":"result","result":"host did not prove itself","is_error":true}'; exit 4
          fi
        else
          zmodload zsh/net/socket
          zsocket ${endpoint#unix:} || exit 3
          fd=$REPLY
          token=none
        fi
        print -r -u $fd -- '{"tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"t1"}'
        IFS= read -r -u $fd reply
        exec {fd}>&-
        if [[ $reply == *'"behavior":"allow"'* ]]; then r=allowed; else r=denied; fi
        print -r -- "{\"type\":\"result\",\"result\":\"$r token=${#token}\",\"is_error\":false}"
        """#
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
        #endif
    }

    #if os(Windows)
    /// The Windows stand-in has the shape of the real `claude.cmd`: an npm-style shim in front of a node script, so the
    /// launcher runs node on the script directly. The script plays the shim's part over loopback TCP.
    private func fakeClaudeForWindows(in folder: URL) throws -> URL {
        let shim = folder.appendingPathComponent("fake-claude.cmd")
        try Data("@ECHO off\r\nnode \"%~dp0\\fake-claude.js\" %*\r\n".utf8).write(to: shim)
        let script = #"""
        const fs = require('fs'), net = require('net');
        const args = process.argv.slice(2);
        const out = o => process.stdout.write(JSON.stringify(o) + '\n');
        const i = args.indexOf('--mcp-config');
        if (i < 0) { out({type: 'result', result: 'no config', is_error: true}); process.exit(2); }
        const server = JSON.parse(fs.readFileSync(args[i + 1], 'utf8')).mcpServers.tristan;
        const env = server.env || {};
        const m = /^tcp:127\.0\.0\.1:(\d+)$/.exec(server.args[1]);
        if (!m) { out({type: 'result', result: 'not tcp: ' + server.args[1], is_error: true}); process.exit(3); }
        const token = env.TRISTAN_APPROVAL_TOKEN || '', expected = env.TRISTAN_APPROVAL_SERVER_TOKEN || '';
        const socket = net.connect(Number(m[1]), '127.0.0.1', () => socket.write(token + '\n'));
        let buffer = '', proven = false;
        socket.on('data', data => {
          buffer += data;
          let n;
          while ((n = buffer.indexOf('\n')) >= 0) {
            const line = buffer.slice(0, n); buffer = buffer.slice(n + 1);
            if (!proven) {
              if (expected.length !== 64 || line !== expected) {
                out({type: 'result', result: 'host did not prove itself', is_error: true}); process.exit(4);
              }
              proven = true;
              socket.write(JSON.stringify({tool_name: 'Bash', input: {command: 'ls'}, tool_use_id: 't1'}) + '\n');
            } else {
              socket.end();
              const r = line.includes('"behavior":"allow"') ? 'allowed' : 'denied';
              out({type: 'result', result: r + ' token=' + token.length, is_error: false});
              process.exit(0);
            }
          }
        });
        socket.on('error', e => { out({type: 'result', result: 'socket: ' + e.message, is_error: true}); process.exit(5); });
        """#
        try Data(script.utf8).write(to: folder.appendingPathComponent("fake-claude.js"))
        return shim
    }
    #endif

    private func runProvider(kind: ApprovalTransportKind, allow: Bool) async throws -> (String?, [String]) {
        let folder = try makeFolder()
        var provider = ClaudeCodeProvider(mode: .ask)
        provider.transport = kind
        let tool = try fakeClaude(in: folder)
        provider.claudeTool = tool.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? tool.path
        let calls = Calls()
        var result: String?
        for await event in provider.run(task: "list files", workingDirectory: folder, approve: { request in
            calls.add(request.summary, request.detail)
            return allow
        }) {
            switch event {
            case .done(let text): result = text
            case .failed(let text): result = "FAILED " + text
            default: break
            }
        }
        return (result, calls.all.map { "\($0.0) [\($0.1)]" })
    }

    func testProviderApprovalFlowOverLoopback() async throws {
        let (allowed, calls) = try await runProvider(kind: .loopback, allow: true)
        XCTAssertEqual(allowed, "allowed token=64")
        XCTAssertEqual(calls, ["Allow Bash? [ls]"])
        let (denied, _) = try await runProvider(kind: .loopback, allow: false)
        XCTAssertEqual(denied, "denied token=64")
    }

    #if !os(Windows)   // no Unix-socket transport on Windows
    func testProviderApprovalFlowOverUnix() async throws {
        let (allowed, calls) = try await runProvider(kind: .unix, allow: true)
        XCTAssertEqual(allowed, "allowed token=4")
        XCTAssertEqual(calls, ["Allow Bash? [ls]"])
        let (denied, _) = try await runProvider(kind: .unix, allow: false)
        XCTAssertEqual(denied, "denied token=4")
    }
    #endif
}
