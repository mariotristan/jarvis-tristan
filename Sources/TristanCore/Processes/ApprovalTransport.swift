import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// The channel between the Claude Code MCP shim (`--mcp-permission <endpoint>`) and the host's PermissionServer.
// Newline-delimited JSON in both directions: one request line from the shim, one decision line back.
//
// Two transports:
// - `unix:<path>`: a Unix domain socket in a per-run folder only the user can open (the Mac default).
// - `tcp:127.0.0.1:<port>`: loopback TCP (the Windows default). Any local process can connect to a loopback port, so
//   the first line a client sends must be a one-time 256-bit token; anything else is closed without a word. The token
//   reaches the shim through its environment (the MCP config's `env` block), never its command line.

/// One accepted or opened connection, framed in lines.
package protocol ApprovalConnection: AnyObject {
    /// The next line without its newline; nil at the end of the stream, on an error, on an empty line or on a line over
    /// `ApprovalTransport.maxLineLength` bytes.
    func readLine() -> String?
    func writeLine(_ text: String)
    func close()
}

package protocol ApprovalListener: AnyObject {
    /// What the shim is given: `unix:<path>` or `tcp:127.0.0.1:<port>`.
    var endpoint: String { get }
    /// The secret a client must send as its first line; nil for a Unix socket (the folder's permissions guard it).
    var token: String? { get }
    /// Blocks until an authenticated client connects; nil once the listener is closed.
    func accept() -> ApprovalConnection?
    func close()
}

package enum ApprovalTransportKind: Sendable, Equatable {
    case unix
    case loopback

    package static var platformDefault: ApprovalTransportKind {
        #if os(Windows)
        return .loopback
        #else
        return .unix
        #endif
    }
}

package enum ApprovalTransport {
    /// The environment variable the shim reads its token from.
    package static let tokenEnvironmentKey = "TRISTAN_APPROVAL_TOKEN"
    /// The longest line either side accepts once authenticated. Generous because the decision echoes the tool input
    /// (a `Write` carries the whole file); it only bounds what a client can make the host buffer.
    package static let maxLineLength = 16 * 1024 * 1024

    package static func listen(directory: URL) -> ApprovalListener? {
        listen(directory: directory, kind: .platformDefault)
    }

    /// `directory` holds the Unix socket (`<directory>/s`); the loopback transport does not use it.
    package static func listen(directory: URL, kind: ApprovalTransportKind) -> ApprovalListener? {
        switch kind {
        case .loopback:
            return LoopbackListener()
        case .unix:
            #if os(Windows)
            return nil
            #else
            return UnixListener(path: directory.appendingPathComponent("s").path)
            #endif
        }
    }

    /// Opens a connection to a listener. For TCP the token is sent as the first line, and a missing token is refused.
    package static func connect(endpoint: String, token: String?) -> ApprovalConnection? {
        switch ApprovalEndpoint.parse(endpoint) {
        case .none:
            return nil
        case .unix(let path):
            #if os(Windows)
            return nil
            #else
            guard let fd = UnixSocket.connect(to: path) else { return nil }
            return LineConnection(socket: Socket(handle: fd))
            #endif
        case .loopback(let port):
            guard let token, !token.isEmpty, !token.utf8.contains(where: { $0 == 10 || $0 == 13 }) else { return nil }
            return LoopbackConnection.open(port: port, token: token)
        }
    }
}

package enum ApprovalEndpoint: Equatable {
    case unix(String)
    case loopback(port: UInt16)

    private static let tcpPrefix = "tcp:127.0.0.1:"

    /// Only the exact loopback address is accepted for TCP, so a tampered config cannot point the shim (and its token)
    /// at another host.
    static func parse(_ text: String) -> ApprovalEndpoint? {
        if text.hasPrefix("unix:") {
            let path = String(text.dropFirst("unix:".count))
            return path.isEmpty ? nil : .unix(path)
        }
        if text.hasPrefix(tcpPrefix) {
            let digits = text.dropFirst(tcpPrefix.count)
            guard (1...5).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let port = UInt16(digits), port != 0 else { return nil }
            return .loopback(port: port)
        }
        #if !os(Windows)
        // A bare socket path: what the shim was given before endpoints had a scheme.
        if text.hasPrefix("/") { return .unix(text) }
        #endif
        return nil
    }
}

// MARK: - Line framing (shared by both transports and all platforms)

/// Newline-delimited text over a `Socket`, with a cap on how much a line may make it buffer.
final class LineConnection: ApprovalConnection, @unchecked Sendable {
    let socket: Socket
    private var buffer: [UInt8] = []
    /// How far `buffer` has been searched for a newline.
    private var scanned = 0
    private var broken = false

    init(socket: Socket) {
        self.socket = socket
    }

    func readLine() -> String? {
        readLineBytes(limit: ApprovalTransport.maxLineLength, deadline: nil, requireNewline: false)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// The next line's bytes. Nil (and the connection is done) on end of stream with nothing buffered, an error, a
    /// receive timeout, the deadline passing or a line longer than `limit`; nil for an empty line (which is consumed).
    /// With `requireNewline`, bytes cut off by the end of the stream do not count as a line.
    func readLineBytes(limit: Int, deadline: Date?, requireNewline: Bool) -> [UInt8]? {
        guard !broken else { return nil }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer[scanned...].firstIndex(of: 10) {
                guard newline <= limit else { return fail() }
                let line = Array(buffer[..<newline])
                buffer.removeSubrange(...newline)
                scanned = 0
                return line.isEmpty ? nil : line
            }
            scanned = buffer.count
            guard buffer.count <= limit else { return fail() }
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return fail() }
                socket.setReceiveTimeout(remaining)
            }
            let count = chunk.withUnsafeMutableBytes { socket.receive(into: $0) }
            guard count > 0 else {
                let rest = buffer
                _ = fail()
                return rest.isEmpty || requireNewline ? nil : rest
            }
            buffer.append(contentsOf: chunk[..<count])
        }
    }

    private func fail() -> [UInt8]? {
        broken = true
        buffer = []
        scanned = 0
        return nil
    }

    func writeLine(_ text: String) {
        writeRaw(Array((text + "\n").utf8))
    }

    func writeRaw(_ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes[offset...].withUnsafeBytes { socket.transmit($0) }
            if sent <= 0 { break }
            offset += sent
        }
    }

    func close() {
        socket.shutdownAndClose()
    }
}

// MARK: - Loopback TCP

/// Listens on 127.0.0.1 (never any other address) on a port the system picks. Hands out only connections whose first
/// line is the token.
package final class LoopbackListener: ApprovalListener, @unchecked Sendable {
    package let port: UInt16
    package let token: String?
    package var endpoint: String { "tcp:127.0.0.1:\(port)" }

    /// The token line is 64 bytes; a first line longer than this is not a token.
    static let handshakeLimit = 128

    private let socket: Socket
    private let secret: [UInt8]
    private let handshakeTimeout: TimeInterval
    private let lock = NSLock()
    private var closed = false

    /// `handshakeTimeout` bounds how long one client may take to send its token line, so a silent or slow client
    /// cannot hold up the clients behind it.
    package init?(handshakeTimeout: TimeInterval = 5) {
        guard let socket = Socket.listenLoopback() else { return nil }
        guard let bound = socket.localIPv4(), bound.host == "127.0.0.1", bound.port != 0 else {
            socket.shutdownAndClose()
            return nil
        }
        self.socket = socket
        port = bound.port
        let token = Self.makeToken()
        self.token = token
        secret = Array(token.utf8)
        self.handshakeTimeout = handshakeTimeout
    }

    /// 32 bytes from the system's secure generator (arc4random on Apple, getrandom on Linux, BCryptGenRandom on
    /// Windows) as lower-case hex.
    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let digits = Array("0123456789abcdef")
        var text = ""
        for _ in 0..<32 {
            let byte = UInt8.random(in: .min ... .max, using: &generator)
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return text
    }

    /// Compares every byte whatever the first difference, so timing does not reveal how much of a guess was right.
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<a.count { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    package func accept() -> ApprovalConnection? {
        while true {
            if isClosed { return nil }
            guard let client = socket.acceptClient() else { return nil }
            if isClosed { client.shutdownAndClose(); return nil }
            let connection = LineConnection(socket: client)
            let deadline = Date().addingTimeInterval(handshakeTimeout)
            if let first = connection.readLineBytes(limit: Self.handshakeLimit, deadline: deadline, requireNewline: true),
               Self.constantTimeEqual(first, secret) {
                client.setReceiveTimeout(nil)
                return connection
            }
            connection.close()
        }
    }

    package func close() {
        lock.lock()
        closed = true
        lock.unlock()
        socket.shutdownAndClose()
    }

    /// The address the socket is bound to, from the system (`getsockname`).
    func boundAddress() -> (host: String, port: UInt16)? {
        socket.localIPv4()
    }
}

enum LoopbackConnection {
    /// Connects to 127.0.0.1:`port` and, when given, sends the token line.
    static func open(port: UInt16, token: String?) -> LineConnection? {
        guard let socket = Socket.connectLoopback(port: port) else { return nil }
        let connection = LineConnection(socket: socket)
        if let token { connection.writeLine(token) }
        return connection
    }
}

// MARK: - Unix domain socket

#if !os(Windows)
/// `<directory>/s`, guarded by the folder's 0700 permissions.
final class UnixListener: ApprovalListener, @unchecked Sendable {
    let path: String
    var endpoint: String { "unix:" + path }
    var token: String? { nil }

    private let socket: Socket
    private let lock = NSLock()
    private var closed = false

    init?(path: String) {
        guard let fd = UnixSocket.listen(at: path) else { return nil }
        self.path = path
        socket = Socket(handle: fd)
    }

    func accept() -> ApprovalConnection? {
        guard let client = socket.acceptClient() else { return nil }
        lock.lock(); let closed = closed; lock.unlock()
        if closed { client.shutdownAndClose(); return nil }
        return LineConnection(socket: client)
    }

    func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        socket.shutdownAndClose()
        if !wasClosed { _ = unlink(path) }
    }
}
#endif

// MARK: - Platform sockets

/// The only platform-specific surface: a stream socket handle (an `Int32` descriptor on POSIX, a 64-bit `SOCKET` on
/// Windows) and the calls the transports need. Every socket is kept out of child processes and never raises SIGPIPE.
final class Socket: @unchecked Sendable {
    #if os(Windows)
    typealias Handle = SOCKET
    /// INVALID_SOCKET, `(SOCKET)(~0)`.
    static let invalid: Handle = ~SOCKET(0)
    #else
    typealias Handle = Int32
    static let invalid: Handle = -1
    #endif

    private let lock = NSLock()
    private var handle: Handle

    init(handle: Handle) {
        self.handle = handle
        Self.harden(handle)
    }

    deinit {
        if handle != Self.invalid { Self.closeHandle(handle) }
    }

    private var current: Handle? {
        lock.lock(); defer { lock.unlock() }
        return handle == Self.invalid ? nil : handle
    }

    /// Idempotent. Shutting down first wakes a thread blocked in `acceptClient` or `receive`.
    func shutdownAndClose() {
        lock.lock()
        let old = handle
        handle = Self.invalid
        lock.unlock()
        guard old != Self.invalid else { return }
        Self.shutdownHandle(old)
        Self.closeHandle(old)
    }

    #if os(Windows)
    private static let winsockReady: Bool = {
        var data = WSADATA()
        return WSAStartup(WORD(0x0202), &data) == 0
    }()

    private static func harden(_ handle: Handle) {
        // Not inherited by child processes (claude, node); HANDLE_FLAG_INHERIT is 0x1.
        _ = SetHandleInformation(HANDLE(bitPattern: UInt(handle)), DWORD(0x1), 0)
    }

    private static func closeHandle(_ handle: Handle) { _ = closesocket(handle) }
    private static func shutdownHandle(_ handle: Handle) { _ = WinSDK.shutdown(handle, 2 /* SD_BOTH */) }

    private static func newStreamSocket() -> Handle? {
        guard winsockReady else { return nil }
        // WSA_FLAG_OVERLAPPED (0x01, what socket() uses) | WSA_FLAG_NO_HANDLE_INHERIT (0x80).
        let handle = WSASocketW(AF_INET, SOCK_STREAM, 0, nil, 0, DWORD(0x01 | 0x80))
        return handle == invalid ? nil : handle
    }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
        return address
    }

    static func listenLoopback() -> Socket? {
        guard let handle = newStreamSocket() else { return nil }
        // SO_EXCLUSIVEADDRUSE, `(int)(~SO_REUSEADDR)`: no other socket may bind this port while we hold it.
        var one: Int32 = 1
        let exclusive = withUnsafePointer(to: &one) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Int32>.size) {
                setsockopt(handle, SOL_SOCKET, ~Int32(SO_REUSEADDR), $0, Int32(MemoryLayout<Int32>.size))
            }
        }
        var address = loopbackAddress(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { WinSDK.bind(handle, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
        }
        guard exclusive == 0, bound == 0, WinSDK.listen(handle, 16) == 0 else { closeHandle(handle); return nil }
        return Socket(handle: handle)
    }

    static func connectLoopback(port: UInt16) -> Socket? {
        guard let handle = newStreamSocket() else { return nil }
        var address = loopbackAddress(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { WinSDK.connect(handle, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { closeHandle(handle); return nil }
        return Socket(handle: handle)
    }

    func acceptClient() -> Socket? {
        while true {
            guard let handle = current else { return nil }
            let client = WinSDK.accept(handle, nil, nil)
            if client != Self.invalid { return Socket(handle: client) }
            let error = WSAGetLastError()
            // WSAEINTR (10004), WSAECONNRESET (10054): a client gave up before we took it.
            if error == 10004 || error == 10054 { continue }
            return nil
        }
    }

    /// Bytes read; 0 at end of stream; negative on an error or a receive timeout.
    func receive(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        guard let handle = current, let base = buffer.baseAddress else { return -1 }
        let count = Int32(clamping: buffer.count)
        return Int(WinSDK.recv(handle, base.assumingMemoryBound(to: CChar.self), count, 0))
    }

    func transmit(_ bytes: UnsafeRawBufferPointer) -> Int {
        guard let handle = current, let base = bytes.baseAddress else { return -1 }
        let count = Int32(clamping: bytes.count)
        return Int(WinSDK.send(handle, base.assumingMemoryBound(to: CChar.self), count, 0))
    }

    /// nil: wait forever.
    func setReceiveTimeout(_ seconds: TimeInterval?) {
        guard let handle = current else { return }
        // A DWORD of milliseconds; 0 means no timeout, so a positive timeout is at least 1 ms.
        var milliseconds: DWORD = 0
        if let seconds { milliseconds = DWORD(clamping: max(1, Int64((seconds * 1000).rounded(.up)))) }
        _ = withUnsafePointer(to: &milliseconds) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<DWORD>.size) {
                setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, $0, Int32(MemoryLayout<DWORD>.size))
            }
        }
    }

    func localIPv4() -> (host: String, port: UInt16)? {
        guard let handle = current else { return nil }
        var address = sockaddr_in()
        var length = Int32(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(handle, $0, &length) }
        }
        guard rc == 0, Int32(address.sin_family) == AF_INET else { return nil }
        return (Self.dotted(UInt32(bigEndian: address.sin_addr.S_un.S_addr)), UInt16(bigEndian: address.sin_port))
    }
    #else
    private static func harden(_ fd: Handle) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    private static func closeHandle(_ fd: Handle) { _ = posixClose(fd) }
    private static func shutdownHandle(_ fd: Handle) { _ = posixShutdown(fd) }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        return address
    }

    static func listenLoopback() -> Socket? {
        let fd = socket(AF_INET, posixStreamType, 0)
        guard fd >= 0 else { return nil }
        var address = loopbackAddress(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, posixListen(fd, 16) == 0 else { _ = posixClose(fd); return nil }
        return Socket(handle: fd)
    }

    static func connectLoopback(port: UInt16) -> Socket? {
        let fd = socket(AF_INET, posixStreamType, 0)
        guard fd >= 0 else { return nil }
        var address = loopbackAddress(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { posixConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { _ = posixClose(fd); return nil }
        return Socket(handle: fd)
    }

    func acceptClient() -> Socket? {
        while true {
            guard let fd = current else { return nil }
            let client = posixAccept(fd)
            if client >= 0 { return Socket(handle: client) }
            // A signal, or a client that gave up before we took it.
            if errno == EINTR || errno == ECONNABORTED { continue }
            return nil
        }
    }

    /// Bytes read; 0 at end of stream; negative on an error or a receive timeout.
    func receive(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        guard let fd = current else { return -1 }
        while true {
            let count = recv(fd, buffer.baseAddress, buffer.count, 0)
            if count < 0, errno == EINTR { continue }
            return count
        }
    }

    func transmit(_ bytes: UnsafeRawBufferPointer) -> Int {
        guard let fd = current else { return -1 }
        while true {
            let count = send(fd, bytes.baseAddress, bytes.count, posixSendFlags)
            if count < 0, errno == EINTR { continue }
            return count
        }
    }

    /// nil: wait forever.
    func setReceiveTimeout(_ seconds: TimeInterval?) {
        guard let fd = current else { return }
        var time = timeval()
        if let seconds {
            // An all-zero timeval means no timeout, so a positive timeout is at least 1 ms.
            let micro = max(1000, Int64((seconds * 1_000_000).rounded(.up)))
            time.tv_sec = .init(micro / 1_000_000)
            time.tv_usec = .init(micro % 1_000_000)
        }
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    func localIPv4() -> (host: String, port: UInt16)? {
        guard let fd = current else { return nil }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard rc == 0, Int32(address.sin_family) == AF_INET else { return nil }
        return (Self.dotted(UInt32(bigEndian: address.sin_addr.s_addr)), UInt16(bigEndian: address.sin_port))
    }
    #endif

    private static func dotted(_ address: UInt32) -> String {
        "\(address >> 24).\((address >> 16) & 0xFF).\((address >> 8) & 0xFF).\(address & 0xFF)"
    }
}

#if !os(Windows)
// Free functions, so the C calls are not shadowed by members of the same name.
#if canImport(Darwin)
let posixStreamType = SOCK_STREAM
private let posixSendFlags: Int32 = 0
#else
let posixStreamType = Int32(SOCK_STREAM.rawValue)
private let posixSendFlags = Int32(MSG_NOSIGNAL)
#endif

func posixClose(_ fd: Int32) -> Int32 { close(fd) }
func posixListen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
func posixConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 { connect(fd, address, length) }
func posixAccept(_ fd: Int32) -> Int32 { accept(fd, nil, nil) }
func posixShutdown(_ fd: Int32) -> Int32 { shutdown(fd, Int32(SHUT_RDWR)) }
#endif
