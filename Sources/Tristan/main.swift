import AppKit

let app = NSApplication.shared

if let flag = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let path = CommandLine.arguments.indices.contains(flag + 1) ? CommandLine.arguments[flag + 1] : "docs/screenshots"
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
