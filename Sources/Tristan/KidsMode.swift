import Foundation
import CryptoKit
import LocalAuthentication
import TristanCore

/// How a parent proves who they are: a PIN set in Settings, or the Mac's own Touch ID / password.
enum ParentAuth: String, CaseIterable, Identifiable {
    case pin = "PIN"
    case system = "TOUCH ID / MAC PASSWORD"
    var id: String { rawValue }
}

/// A question to the parent: shown by the HUD until it is answered or cancelled.
struct ParentPrompt: Identifiable {
    let id = UUID()
    let reason: String
    let method: ParentAuth
    let onApproved: () -> Void
}

enum SystemAuth {
    /// Touch ID, Apple Watch or the Mac's password.
    static func evaluate(reason: String, _ done: @escaping @MainActor (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            Task { @MainActor in done(false) }
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            Task { @MainActor in done(ok) }
        }
    }
}

extension Session {
    static let parentUnlockSeconds: TimeInterval = 300

    /// True while kids safe mode is on and no parent has unlocked it.
    var kidsLocked: Bool { kidsMode && !parentUnlocked }

    /// Runs `action` straight away unless kids mode is locked, in which case a parent is asked first.
    func requireParent(_ reason: String, then action: @escaping () -> Void) {
        guard kidsLocked else { action(); return }
        askParent(reason) { [weak self] in
            self?.unlockParent()
            action()
        }
    }

    /// Asks a parent for this one thing only; unlike `requireParent` it does not unlock kids mode afterwards.
    func askParent(_ reason: String, onApproved: @escaping () -> Void) {
        switch parentAuth {
        case .pin where ParentPIN.isSet:
            parentPrompt = ParentPrompt(reason: reason, method: .pin, onApproved: onApproved)
        case .system:
            SystemAuth.evaluate(reason: reason) { ok in if ok { onApproved() } }
        default:
            // Kids mode is on with the PIN method but no PIN was stored (cleared keychain): fall back to the Mac's own login.
            SystemAuth.evaluate(reason: reason) { ok in if ok { onApproved() } }
        }
    }

    func submitParentPIN(_ pin: String) -> Bool {
        guard let prompt = parentPrompt, ParentPIN.matches(pin) else { parentPINFailed = parentPrompt != nil; return false }
        parentPrompt = nil
        parentPINFailed = false
        prompt.onApproved()
        return true
    }

    func cancelParentPrompt() { parentPrompt = nil; parentPINFailed = false }

    func unlockParent() {
        parentUnlocked = true
        relock?.cancel()
        relock = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.parentUnlockSeconds))
            guard !Task.isCancelled else { return }
            self?.lockKids()
        }
    }

    /// Back to kid mode: Settings close and anything beyond ASK is switched off.
    func lockKids() {
        relock?.cancel()
        relock = nil
        parentUnlocked = false
        guard kidsMode else { return }
        showSettings = false
        if approvalMode != .ask, !busy { approvalMode = .ask }
    }

    /// The gear button and anything else that opens Settings.
    func openSettings() {
        if showSettings { showSettings = false; if kidsMode { lockKids() }; return }
        requireParent("Open Tristan's settings") { [weak self] in self?.showSettings = true }
    }

    func closeSettings() {
        showSettings = false
        if kidsMode { lockKids() }
    }
}
