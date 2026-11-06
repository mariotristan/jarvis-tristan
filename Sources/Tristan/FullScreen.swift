import AppKit

/// Full-screen ("immersive") mode for the borderless HUD window. macOS native full screen needs a titled window, so
/// this fills the screen itself and hides the Dock and menu bar while Tristan is in front, then puts everything back.
@MainActor
final class FullScreenController {
    private weak var window: NSWindow?
    private var savedFrame: NSRect?
    private let setPresentation: (NSApplication.PresentationOptions) -> Void
    private(set) var isFullScreen = false

    init(window: NSWindow, setPresentation: @escaping (NSApplication.PresentationOptions) -> Void = { NSApp.presentationOptions = $0 }) {
        self.window = window
        self.setPresentation = setPresentation
    }

    private var screen: NSScreen? { window?.screen ?? NSScreen.main }

    /// Height of the camera notch on this screen, so content can start below it. Zero on Macs without one.
    var topInset: CGFloat { screen?.safeAreaInsets.top ?? 0 }

    func set(_ on: Bool) {
        guard let window, on != isFullScreen else { return }
        if on {
            guard let target = screen?.frame else { return }
            savedFrame = window.frame
            setPresentation([.autoHideDock, .autoHideMenuBar])
            window.setFrame(target, display: true, animate: true)
            isFullScreen = true
        } else {
            setPresentation([])
            if let saved = savedFrame { window.setFrame(saved, display: true, animate: true) }
            savedFrame = nil
            isFullScreen = false
        }
    }
}
