import AppKit
import TristanCore

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

// `Tristan --headless-sessions <dirA> "<taskA>" <dirB> "<taskB>" [claude|copilot] [ask|auto]`: two real sessions at the
// same time, each answering its own approvals. Prints a timeline and how many sessions were busy at once.
if let flag = args.firstIndex(of: "--headless-sessions"), args.indices.contains(flag + 4) {
    let folders = [URL(fileURLWithPath: args[flag + 1]), URL(fileURLWithPath: args[flag + 3])]
    let tasks = [args[flag + 2], args[flag + 4]]
    let kind: ProviderKind = args.indices.contains(flag + 5) && args[flag + 5] == "copilot" ? .copilot : .claude
    let mode: ApprovalMode = args.indices.contains(flag + 6) && args[flag + 6] == "auto" ? .auto : .ask
    Task { @MainActor in
        let hub = Session(history: nil)
        hub.soundsOn = false; hub.voiceOn = false; hub.notificationsOn = false
        hub.approvalMode = mode
        hub.allowRules = []
        let first = hub.active
        first.provider = kind; first.workingDirectory = folders[0]
        let second = hub.newSession(provider: kind, folder: folders[1], select: false)!
        let sessions = [first, second]
        let start = Date()
        func stamp() -> String { String(format: "%5.1fs", Date().timeIntervalSince(start)) }
        for (session, task) in zip(sessions, tasks) { session.submit(task) }
        var printed = [0, 0]
        var peak = 0
        var approvals = [0, 0]
        var finished: [Int: String] = [:]
        while finished.count < 2, Date().timeIntervalSince(start) < 240 {
            peak = max(peak, sessions.filter(\.busy).count)
            for (index, session) in sessions.enumerated() {
                if let request = session.pending {
                    print("\(stamp())  session \(index + 1) APPROVAL  \(request.summary) [\(request.detail.prefix(60))] -> allow")
                    approvals[index] += 1
                    session.resolve(true)
                }
                while printed[index] < session.log.count {
                    print("\(stamp())  session \(index + 1)  \(session.log[printed[index]].text.prefix(90))")
                    printed[index] += 1
                }
                if finished[index] == nil, session.phase == .done || session.phase == .failed {
                    finished[index] = "\(session.phase) at \(stamp())"
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("---")
        for index in 0..<2 { print("session \(index + 1): \(finished[index] ?? "TIMED OUT"), approvals answered: \(approvals[index]), folder: \(folders[index].lastPathComponent)") }
        print("most sessions busy at the same moment: \(peak)")
        exit(0)
    }
    dispatchMain()
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

// `Tristan --fullscreen-selftest`: opens a window, enters and leaves full screen, and prints what happened. A real
// check of the window and presentation behaviour (it briefly hides the Dock and menu bar).
if args.contains("--fullscreen-selftest") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = HUDWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        var applied: [NSApplication.PresentationOptions] = []
        let controller = FullScreenController(window: window) { options in applied.append(options); app.presentationOptions = options }
        let screen = window.screen ?? NSScreen.main!
        let windowed = window.frame
        controller.set(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let full = window.frame
        print("screen frame:     \(screen.frame)")
        print("windowed frame:   \(windowed)")
        print("full-screen frame: \(full)  covers screen: \(full == screen.frame)")
        print("presentation:     hideDock=\(app.presentationOptions.contains(.hideDock)) hideMenuBar=\(app.presentationOptions.contains(.hideMenuBar))")
        print("notch inset:      \(controller.topInset)")
        controller.set(false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        print("restored frame:   \(window.frame)  matches windowed: \(window.frame == windowed)")
        print("presentation after exit: \(app.presentationOptions.rawValue == 0 ? "normal" : "STILL CHANGED")")
        window.orderOut(nil)
    }
    exit(0)
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
