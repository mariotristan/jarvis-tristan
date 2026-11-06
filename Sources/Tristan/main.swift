import AppKit

let args = CommandLine.arguments

// `Tristan --mcp-permission <socket>`: MCP stdio shim spawned by Claude Code (see PermissionBridge.swift).
if let flag = args.firstIndex(of: "--mcp-permission"), args.indices.contains(flag + 1) {
    PermissionShim.run(socketPath: args[flag + 1])
}

// `Tristan --headless <dir> "<task>" [allow|deny|always|auto|yolo]`: drives a real Session (the same code the UI
// uses) without any window, answering approvals automatically. Used to test the approval path end to end.
if let flag = args.firstIndex(of: "--headless"), args.indices.contains(flag + 2) {
    let dir = URL(fileURLWithPath: args[flag + 1])
    let task = args[flag + 2]
    let choice = args.indices.contains(flag + 3) ? args[flag + 3] : "allow"
    let mode: ApprovalMode = choice == "auto" ? .auto : choice == "yolo" ? .yolo : .ask
    Task { @MainActor in
        let session = Session()
        session.provider = .claude
        session.approvalMode = mode
        session.workingDirectory = dir
        session.allowRules = []
        session.submit(task)
        var printed = 0
        while true {
            if let request = session.pending {
                print("APPROVAL  \(request.summary)  [\(request.detail)]  rule=\(request.rule?.label ?? "none")  -> \(choice)")
                session.resolve(choice != "deny", always: choice == "always")
            }
            while printed < session.log.count { print("LOG       \(session.log[printed].text)"); printed += 1 }
            if session.phase == .done || session.phase == .failed { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        while printed < session.log.count { print("LOG       \(session.log[printed].text)"); printed += 1 }
        print("FINAL     \(session.phase)  rules=\(session.allowRules.map(\.key))")
        session.allowRules = []
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
