import Foundation

/// The kids-mode promise shared by the Mac app and the `tristan` CLI: questions stay on this machine (Ollama)
/// unless a parent allowed one cloud question.
package enum KidsRouting {
    /// True when kids mode is on and no parent allowed a cloud question once.
    package static func mustStayLocal(kidsMode: Bool, cloudOnce: Bool) -> Bool {
        kidsMode && !cloudOnce
    }
}
