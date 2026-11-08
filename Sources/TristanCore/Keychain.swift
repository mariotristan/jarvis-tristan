import Foundation
#if canImport(Security)
import Security
#endif

/// Set by `Tristan --demo`: nothing in the recorded demo may read or write the real Keychain, because an ad-hoc signed app
/// makes macOS ask for the login password. `KeychainStore` then keeps values in memory for the life of the process.
package enum NoKeychain {
    package nonisolated(unsafe) static var enabled = false
}

/// Minimal Keychain wrapper for provider credentials (Windows Credential Manager on Windows). Secrets never go in
/// UserDefaults, settings files or the repository.
package enum KeychainStore {
    private static let service = "com.tristan.app"

    private static let memoryLock = NSLock()
    nonisolated(unsafe) private static var memory: [String: String] = [:]

    package static func get(_ account: String) -> String? {
        if NoKeychain.enabled { memoryLock.lock(); defer { memoryLock.unlock() }; return memory[account] }
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #elseif os(Windows)
        return WindowsCredentialStore.get(target(account))
        #else
        return nil
        #endif
    }

    /// Stores the value, or deletes the entry when it is empty. Returns false on failure.
    @discardableResult
    package static func set(_ value: String, account: String) -> Bool {
        if NoKeychain.enabled {
            memoryLock.lock(); defer { memoryLock.unlock() }
            memory[account] = value.isEmpty ? nil : value
            return true
        }
        #if canImport(Security)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        #elseif os(Windows)
        return value.isEmpty ? WindowsCredentialStore.delete(target(account)) : WindowsCredentialStore.set(value, target: target(account))
        #else
        return false
        #endif
    }

    /// The Credential Manager target name on Windows: `com.tristan.app/<account>`.
    static func target(_ account: String) -> String { service + "/" + account }
}
