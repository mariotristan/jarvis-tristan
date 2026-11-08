import Foundation

/// The kids-mode promise shared by the Mac app and the `tristan` CLI: questions stay on this machine (Ollama)
/// unless a parent allowed one cloud question.
package enum KidsRouting {
    /// The `kidsMode` setting as the `tristan` CLI reads it, failing closed: on when it is set, and also when the
    /// settings store exists but cannot be read (a corrupt or unreadable settings file on Windows or Linux), since it
    /// may hold a parent's "on". A `kidsMode` value that is there but is not a Bool (`"true"`, `"no"`, an object; written
    /// by hand or by another tool) also counts as on. With UserDefaults (the Mac) the store is never unreadable and the
    /// app only writes Bools, so there this is the stored flag.
    package static var kidsModeIsOn: Bool {
        if Settings.unreadable != nil { return true }
        guard let value = Settings.backend.object(forKey: "kidsMode") else { return false }
        return (value as? Bool) ?? true
    }

    /// True when kids mode is on and no parent allowed a cloud question once.
    package static func mustStayLocal(kidsMode: Bool, cloudOnce: Bool) -> Bool {
        kidsMode && !cloudOnce
    }
}
