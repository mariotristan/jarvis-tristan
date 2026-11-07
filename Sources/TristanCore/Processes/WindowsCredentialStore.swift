#if os(Windows)
import Foundation
import WinSDK

/// Generic credentials in the Windows Credential Manager, called directly through `WinSDK` so a secret never appears on
/// a command line. Values are stored as UTF-8 bytes under the target name `KeychainStore` passes
/// (`com.tristan.app/<account>`), kept for this user on this machine.
enum WindowsCredentialStore {
    private static let genericType = DWORD(1)           // CRED_TYPE_GENERIC
    private static let persistLocalMachine = DWORD(2)   // CRED_PERSIST_LOCAL_MACHINE
    private static let notFound = DWORD(1168)           // ERROR_NOT_FOUND

    static func get(_ target: String) -> String? {
        var credential: PCREDENTIALW? = nil
        let found = target.withCString(encodedAs: UTF16.self) { CredReadW($0, genericType, 0, &credential) }
        guard found, let credential else { return nil }
        defer { CredFree(UnsafeMutableRawPointer(credential)) }
        let size = Int(credential.pointee.CredentialBlobSize)
        guard size > 0, let blob = credential.pointee.CredentialBlob else { return nil }
        return decode(Array(UnsafeBufferPointer(start: blob, count: size)))
    }

    /// `set` writes UTF-8. Windows' own tools (`cmdkey`, the Credential Manager window) store the password as UTF-16LE,
    /// so a blob whose every second byte is zero (an ASCII or Latin-1 key typed there) is read as UTF-16LE. Trailing
    /// NUL characters (a terminator some tools store with the value) are not part of the value and are dropped, in
    /// both encodings. Nil when nothing is left (a blob holding only NULs is no value).
    ///
    /// Not supported: a value typed into `cmdkey` or the Credential Manager window with characters above U+00FF.
    /// Its UTF-16LE high bytes are not zero, so it cannot be told from UTF-8 and is read as UTF-8 (garbled). Store such
    /// a value with `tristan secret set` instead.
    static func decode(_ bytes: [UInt8]) -> String? {
        var text: String
        if bytes.count >= 2, bytes.count % 2 == 0, stride(from: 1, to: bytes.count, by: 2).allSatisfy({ bytes[$0] == 0 }) {
            let units = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
            text = String(decoding: units, as: UTF16.self)
        } else {
            text = String(decoding: bytes, as: UTF8.self)
        }
        while text.unicodeScalars.last == "\0" { text.unicodeScalars.removeLast() }
        return text.isEmpty ? nil : text
    }

    /// Creates or replaces the credential. False when Windows refuses it (for example a value over 2,560 bytes).
    static func set(_ value: String, target: String) -> Bool {
        var blob = Array(value.utf8)
        defer { for index in blob.indices { blob[index] = 0 } }
        return target.withCString(encodedAs: UTF16.self) { name in
            blob.withUnsafeMutableBufferPointer { bytes in
                var credential = CREDENTIALW()
                credential.`Type` = genericType
                credential.TargetName = UnsafeMutablePointer(mutating: name)
                credential.CredentialBlobSize = DWORD(bytes.count)
                credential.CredentialBlob = bytes.baseAddress
                credential.Persist = persistLocalMachine
                return CredWriteW(&credential, 0)
            }
        }
    }

    /// True when the credential is gone afterwards, including when there was none.
    static func delete(_ target: String) -> Bool {
        target.withCString(encodedAs: UTF16.self) { name in
            CredDeleteW(name, genericType, 0) || GetLastError() == notFound
        }
    }
}
#endif
