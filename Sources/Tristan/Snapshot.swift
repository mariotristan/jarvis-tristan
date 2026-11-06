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
        working.code = """
        // Sources/auth.ts
        import { sign } from "./jwt";

        export function login(user: User): string {
          const token = sign({ sub: user.id, role: user.role });
          audit("login", user.id);
          return token;
        }

        // Sources/routes.ts
        router.post("/login", async (req, res) => {
          const user = await verify(req.body);
          res.json({ token: login(user) });
        });
        """
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
        let notchView = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.32), Color(red: 0.05, green: 0.07, blue: 0.14)],
                           startPoint: .top, endPoint: .bottom)
            NotchView(state: state, geometry: geometry, expanded: true, openHUD: {})
                .environmentObject(notchSession)
                .frame(width: max(geometry.width + 300, 420), height: geometry.height + 110)
        }
        save(notchView, width: 640, height: 220, name: "notch-approval.png")
    }

    private static func entry(_ text: String, _ kind: LogEntry.Kind) -> LogEntry { LogEntry(text: text, kind: kind) }

    /// Renders the app icon (a dark squircle with the arc reactor) at 1024 points, for `scripts/bundle.sh` to turn into an .icns.
    static func renderIcon(to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        write(AppIconView(), width: 1024, height: 1024, to: file)
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
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 190, style: .continuous)
                .fill(RadialGradient(colors: [Color(red: 0.03, green: 0.20, blue: 0.27), Theme.deep],
                                     center: .center, startRadius: 0, endRadius: 560))
                .frame(width: 824, height: 824)
            RoundedRectangle(cornerRadius: 190, style: .continuous)
                .stroke(Theme.cyan.opacity(0.55), lineWidth: 8)
                .frame(width: 824, height: 824)
            ReactorView(active: true, tint: Theme.cyan, size: 560)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// Pretends to be Spotify for screenshots.
private struct StaticRunner: ScriptRunner {
    func run(_ source: String) async throws -> String { "playing\tDeep Focus\tSpotify\t60" }
}
