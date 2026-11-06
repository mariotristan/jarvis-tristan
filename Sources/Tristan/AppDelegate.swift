import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

final class HUDWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let session = Session()
    private var hud: HUDWindow!
    private var notch: NotchController!
    private var statusItem: NSStatusItem!
    private var openItem: NSMenuItem!
    private var hotKey: GlobalHotKey?
    private var talkKey: GlobalHotKey?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        hud = HUDWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
                        styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.isMovableByWindowBackground = true
        hud.isReleasedWhenClosed = false
        hud.contentView = NSHostingView(rootView: HUDView().environmentObject(session))
        hud.center()

        notch = NotchController(session: session) { [weak self] in self?.showHUD() }
        Notifier.shared.onOpen = { [weak self] in self?.showHUD() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.circle", accessibilityDescription: "Tristan")
        let menu = NSMenu()
        openItem = menu.addItem(withTitle: "", action: #selector(toggleHUD), keyEquivalent: "")
        openItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tristan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        // Re-register the global shortcuts whenever the preset changes (and once at launch).
        Publishers.CombineLatest(session.$hotkey, session.$recordingShortcut)
            .sink { [weak self] shortcut, recording in self?.registerHotKeys(shortcut, paused: recording) }
            .store(in: &bag)
        showHUD()
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.music.restoreVolumeNow()
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
        if hud.isVisible && hud.isKeyWindow { hud.orderOut(nil) } else { showHUD() }
    }

    private func showHUD() {
        NSApp.activate(ignoringOtherApps: true)
        hud.makeKeyAndOrderFront(nil)
    }
}
