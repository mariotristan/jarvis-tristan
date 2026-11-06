import SwiftUI
import AppKit

/// `Tristan --snapshot <dir>` renders the real views with sample data to PNGs (used for README screenshots).
@MainActor
enum Snapshot {
    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let working = Session()
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
        save(HUDView().environmentObject(working), width: 1000, height: 640, name: "hud-working.png")

        let asking = Session()
        asking.provider = .claude
        asking.workingDirectory = URL(fileURLWithPath: "/Users/you/code/my-api")
        asking.phase = .awaitingApproval
        asking.status = "AWAITING AUTHORIZATION"
        asking.log = [entry("Task: add login to the API", .info), entry("Let Claude Code edit files", .warn)]
        asking.pending = ApprovalRequest(summary: "Let Claude Code edit files", detail: "Working folder: /Users/you/code/my-api")
        save(HUDView().environmentObject(asking), width: 1000, height: 640, name: "hud-approval.png")

        let geometry = NotchGeometry.current()
        let state = NotchState()
        let notchSession = Session()
        notchSession.phase = .awaitingApproval
        notchSession.status = "AWAITING AUTHORIZATION"
        notchSession.pending = ApprovalRequest(summary: "Let Claude Code edit files", detail: "")
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

    private static func save<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String) {
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
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("snapshot failed: \(name)"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { print("snapshot failed: \(name)"); return }
        window.orderOut(nil)
        let url = snapshotDirectory.appendingPathComponent(name)
        try? png.write(to: url)
        print("wrote \(url.path)")
    }

    private static var snapshotDirectory = URL(fileURLWithPath: ".")
    static func setDirectory(_ url: URL) { snapshotDirectory = url }
}
