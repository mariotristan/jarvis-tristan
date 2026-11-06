import AppKit

let args = CommandLine.arguments
nonisolated(unsafe) var demoKeepAlive: (Any, Any)?

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
        let session = Session(history: nil)
        session.provider = choice.hasPrefix("bedrock") ? .bedrock : .claude
        session.approvalMode = mode
        session.workingDirectory = dir
        session.allowRules = []
        session.soundsOn = false
        session.voiceOn = false
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

// `Tristan --sound-demo`: plays every sound cue and sample voice line once, so you can hear them.
if args.contains("--sound-demo") {
    Task { @MainActor in
        let fx = SoundFX()
        let order: [(String, Cue, String?)] = [
            ("listen start", .listenStart, nil), ("listen stop", .listenStop, nil),
            ("mission start", .missionStart, SoundFX.startLines[0]), ("approval needed", .approvalNeeded, SoundFX.approvalLines[0]),
            ("approved", .approved, nil), ("denied", .denied, nil),
            ("mission complete", .missionComplete, SoundFX.doneLines[0]), ("mission failed", .missionFailed, SoundFX.failLines[0]),
        ]
        for (name, cue, line) in order {
            print("▸ \(name)")
            fx.play(cue)
            try? await Task.sleep(for: .seconds(1.2))
            if let line { fx.say(line, interrupt: false); try? await Task.sleep(for: .seconds(2.2)) }
        }
        exit(0)
    }
    dispatchMain()
}

// `Tristan --make-icon <file.png>`: renders the app icon (used by scripts/bundle.sh).
if let flag = args.firstIndex(of: "--make-icon"), args.indices.contains(flag + 1) {
    MainActor.assumeIsolated { Snapshot.renderIcon(to: URL(fileURLWithPath: args[flag + 1]), fullBleed: args.contains("--full-bleed")) }
    exit(0)
}

// `Tristan --remote-demo`: serves a demo Session over the remote protocol, without any UI. For developing the iOS
// app in the simulator: it prints a pairing link for 127.0.0.1.
if args.contains("--remote-demo") {
    let demoServer: RemoteServer = MainActor.assumeIsolated {
        let session = Session(history: nil)
        session.soundsOn = false; session.voiceOn = false; session.notificationsOn = false
        session.provider = .demo
        session.approvalMode = .ask
        session.workingDirectory = FileManager.default.temporaryDirectory
        let server = RemoteServer(secret: PairingSecret.generate(), advertise: false, preferredPort: RemoteServer.defaultPort)
        server.attach(to: session)
        server.start()
        demoKeepAlive = (session, server)
        return server
    }
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
        MainActor.assumeIsolated {
            guard let port = demoServer.port else { return }
            timer.invalidate()
            let link = PairingLink(name: "Demo Mac", host: "127.0.0.1", port: port, secret: demoServer.secret)
            print("PAIR \(link.url.absoluteString)")
            fflush(stdout)
        }
    }
    RunLoop.main.run()
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
