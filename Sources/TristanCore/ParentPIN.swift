import Foundation
import CryptoKit

package enum ParentPIN {
    package nonisolated(unsafe) static var account = "kids.pin"
    /// The recorded demo keeps its PIN in memory so it never touches (or prompts for) the real Keychain.
    package nonisolated(unsafe) static var inMemory = false
    nonisolated(unsafe) private static var memoryHash: String?

    private static func stored() -> String? { inMemory ? memoryHash : KeychainStore.get(account) }
    static let minimumLength = 4

    static func hash(_ pin: String) -> String {
        SHA256.hash(data: Data(("tristan-kids:" + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    package static var isSet: Bool { stored()?.isEmpty == false }

    package static func valid(_ pin: String) -> Bool {
        pin.count >= minimumLength && pin.allSatisfy(\.isNumber)
    }

    @discardableResult
    package static func set(_ pin: String) -> Bool {
        guard valid(pin) else { return false }
        if inMemory { memoryHash = hash(pin); return true }
        return KeychainStore.set(hash(pin), account: account)
    }

    package static func matches(_ pin: String) -> Bool {
        guard let stored = stored(), !stored.isEmpty else { return false }
        return stored == hash(pin)
    }
}
