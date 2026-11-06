import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

final class HUDWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// A borderless window may cover the whole screen, including the menu bar area, in full-screen mode.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `Tristan --demo [ask|auto|yolo] [--kids] [--manual]` (used by scripts/record-demo.sh): the DEMO provider in the given mode (ASK by default) with kids mode off, nothing saved
    /// as open tabs or history, and a separate Keychain slot for the parent PIN so a demo PIN never replaces a real one.
    private let demo = CommandLine.arguments.contains("--demo")
    private var demoRestore: (() -> Void)?
    private var demoSignal: DispatchSourceSignal?
    private var demoStart: DispatchSourceSignal?
    private lazy var session: Session = demo ? Session(history: nil) : Session()
    private var hud: HUDWindow!
    private var notch: NotchController!
    private var statusItem: NSStatusItem!
    private var openItem: NSMenuItem!
    private var hotKey: GlobalHotKey?
    private var talkKey: GlobalHotKey?
    private var fullScreen: FullScreenController!
    private var fullScreenItem: NSMenuItem!
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if demo {
            ParentPIN.inMemory = true
            ParentPIN.account = "kids.pin.demo"
            NoKeychain.enabled = true
            // Changing the mode saves it, so put the real settings back when the demo ends (also on SIGTERM from the script).
            let defaults = UserDefaults.standard
            let keys = ["approvalMode", "kidsMode", "wakeOn", "theme", "orbEffects", "orbFill", "parentAuth"]
            let saved = keys.map { ($0, defaults.object(forKey: $0)) }
            let restore = {
                for (key, value) in saved {
                    if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
                }
            }
            demoRestore = restore
            signal(SIGTERM, SIG_IGN)
            let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            term.setEventHandler { restore(); exit(0) }
            term.resume()
            demoSignal = term
            let word = CommandLine.arguments.drop { $0 != "--demo" }.dropFirst().first?.uppercased() ?? "ASK"
            session.provider = .demo
            session.approvalMode = ApprovalMode(rawValue: word) ?? .ask
            session.kidsMode = false
            session.wakeOn = false
        }
        hud = HUDWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
                        styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.isMovableByWindowBackground = true
        hud.isReleasedWhenClosed = false
        hud.contentView = NSHostingView(rootView: HUDView().environmentObject(session))
        // Open on the primary display (the one with the menu bar), centered there.
        let primary = NotchGeometry.primaryScreen().visibleFrame
        hud.setFrameOrigin(NSPoint(x: primary.midX - hud.frame.width / 2, y: primary.midY - hud.frame.height / 2))
        fullScreen = FullScreenController(window: hud)

        notch = NotchController(session: session) { [weak self] in self?.showHUD() }
        Notifier.shared.onOpen = { [weak self] in self?.showHUD() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.circle", accessibilityDescription: "Tristan")
        let menu = NSMenu()
        openItem = menu.addItem(withTitle: "", action: #selector(toggleHUD), keyEquivalent: "")
        openItem.target = self
        fullScreenItem = menu.addItem(withTitle: "Enter Full Screen  (⌃⌘F)", action: #selector(toggleFullScreen), keyEquivalent: "")
        fullScreenItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tristan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        // Re-register the global shortcuts whenever the preset changes (and once at launch).
        Publishers.CombineLatest(session.$hotkey, session.$recordingShortcut)
            .sink { [weak self] shortcut, recording in self?.registerHotKeys(shortcut, paused: recording) }
            .store(in: &bag)
        // "Match system" follows light and dark mode.
        NSApp.publisher(for: \.effectiveAppearance)
            .sink { [weak self] _ in self?.session.applyTheme() }
            .store(in: &bag)
        session.$fullScreen
            .removeDuplicates()
            .sink { [weak self] on in self?.applyFullScreen(on) }
            .store(in: &bag)
        showHUD()
        session.startNetworkMonitor()
        session.greet()
        if demo {
            // The recording script crops the video to this rectangle (screen points, origin at the top left).
            let screen = NotchGeometry.primaryScreen().frame
            print("DEMO_WINDOW \(Int(hud.frame.minX - screen.minX)) \(Int(screen.maxY - hud.frame.maxY)) \(Int(hud.frame.width)) \(Int(hud.frame.height)) \(Int(screen.width)) \(Int(screen.height))")
            fflush(stdout)
            if !CommandLine.arguments.contains("--manual") {
                let kids = CommandLine.arguments.contains("--kids")
                let start: @MainActor () -> Void = { [session] in
                    Task { @MainActor in if kids { await DemoAutopilot.runKids(on: session) } else { await DemoAutopilot.run(on: session) } }
                }
                if CommandLine.arguments.contains("--wait-start") {
                    // The recording script sends SIGUSR1 once the screen recorder is running, so the video starts at the beginning.
                    signal(SIGUSR1, SIG_IGN)
                    let go = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
                    go.setEventHandler { start() }
                    go.resume()
                    demoStart = go
                } else {
                    start()
                }
            }
        }
    }

    @objc private func toggleFullScreen() {
        session.fullScreen.toggle()
        if session.fullScreen { showHUD() }
    }

    private func applyFullScreen(_ on: Bool) {
        if on { session.fullScreenTopInset = fullScreen.topInset }
        fullScreen.set(on)
        notch.setHidden(on)         // the HUD shows everything, and the notch pill would sit on top of it
        fullScreenItem.title = on ? "Exit Full Screen  (⌃⌘F)" : "Enter Full Screen  (⌃⌘F)"
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.music.restoreVolumeNow()
        demoRestore?()
    }

    private func registerHotKeys(_ shortcut: Shortcut, paused: Bool) {
        hotKey?.unregister()
        talkKey?.unregister()
        hotKey = nil
        talkKey = nil
        openItem?.title = "Open Tristan  (\(shortcut.display), hold \(shortcut.talk.display) to talk)"
        guard !paused else { return }   // pressing the old shortcut must not fire while a new one is being recorded
        let show = GlobalHotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in self?.toggleHUD() }
        // Hold the same combination plus Shift to talk, release to send.
        let talk = GlobalHotKey(keyCode: shortcut.keyCode, modifiers: shortcut.talk.modifiers,
                                onRelease: { [weak self] in self?.session.stopListening() },
                                handler: { [weak self] in self?.session.startListening() })
        hotKey = show
        talkKey = talk
        session.shortcutProblem = show.registered && talk.registered ? nil : "Another app or macOS already uses \(shortcut.display). Pick a different one."
    }

    @objc private func toggleHUD() {
        if hud.isVisible && hud.isKeyWindow {
            if session.fullScreen { session.fullScreen = false }    // never leave the Dock and menu bar hidden
            hud.orderOut(nil)
        } else {
            showHUD()
        }
    }

    private func showHUD() {
        NSApp.activate(ignoringOtherApps: true)
        hud.makeKeyAndOrderFront(nil)
    }
}
