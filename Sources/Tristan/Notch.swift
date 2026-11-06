import SwiftUI
import AppKit
import Combine

/// Geometry of the camera notch, with a floating-pill fallback for Macs without one.
struct NotchGeometry {
    let screen: NSScreen
    let width: CGFloat
    let height: CGFloat
    let hasNotch: Bool

    /// The primary display (the one with the menu bar), whether or not it has a notch.
    static func primaryScreen() -> NSScreen { NSScreen.screens.first ?? NSScreen.main ?? NSScreen.screens[0] }

    static func current() -> NotchGeometry {
        let screen = primaryScreen()
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return NotchGeometry(screen: screen,
                                 width: screen.frame.width - left.width - right.width,
                                 height: screen.safeAreaInsets.top, hasNotch: true)
        }
        return NotchGeometry(screen: screen, width: 180, height: 28, hasNotch: false)
    }
}

/// The few things the notch shows. The view reads only this, so a stream of log lines in the session does not
/// redraw the notch unless something visible changed.
struct NotchSnapshot: Equatable {
    var phase: Phase = .idle
    var listening = false
    var title = ""
    var detail = ""
    var hasPending = false
    var canAlwaysAllow = false
}

@MainActor
final class NotchState: ObservableObject {
    @Published var hovering = false
    @Published var peek = false
    @Published var expanded = false
    @Published private(set) var snapshot = NotchSnapshot()

    func refresh(from session: Session) {
        let focus = session.attention ?? session.active
        let title = session.sessions.count > 1 ? "\(session.label(for: focus).uppercased())  ·  \(focus.status)" : focus.status
        let detail = session.listening ? (session.draft.isEmpty ? "Listening…" : session.draft)
            : focus.pending?.summary ?? focus.log.last?.text ?? focus.welcome
        let next = NotchSnapshot(phase: session.overallPhase, listening: session.listening, title: title, detail: detail,
                                 hasPending: focus.pending != nil, canAlwaysAllow: focus.pending?.rule != nil)
        if next != snapshot { snapshot = next }
    }
}

struct NotchView: View {
    @EnvironmentObject var session: Session
    @ObservedObject var state: NotchState
    let geometry: NotchGeometry
    let openHUD: () -> Void

    private let wing: CGFloat = 56

    var body: some View {
        let snap = state.snapshot
        let tint = Theme.tint(for: snap.phase)
        let expanded = state.expanded
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ReactorView(active: snap.phase == .working || snap.listening, tint: tint, size: geometry.height - 8, minimumInterval: 1.0 / 24)
                    .frame(width: wing)
                Spacer().frame(width: geometry.width)
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .frame(width: wing)
            }
            .frame(height: geometry.height)

            if expanded {
                VStack(spacing: 8) {
                    Text(snap.title)
                        .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(2)
                        .foregroundStyle(tint)
                    Text(snap.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.cyan.opacity(0.85))
                        .lineLimit(2).multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        if snap.hasPending {
                            hudButton("DENY", tint: Theme.red) { session.resolveAttention(false) }
                            hudButton("APPROVE", tint: Theme.green) { session.resolveAttention(true) }
                            if snap.canAlwaysAllow {
                                hudButton("ALWAYS", tint: Theme.cyan) { session.resolveAttention(true, always: true) }
                            }
                        } else {
                            hudButton("OPEN HUD", tint: Theme.cyan, action: openHUD)
                            hudButton("QUIT", tint: Theme.red) { NSApp.terminate(nil) }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 14).padding(.top, 4)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22)
                .fill(.black)
                .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22)
                    .stroke(tint.opacity(expanded ? 0.6 : 0.25), lineWidth: 1))
        )
        .onHover { state.hovering = $0 }
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchController {
    private let panel: NotchPanel
    private var geometry = NotchGeometry.current()
    private let state = NotchState()
    private let session: Session
    private let openHUD: () -> Void
    private var bag = Set<AnyCancellable>()
    private var peekTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var hidden = false

    init(session: Session, openHUD: @escaping () -> Void) {
        self.session = session
        self.openHUD = openHUD
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        render()
        state.refresh(from: session)
        applyFrame()
        panel.orderFrontRegardless()

        // The view is built once; only the state changes. Replacing the view on every change is what made it blink.
        session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // objectWillChange fires before the change lands, so read on the next turn.
                Task { @MainActor in self.state.refresh(from: self.session) }
            }
            .store(in: &bag)

        Publishers.CombineLatest4(state.$hovering, session.$overallPhase, state.$peek, session.$listening)
            .receive(on: RunLoop.main)
            .sink { [weak self] hovering, phase, peek, listening in
                self?.setExpanded(hovering || phase == .awaitingApproval || peek || listening)
            }
            .store(in: &bag)

        // New colors: build the notch's view again (its background stays black, to blend with the notch).
        session.$themeID
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &bag)

        // Peek open for a few seconds when a mission ends.
        session.$overallPhase
            .removeDuplicates()
            .filter { $0 == .done || $0 == .failed }
            .sink { [weak self] _ in self?.flash() }
            .store(in: &bag)

        // A monitor was plugged in, unplugged or rearranged: stay on the primary one.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.geometry = NotchGeometry.current()
                self.render()
                self.applyFrame()
            }
            .store(in: &bag)
    }

    /// Hidden while the HUD is full screen.
    func setHidden(_ hidden: Bool) {
        self.hidden = hidden
        if hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    private func flash() {
        state.peek = true
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.state.peek = false }
        }
    }

    private func render() {
        let root = NotchView(state: state, geometry: geometry, openHUD: openHUD).environmentObject(session)
        panel.contentView = NSHostingView(rootView: root)
    }

    /// Opens at once (the window grows first, then the content fades in). Closing waits a moment so the pointer
    /// crossing the edge does not flicker it, and the window shrinks only after the content has gone.
    private func setExpanded(_ want: Bool) {
        collapseTask?.cancel()
        if want {
            guard !state.expanded else { return }
            applyFrame(expanded: true)
            withAnimation(.easeOut(duration: 0.14)) { state.expanded = true }
        } else {
            guard state.expanded else { return }
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled, let self else { return }
                withAnimation(.easeIn(duration: 0.12)) { self.state.expanded = false }
                try? await Task.sleep(for: .milliseconds(140))
                if !Task.isCancelled { self.applyFrame(expanded: false) }
            }
        }
    }

    private func applyFrame(expanded: Bool = false) {
        let size = expanded ? NSSize(width: max(geometry.width + 300, 420), height: geometry.height + 110)
                            : NSSize(width: geometry.width + 112, height: geometry.height)
        let frame = geometry.screen.frame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }
}
