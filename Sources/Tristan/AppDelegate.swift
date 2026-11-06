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
        session.$hotkey
            .sink { [weak self] preset in self?.registerHotKeys(preset) }
            .store(in: &bag)
        showHUD()
    }

    private func registerHotKeys(_ preset: HotkeyPreset) {
        hotKey?.unregister()
        talkKey?.unregister()
        hotKey = GlobalHotKey(keyCode: kVK_Space, modifiers: preset.modifiers) { [weak self] in self?.toggleHUD() }
        // Hold the same combination plus Shift to talk, release to send.
        talkKey = GlobalHotKey(keyCode: kVK_Space, modifiers: preset.modifiers | shiftKey,
                               onRelease: { [weak self] in self?.session.stopListening() },
                               handler: { [weak self] in self?.session.startListening() })
        openItem?.title = "Open Tristan  (\(preset.rawValue), hold \(preset.talkLabel) to talk)"
    }

    @objc private func toggleHUD() {
        if hud.isVisible && hud.isKeyWindow { hud.orderOut(nil) } else { showHUD() }
    }

    private func showHUD() {
        NSApp.activate(ignoringOtherApps: true)
        hud.makeKeyAndOrderFront(nil)
    }
}
