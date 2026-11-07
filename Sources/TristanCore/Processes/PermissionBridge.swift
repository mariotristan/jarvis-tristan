import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if os(Windows)
import WinSDK
#endif

#if !os(Windows)
/// The Unix domain socket half of the approval transport (`unix:<path>`); see ApprovalTransport.swift.
package enum UnixSocket {
    /// nil when the path does not fit `sun_path` (a truncated path would bind somewhere else).
    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    static func listen(at path: String) -> Int32? {
        guard var addr = address(path) else { return nil }
        let fd = socket(AF_UNIX, posixStreamType, 0)
        guard fd >= 0 else { return nil }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, posixListen(fd, 8) == 0 else { _ = posixClose(fd); return nil }
        return fd
    }

    static func connect(to path: String) -> Int32? {
        guard var addr = address(path) else { return nil }
        let fd = socket(AF_UNIX, posixStreamType, 0)
        guard fd >= 0 else { return nil }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { posixConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { _ = posixClose(fd); return nil }
        return fd
    }
}
#endif

/// Runs inside the app. Receives permission requests from the MCP shim and asks the operator.
package final class PermissionServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ tool: String, _ detail: String, _ rule: ApprovalRule?) async -> Bool

    /// The per-run folder: the Unix socket and the MCP config live here. Only the current user can open it.
    let directory: URL
    private let transport: ApprovalTransportKind
    private let lock = NSLock()
    private var listener: ApprovalListener?
    private let handler: Handler
    private let workingDirectory: URL

    init(workingDirectory: URL, transport: ApprovalTransportKind = .platformDefault, handler: @escaping Handler) {
        self.workingDirectory = workingDirectory
        self.transport = transport
        let short = UUID().uuidString.prefix(8)
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tristan-\(short)")
        self.handler = handler
    }

    /// What the shim connects to, once started.
    var endpoint: String? {
        lock.lock(); defer { lock.unlock() }
        return listener?.endpoint
    }

    /// The shim's secret for a loopback listener; nil for a Unix socket.
    var token: String? {
        lock.lock(); defer { lock.unlock() }
        return listener?.token
    }

    /// What the host answers the shim with, for a loopback listener; nil for a Unix socket.
    var serverToken: String? {
        lock.lock(); defer { lock.unlock() }
        return listener?.serverToken
    }

    func start() -> Bool {
        guard Self.createPrivateDirectory(directory) else { return false }
        guard let listener = ApprovalTransport.listen(directory: directory, kind: transport) else { return false }
        lock.lock()
        self.listener = listener
        lock.unlock()
        nonisolated(unsafe) let accepting = listener
        DispatchQueue.global().async { [weak self] in
            while let client = accepting.accept() {
                guard let self else { client.close(); break }
                self.serve(client)
            }
        }
        return true
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        lock.unlock()
        listener?.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func createPrivateDirectory(_ directory: URL) -> Bool {
        #if os(Windows)
        // A fresh folder (never one that already exists) that only the current user may open from its first moment.
        return createLockedDirectory(directory)
        #else
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return false }
        return true
        #endif
    }

    #if os(Windows)
    /// Creates `directory` (failing if it exists) with exactly one access entry: full control for the current user,
    /// inherited by what is created inside, with inheritance from the parent blocked (a protected DACL). The security
    /// descriptor is passed to CreateDirectoryW itself, so the folder never exists with the default, inherited list
    /// (no create-then-restrict window in a shared temporary folder).
    ///
    /// The user is the SID of this process's token, not `%USERDOMAIN%\%USERNAME%`: those variables can name another
    /// account (on GitHub's Windows runners USERNAME is SYSTEM while the process runs as runneradmin). The list is built
    /// through the Win32 API rather than icacls, because `icacls /inheritance:r /grant:r` left explicit full-control
    /// entries for SYSTEM and Administrators on the runner.
    static func createLockedDirectory(_ directory: URL) -> Bool {
        let path = directory.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? directory.path
        return withCurrentUserSID { sid -> Bool? in
            var access = EXPLICIT_ACCESS_W()
            access.grfAccessPermissions = DWORD(0x001F_01FF)   // FILE_ALL_ACCESS
            access.grfAccessMode = SET_ACCESS
            access.grfInheritance = DWORD(0x3)                  // SUB_CONTAINERS_AND_OBJECTS_INHERIT
            access.Trustee.TrusteeForm = TRUSTEE_IS_SID
            access.Trustee.TrusteeType = TRUSTEE_IS_USER
            access.Trustee.ptstrName = sid.assumingMemoryBound(to: WCHAR.self)
            var acl: PACL? = nil
            guard SetEntriesInAclW(1, &access, nil, &acl) == 0, let acl else { return false }
            defer { _ = LocalFree(UnsafeMutableRawPointer(acl)) }
            var descriptor = SECURITY_DESCRIPTOR()
            return withUnsafeMutablePointer(to: &descriptor) { pointer -> Bool in
                let raw = UnsafeMutableRawPointer(pointer)
                // SECURITY_DESCRIPTOR_REVISION (1); SE_DACL_PROTECTED (0x1000) blocks inheritance from the parent.
                guard InitializeSecurityDescriptor(raw, DWORD(1)),
                      SetSecurityDescriptorDacl(raw, true, acl, false),
                      SetSecurityDescriptorControl(raw, SECURITY_DESCRIPTOR_CONTROL(0x1000),
                                                   SECURITY_DESCRIPTOR_CONTROL(0x1000)) else { return false }
                var attributes = SECURITY_ATTRIBUTES()
                attributes.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
                attributes.lpSecurityDescriptor = raw
                attributes.bInheritHandle = false
                return path.withCString(encodedAs: UTF16.self) { CreateDirectoryW($0, &attributes) }
            }
        } ?? false
    }

    /// Calls `body` with the SID of the user this process runs as, from its access token.
    private static func withCurrentUserSID<T>(_ body: (UnsafeMutableRawPointer) -> T?) -> T? {
        var token: HANDLE? = nil
        guard OpenProcessToken(GetCurrentProcess(), DWORD(0x0008) /* TOKEN_QUERY */, &token), let token else { return nil }
        defer { CloseHandle(token) }
        var size: DWORD = 0
        _ = GetTokenInformation(token, TokenUser, nil, 0, &size)
        guard size > 0 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<TOKEN_USER>.alignment)
        defer { buffer.deallocate() }
        guard GetTokenInformation(token, TokenUser, buffer, size, &size),
              let sid = buffer.assumingMemoryBound(to: TOKEN_USER.self).pointee.User.Sid else { return nil }
        return body(sid)
    }

    /// The string SID (`S-1-5-21-…`) of the user this process runs as.
    static func currentUserSID() -> String? {
        withCurrentUserSID { sid -> String? in
            var text: LPWSTR? = nil
            guard ConvertSidToStringSidW(sid, &text), let text else { return nil }
            defer { _ = LocalFree(UnsafeMutableRawPointer(text)) }
            return String(decodingCString: text, as: UTF16.self)
        }
    }
    #endif

    private func serve(_ client: ApprovalConnection) {
        nonisolated(unsafe) let client = client
        DispatchQueue.global().async { [handler, workingDirectory] in
            guard let line = client.readLine(),
                  let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                client.close(); return
            }
            let tool = request["tool_name"] as? String ?? "tool"
            let input = request["input"] as? [String: Any] ?? [:]
            let detail = Self.describe(tool: tool, input: input)
            let rule = ApprovalRule.make(tool: tool, input: input, workingDirectory: workingDirectory)
            Task {
                let allowed = await handler(tool, detail, rule)
                let response: [String: Any] = allowed
                    ? ["behavior": "allow", "updatedInput": input]
                    : ["behavior": "deny", "message": "Denied by the operator in Tristan."]
                if let out = try? JSONSerialization.data(withJSONObject: response), let text = String(data: out, encoding: .utf8) {
                    client.writeLine(text)
                }
                client.close()
            }
        }
    }

    private static func describe(tool: String, input: [String: Any]) -> String {
        if let command = input["command"] as? String { return command }
        if let path = input["file_path"] as? String { return path }
        if let url = input["url"] as? String { return url }
        if let data = try? JSONSerialization.data(withJSONObject: input), let text = String(data: data, encoding: .utf8) {
            return String(text.prefix(300))
        }
        return tool
    }
}

/// `Tristan --mcp-permission <endpoint>`: a minimal MCP stdio server exposing one tool, `approve`,
/// which Claude Code calls (via --permission-prompt-tool) before each action that needs permission.
/// For a loopback endpoint both tokens come from the environment (`TRISTAN_APPROVAL_TOKEN`, the shim's own, and
/// `TRISTAN_APPROVAL_SERVER_TOKEN`, the host's), never the command line.
package enum PermissionShim {
    package static func run(endpoint: String, token: String?, serverToken: String?) -> Never {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = message["id"]
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]

            func reply(_ result: [String: Any]) {
                guard let id else { return }
                send(["jsonrpc": "2.0", "id": id, "result": result])
            }

            switch method {
            case "initialize":
                reply(["protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05",
                       "capabilities": ["tools": [String: Any]()],
                       "serverInfo": ["name": "tristan", "version": "0.1"]])
            case "tools/list":
                reply(["tools": [[
                    "name": "approve",
                    "description": "Ask the Tristan operator to approve a tool call.",
                    "inputSchema": [
                        "type": "object",
                        "properties": ["tool_name": ["type": "string"], "input": ["type": "object"], "tool_use_id": ["type": "string"]],
                        "required": ["tool_name", "input"],
                    ],
                ]]])
            case "tools/call":
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                reply(["content": [["type": "text", "text": decide(arguments, endpoint: endpoint, token: token, serverToken: serverToken)]]])
            case "ping":
                reply([:])
            default:
                if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]) }
            }
        }
        exit(0)
    }

    /// Sends one request to the host and returns its decision line; a deny when the host cannot be reached, does not
    /// prove itself (loopback), or does not answer.
    static func decide(_ arguments: [String: Any], endpoint: String, token: String?, serverToken: String?,
                       handshakeTimeout: TimeInterval = ApprovalTransport.handshakeTimeout) -> String {
        let deny = #"{"behavior":"deny","message":"Tristan is not reachable."}"#
        guard let data = try? JSONSerialization.data(withJSONObject: arguments),
              let text = String(data: data, encoding: .utf8),
              let connection = ApprovalTransport.connect(endpoint: endpoint, token: token, serverToken: serverToken,
                                                         handshakeTimeout: handshakeTimeout) else { return deny }
        defer { connection.close() }
        connection.writeLine(text)
        return connection.readLine() ?? deny
    }

    private static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
