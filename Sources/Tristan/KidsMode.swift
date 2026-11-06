import Foundation
import CryptoKit
import LocalAuthentication

/// How a parent proves who they are: a PIN set in Settings, or the Mac's own Touch ID / password.
enum ParentAuth: String, CaseIterable, Identifiable {
    case pin = "PIN"
    case system = "TOUCH ID / MAC PASSWORD"
    var id: String { rawValue }
}

enum ParentPIN {
    nonisolated(unsafe) static var account = "kids.pin"
    /// The recorded demo keeps its PIN in memory so it never touches (or prompts for) the real Keychain.
    nonisolated(unsafe) static var inMemory = false
    nonisolated(unsafe) private static var memoryHash: String?

    private static func stored() -> String? { inMemory ? memoryHash : KeychainStore.get(account) }
    static let minimumLength = 4

    static func hash(_ pin: String) -> String {
        SHA256.hash(data: Data(("tristan-kids:" + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static var isSet: Bool { stored()?.isEmpty == false }

    static func valid(_ pin: String) -> Bool {
        pin.count >= minimumLength && pin.allSatisfy(\.isNumber)
    }

    @discardableResult
    static func set(_ pin: String) -> Bool {
        guard valid(pin) else { return false }
        if inMemory { memoryHash = hash(pin); return true }
        return KeychainStore.set(hash(pin), account: account)
    }

    static func matches(_ pin: String) -> Bool {
        guard let stored = stored(), !stored.isEmpty else { return false }
        return stored == hash(pin)
    }
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
        let unlocked: () -> Void = { [weak self] in
            self?.unlockParent()
            action()
        }
        switch parentAuth {
        case .pin where ParentPIN.isSet:
            parentPrompt = ParentPrompt(reason: reason, method: .pin, onApproved: unlocked)
        case .system:
            SystemAuth.evaluate(reason: reason) { ok in if ok { unlocked() } }
        default:
            // Kids mode is on with the PIN method but no PIN was stored (cleared keychain): fall back to the Mac's own login.
            SystemAuth.evaluate(reason: reason) { ok in if ok { unlocked() } }
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

/// Set by `Tristan --demo`: nothing in the recorded demo may read or write the Keychain.
enum NoKeychain {
    nonisolated(unsafe) static var enabled = false
}
