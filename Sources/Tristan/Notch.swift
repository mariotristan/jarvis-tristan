import SwiftUI
import AppKit
import Combine

/// Geometry of the camera notch, with a floating-pill fallback for Macs without one.
struct NotchGeometry {
    let screen: NSScreen
    let width: CGFloat
    let height: CGFloat
    let hasNotch: Bool

    static func current() -> NotchGeometry {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return NotchGeometry(screen: screen,
                                 width: screen.frame.width - left.width - right.width,
                                 height: screen.safeAreaInsets.top, hasNotch: true)
        }
        return NotchGeometry(screen: screen, width: 180, height: 28, hasNotch: false)
    }
}

@MainActor
final class NotchState: ObservableObject {
    @Published var hovering = false
    @Published var peek = false
}

struct NotchView: View {
    @EnvironmentObject var session: Session
    @ObservedObject var state: NotchState
    let geometry: NotchGeometry
    let expanded: Bool
    let openHUD: () -> Void

    private let wing: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ReactorView(active: session.phase == .working, tint: Theme.tint(for: session.phase), size: geometry.height - 8)
                    .frame(width: wing)
                Spacer().frame(width: geometry.width)
                Circle()
                    .fill(Theme.tint(for: session.phase))
                    .frame(width: 8, height: 8)
                    .shadow(color: Theme.tint(for: session.phase), radius: 5)
                    .frame(width: wing)
            }
            .frame(height: geometry.height)

            if expanded {
                VStack(spacing: 8) {
                    Text(session.status)
                        .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(2)
                        .foregroundStyle(Theme.tint(for: session.phase))
                    Text(session.pending?.summary ?? session.log.last?.text ?? "Ready when you are, sir.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.cyan.opacity(0.85))
                        .lineLimit(2).multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        if session.pending != nil {
                            hudButton("DENY", tint: Theme.red) { session.resolve(false) }
                            hudButton("APPROVE", tint: Theme.green) { session.resolve(true) }
                        } else {
                            hudButton("OPEN HUD", tint: Theme.cyan, action: openHUD)
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
                    .stroke(Theme.tint(for: session.phase).opacity(expanded ? 0.6 : 0.25), lineWidth: 1))
                .shadow(color: Theme.tint(for: session.phase).opacity(session.phase == .working ? 0.7 : 0.2), radius: 10)
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
    private let geometry = NotchGeometry.current()
    private let state = NotchState()
    private let session: Session
    private var bag = Set<AnyCancellable>()
    private var expanded = false
    private var peekTask: Task<Void, Never>?

    init(session: Session, openHUD: @escaping () -> Void) {
        self.session = session
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        render(openHUD: openHUD)
        applyFrame(animated: false)
        panel.orderFrontRegardless()

        Publishers.CombineLatest3(state.$hovering, session.$phase, state.$peek)
            .receive(on: RunLoop.main)
            .sink { [weak self] hovering, phase, peek in
                let want = hovering || phase == .awaitingApproval || peek
                guard let self, want != self.expanded else { return }
                self.expanded = want
                self.render(openHUD: openHUD)
                self.applyFrame(animated: true)
            }
            .store(in: &bag)

        // Peek open for a few seconds when a mission ends.
        session.$phase
            .removeDuplicates()
            .filter { $0 == .done || $0 == .failed }
            .sink { [weak self] _ in self?.flash() }
            .store(in: &bag)
    }

    private func flash() {
        state.peek = true
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.state.peek = false }
        }
    }

    private func render(openHUD: @escaping () -> Void) {
        let root = NotchView(state: state, geometry: geometry, expanded: expanded, openHUD: openHUD)
            .environmentObject(session)
        panel.contentView = NSHostingView(rootView: root)
    }

    private func applyFrame(animated: Bool) {
        let size = expanded ? NSSize(width: max(geometry.width + 300, 420), height: geometry.height + 110)
                            : NSSize(width: geometry.width + 112, height: geometry.height)
        let frame = geometry.screen.frame
        let target = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }
}
