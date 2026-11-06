import AppKit

/// Full-screen ("immersive") mode for the borderless HUD window. macOS native full screen needs a titled window, so
/// this fills the screen itself and hides the Dock and menu bar while Tristan is in front, then puts everything back.
@MainActor
final class FullScreenController {
    private weak var window: NSWindow?
    private var savedFrame: NSRect?
    private var savedLevel = NSWindow.Level.normal
    private var savedShadow = true
    private var observer: NSObjectProtocol?
    private let setPresentation: (NSApplication.PresentationOptions) -> Void
    private(set) var isFullScreen = false

    init(window: NSWindow, setPresentation: @escaping (NSApplication.PresentationOptions) -> Void = { NSApp.presentationOptions = $0 }) {
        self.window = window
        self.setPresentation = setPresentation
    }

    /// The screen the window is on (it opens on the primary display).
    private var screen: NSScreen? { window?.screen ?? NSScreen.screens.first }

    /// Height of the camera notch on this screen, so content can start below it. Zero on Macs without one.
    var topInset: CGFloat { screen?.safeAreaInsets.top ?? 0 }

    func set(_ on: Bool) {
        guard let window, on != isFullScreen else { return }
        if on {
            guard let target = screen?.frame else { return }
            savedFrame = window.frame
            savedLevel = window.level
            savedShadow = window.hasShadow
            // Hidden outright, not just auto-hidden, so the Dock and menu bar never slide in over the edges.
            setPresentation([.hideDock, .hideMenuBar])
            window.level = .mainMenu + 1
            window.hasShadow = false
            window.setFrame(target, display: true, animate: true)
            isFullScreen = true
            // A display was added, removed or rearranged while full screen: fill the screen we are on now.
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refit() }
            }
        } else {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            setPresentation([])
            window.level = savedLevel
            window.hasShadow = savedShadow
            if let saved = savedFrame { window.setFrame(saved, display: true, animate: true) }
            savedFrame = nil
            isFullScreen = false
        }
    }

    private func refit() {
        guard isFullScreen, let window, let target = screen?.frame, window.frame != target else { return }
        window.setFrame(target, display: true)
    }
}
