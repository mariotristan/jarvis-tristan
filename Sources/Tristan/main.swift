import AppKit

let args = CommandLine.arguments

// `Tristan --mcp-permission <socket>`: MCP stdio shim spawned by Claude Code (see PermissionBridge.swift).
if let flag = args.firstIndex(of: "--mcp-permission"), args.indices.contains(flag + 1) {
    PermissionShim.run(socketPath: args[flag + 1])
}

// `Tristan --headless <dir> "<task>" [allow|deny|auto|yolo]`: runs the Claude provider without UI, answering
// every approval automatically. Used to test the real approval path end to end.
if let flag = args.firstIndex(of: "--headless"), args.indices.contains(flag + 2) {
    let dir = URL(fileURLWithPath: args[flag + 1])
    let task = args[flag + 2]
    let choice = args.indices.contains(flag + 3) ? args[flag + 3] : "allow"
    let allow = choice != "deny"
    let mode: ApprovalMode = choice == "auto" ? .auto : choice == "yolo" ? .yolo : .ask
    Task {
        let stream = ClaudeCodeProvider(mode: mode).run(task: task, workingDirectory: dir) { request in
            print("APPROVAL  \(request.summary)  [\(request.detail)]  -> \(allow ? "allow" : "deny")")
            return allow
        }
        for await event in stream { print("EVENT     \(event)") }
        exit(0)
    }
    dispatchMain()
}

let app = NSApplication.shared

if let flag = args.firstIndex(of: "--snapshot") {
    let path = args.indices.contains(flag + 1) ? args[flag + 1] : "docs/screenshots"
    let dir = URL(fileURLWithPath: path)
    MainActor.assumeIsolated {
        Snapshot.setDirectory(dir)
        Snapshot.run(into: dir)
    }
    exit(0)
}

let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
