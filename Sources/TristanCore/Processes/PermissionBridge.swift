import Foundation
import Darwin

/// Tiny POSIX helpers for newline-delimited JSON over a Unix domain socket.
package enum UnixSocket {
    private static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) }
        }
        return addr
    }

    static func listen(at path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { close(fd); return nil }
        return fd
    }

    static func connect(to path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(fd); return nil }
        return fd
    }

    static func readLine(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { break }
            if byte == 10 { break }
            bytes.append(byte)
        }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    static func writeLine(_ fd: Int32, _ text: String) {
        let data = Array((text + "\n").utf8)
        var offset = 0
        while offset < data.count {
            let n = data[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            offset += n
        }
    }
}

/// Runs inside the app. Receives permission requests from the MCP shim and asks the operator.
package final class PermissionServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ tool: String, _ detail: String, _ rule: ApprovalRule?) async -> Bool

    let directory: URL
    var socketPath: String { directory.appendingPathComponent("s").path }
    private var fd: Int32 = -1
    private let handler: Handler
    private let workingDirectory: URL

    init(workingDirectory: URL, handler: @escaping Handler) {
        self.workingDirectory = workingDirectory
        let short = UUID().uuidString.prefix(8)
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tristan-\(short)")
        self.handler = handler
    }

    func start() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return false }
        guard let listener = UnixSocket.listen(at: socketPath) else { return false }
        fd = listener
        DispatchQueue.global().async { [weak self] in
            while let self, self.fd >= 0 {
                let client = accept(self.fd, nil, nil)
                if client < 0 { break }
                self.serve(client)
            }
        }
        return true
    }

    func stop() {
        if fd >= 0 { close(fd); fd = -1 }
        try? FileManager.default.removeItem(at: directory)
    }

    private func serve(_ client: Int32) {
        DispatchQueue.global().async { [handler, workingDirectory] in
            guard let line = UnixSocket.readLine(client),
                  let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                close(client); return
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
                    UnixSocket.writeLine(client, text)
                }
                close(client)
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

/// `Tristan --mcp-permission <socket>`: a minimal MCP stdio server exposing one tool, `approve`,
/// which Claude Code calls (via --permission-prompt-tool) before each action that needs permission.
package enum PermissionShim {
    package static func run(socketPath: String) -> Never {
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
                reply(["content": [["type": "text", "text": decide(arguments, socketPath: socketPath)]]])
            case "ping":
                reply([:])
            default:
                if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]) }
            }
        }
        exit(0)
    }

    private static func decide(_ arguments: [String: Any], socketPath: String) -> String {
        let deny = #"{"behavior":"deny","message":"Tristan is not reachable."}"#
        guard let fd = UnixSocket.connect(to: socketPath),
              let data = try? JSONSerialization.data(withJSONObject: arguments),
              let text = String(data: data, encoding: .utf8) else { return deny }
        defer { close(fd) }
        UnixSocket.writeLine(fd, text)
        return UnixSocket.readLine(fd) ?? deny
    }

    private static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
