import Foundation

/// The kids-mode promise shared by the Mac app and the `tristan` CLI: questions stay on this machine (Ollama)
/// unless a parent allowed one cloud question.
package enum KidsRouting {
    /// The `kidsMode` setting as the `tristan` CLI reads it, failing closed: on when it is set, and also when the
    /// settings store exists but cannot be read (a corrupt or unreadable settings file on Windows or Linux), since it
    /// may hold a parent's "on". With UserDefaults (the Mac) the store is never unreadable, so this is the stored flag.
    package static var kidsModeIsOn: Bool {
        Settings.unreadable != nil || Settings.bool("kidsMode")
    }

    /// True when kids mode is on and no parent allowed a cloud question once.
    package static func mustStayLocal(kidsMode: Bool, cloudOnce: Bool) -> Bool {
        kidsMode && !cloudOnce
    }
}
