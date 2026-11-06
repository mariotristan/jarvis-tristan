import SwiftUI
import AppKit

/// `Tristan --snapshot <dir>` renders the real views with sample data to PNGs (used for README screenshots).
@MainActor
enum Snapshot {
    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let music = SpotifyController(runner: StaticRunner(), isRunning: { true })
        let working = Session(history: nil, music: music)
        working.musicOn = true
        working.provider = .claude
        working.workingDirectory = URL(fileURLWithPath: "/Users/you/code/my-api")
        working.phase = .working
        working.status = "WRITING CODE"
        working.log = [
            entry("Task: add login to the API", .info),
            entry("Scanning my-api", .step),
            entry("Authorization granted", .ok),
            entry("Read routes.ts", .step),
            entry("Write auth.ts", .step),
            entry("Bash: npm test", .step),
        ]
        let routes = CodeFence.block(path: "Sources/routes.ts", content: """
        router.post("/login", async (req, res) => {
          const user = await verify(req.body);
          res.json({ token: login(user) });
        });
        """)
        working.code = """
        ## Adding login to the API

        I read `routes.ts` first, then made two changes:

        - created **auth.ts** with a `login` function that signs a JWT
        - wired a `POST /login` route

        | File | Change | Tests |
        |:-----|:------:|------:|
        | `auth.ts` | new | 12 pass |
        | `routes.ts` | edited | 12 pass |

        > Next I will run the full suite.

        """ + CodeFence.block(path: "Sources/auth.ts", content: """
        export function login(user: User): string {
          const token = sign({ sub: user.id, role: user.role });
          audit("login", user.id);
          return token;
        }
        """) + routes
        save(HUDView().environmentObject(working), width: 1000, height: 660, name: "hud-working.png")

        let asking = Session(history: nil)
        asking.provider = .claude
        asking.workingDirectory = URL(fileURLWithPath: "/Users/you/code/my-api")
        asking.phase = .awaitingApproval
        asking.status = "AWAITING AUTHORIZATION"
        asking.log = [entry("Task: add login to the API", .info), entry("Allow Bash?", .warn)]
        asking.pending = ApprovalRequest(summary: "Allow Bash?", detail: "npm test",
                                         rule: ApprovalRule(key: "Bash:npm", label: "Bash: npm …"))
        save(HUDView().environmentObject(asking), width: 1000, height: 660, name: "hud-approval.png")

        let wide = Session(history: nil)
        wide.provider = .claude
        wide.workingDirectory = URL(fileURLWithPath: "/Users/you/code/my-api")
        wide.phase = .working
        wide.status = "WRITING CODE"
        wide.log = working.log
        wide.code = working.code
        wide.musicOn = false
        wide.fullScreen = true
        wide.fullScreenTopInset = 32
        save(HUDView().environmentObject(wide), width: 1728, height: 1117, name: "hud-fullscreen.png")

        // Three sessions side by side: one working, one waiting for approval in the background, one finished.
        let many = Session(history: nil)
        many.musicOn = false
        many.soundsOn = false; many.voiceOn = false; many.notificationsOn = false
        let one = many.active
        one.provider = .claude
        one.workingDirectory = URL(fileURLWithPath: "/Users/you/code/my-api")
        one.phase = .working; one.status = "WRITING CODE"
        one.log = working.log; one.code = working.code
        let two = many.newSession(provider: .copilot, folder: URL(fileURLWithPath: "/Users/you/code/scripts"), select: false)!
        two.phase = .awaitingApproval; two.status = "AWAITING AUTHORIZATION"
        two.pending = ApprovalRequest(summary: "Run Copilot CLI with its tools allowed?", detail: "It will edit files in /Users/you/code/scripts")
        two.log = [LogEntry(text: "Task: update the deploy scripts", kind: .info)]
        let three = many.newSession(provider: .bedrock, folder: URL(fileURLWithPath: "/Users/you/code/docs"), select: false)!
        three.phase = .done; three.status = "MISSION COMPLETE"
        three.log = [LogEntry(text: "Task: summarise the changelog", kind: .info), LogEntry(text: "Done.", kind: .ok)]
        many.select(one.id)
        save(HUDView().environmentObject(many), width: 1000, height: 660, name: "hud-sessions.png")

        let settings = Session(history: nil)
        settings.provider = .claude
        settings.workingDirectory = URL(fileURLWithPath: "/Users/you/code/my-api")
        settings.approvalMode = .auto
        settings.showSettings = true
        settings.log = [entry("Task: add login to the API", .info)]
        save(HUDView().environmentObject(settings), width: 1000, height: 660, name: "hud-settings.png")
        UserDefaults.standard.removeObject(forKey: "approvalMode")

        let past = Session(history: nil)
        past.provider = .azure
        past.workingDirectory = URL(fileURLWithPath: "/Users/you/code/my-api")
        past.records = [
            MissionRecord(date: Date().addingTimeInterval(-600), task: "add login to the API", provider: "CLAUDE", mode: "ASK",
                          status: "done", summary: "Added auth.ts and a /login route; tests pass.", folder: "/Users/you/code/my-api"),
            MissionRecord(date: Date().addingTimeInterval(-3_600), task: "refactor the config loader", provider: "BEDROCK", mode: "AUTO",
                          status: "done", summary: "Split loader into parse and validate steps.", folder: "/Users/you/code/my-api"),
            MissionRecord(date: Date().addingTimeInterval(-90_000), task: "upgrade dependencies", provider: "COPILOT", mode: "ASK",
                          status: "failed", summary: "Denied by operator", folder: "/Users/you/code/my-api"),
            MissionRecord(date: Date().addingTimeInterval(-180_000), task: "write a README for the scripts folder", provider: "AZURE", mode: "YOLO",
                          status: "aborted", summary: "Aborted by operator", folder: "/Users/you/code/scripts"),
        ]
        past.showHistory = true
        save(HUDView().environmentObject(past), width: 1000, height: 660, name: "hud-history.png")

        let geometry = NotchGeometry.current()
        let state = NotchState()
        let notchSession = Session(history: nil)
        notchSession.phase = .awaitingApproval
        notchSession.status = "AWAITING AUTHORIZATION"
        notchSession.pending = ApprovalRequest(summary: "Allow Bash?  npm test", detail: "",
                                               rule: ApprovalRule(key: "Bash:npm", label: "Bash: npm …"))
        state.expanded = true
        state.refresh(from: notchSession)
        let notchView = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.32), Color(red: 0.05, green: 0.07, blue: 0.14)],
                           startPoint: .top, endPoint: .bottom)
            NotchView(state: state, geometry: geometry, openHUD: {})
                .environmentObject(notchSession)
                .frame(width: max(geometry.width + 300, 420), height: geometry.height + 110)
        }
        save(notchView, width: 640, height: 220, name: "notch-approval.png")
    }

    private static func entry(_ text: String, _ kind: LogEntry.Kind) -> LogEntry { LogEntry(text: text, kind: kind) }

    /// Renders the app icon (a dark squircle with the arc reactor) at 1024 points, for `scripts/bundle.sh` to turn into an .icns.
    static func renderIcon(to file: URL, fullBleed: Bool = false) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        write(AppIconView(fullBleed: fullBleed), width: 1024, height: 1024, to: file)
    }

    private static func save<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String) {
        write(view, width: width, height: height, to: snapshotDirectory.appendingPathComponent(name))
    }

    private static func write<V: View>(_ view: V, width: CGFloat, height: CGFloat, to url: URL) {
        // Render through a real (offscreen) window: ImageRenderer skips ScrollViews and TextFields.
        let size = NSSize(width: width, height: height)
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("render failed: \(url.lastPathComponent)"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { print("render failed: \(url.lastPathComponent)"); return }
        window.orderOut(nil)
        try? png.write(to: url)
        print("wrote \(url.path)")
    }

    private static var snapshotDirectory = URL(fileURLWithPath: ".")
    static func setDirectory(_ url: URL) { snapshotDirectory = url }
}

struct AppIconView: View {
    /// iOS wants a square that fills the whole canvas (the system rounds it); the Mac icon is a drawn squircle.
    var fullBleed = false

    var body: some View {
        ZStack {
            if fullBleed {
                Rectangle()
                    .fill(RadialGradient(colors: [Color(red: 0.03, green: 0.20, blue: 0.27), Theme.deep],
                                         center: .center, startRadius: 0, endRadius: 760))
                    .frame(width: 1024, height: 1024)
            } else {
                RoundedRectangle(cornerRadius: 190, style: .continuous)
                    .fill(RadialGradient(colors: [Color(red: 0.03, green: 0.20, blue: 0.27), Theme.deep],
                                         center: .center, startRadius: 0, endRadius: 560))
                    .frame(width: 824, height: 824)
                RoundedRectangle(cornerRadius: 190, style: .continuous)
                    .stroke(Theme.cyan.opacity(0.55), lineWidth: 8)
                    .frame(width: 824, height: 824)
            }
            ReactorView(active: true, tint: Theme.cyan, size: fullBleed ? 640 : 560)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// Pretends to be Spotify for screenshots.
private struct StaticRunner: ScriptRunner {
    func run(_ source: String) async throws -> String { "playing\tDeep Focus\tSpotify\t60" }
}
