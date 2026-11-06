import AppKit
import SwiftUI
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
    private var hotKey: GlobalHotKey!

    func applicationDidFinishLaunching(_ notification: Notification) {
        hud = HUDWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                        styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.isMovableByWindowBackground = true
        hud.isReleasedWhenClosed = false
        hud.contentView = NSHostingView(rootView: HUDView().environmentObject(session))
        hud.center()

        notch = NotchController(session: session) { [weak self] in self?.showHUD() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.circle", accessibilityDescription: "Tristan")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Tristan  (⌥Space)", action: #selector(toggleHUD), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tristan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        hotKey = GlobalHotKey(keyCode: kVK_Space, modifiers: optionKey) { [weak self] in self?.toggleHUD() }
        showHUD()
    }

    @objc private func toggleHUD() {
        if hud.isVisible && hud.isKeyWindow { hud.orderOut(nil) } else { showHUD() }
    }

    private func showHUD() {
        NSApp.activate(ignoringOtherApps: true)
        hud.makeKeyAndOrderFront(nil)
    }
}
