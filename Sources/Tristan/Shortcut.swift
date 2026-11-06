import AppKit
import Carbon.HIToolbox

/// A global shortcut: a key plus Carbon modifier flags. Push-to-talk is the same shortcut plus Shift.
struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int      // Carbon mask: cmdKey, optionKey, controlKey, shiftKey
    var keyName: String

    static let `default` = Shortcut(keyCode: kVK_Space, modifiers: optionKey, keyName: "Space")

    var talk: Shortcut { Shortcut(keyCode: keyCode, modifiers: modifiers | shiftKey, keyName: keyName) }

    var display: String {
        var symbols = ""
        if modifiers & controlKey != 0 { symbols += "⌃" }
        if modifiers & optionKey != 0 { symbols += "⌥" }
        if modifiers & shiftKey != 0 { symbols += "⇧" }
        if modifiers & cmdKey != 0 { symbols += "⌘" }
        return "\(symbols) \(keyName)"
    }

    /// Why this shortcut cannot be used, or nil if it is fine.
    var validationError: String? {
        if modifiers & shiftKey != 0 { return "Shift is reserved for push-to-talk. Use ⌃, ⌥ or ⌘." }
        if modifiers & (cmdKey | optionKey | controlKey) == 0 { return "Include at least one of ⌃, ⌥ or ⌘." }
        let reservedWithCommand = [kVK_Space, kVK_Tab, kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_H, kVK_ANSI_M]
        if modifiers == cmdKey, reservedWithCommand.contains(keyCode) { return "macOS already uses that combination." }
        return nil
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete", kVK_Escape: "Esc",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func make(keyCode: Int, flags: NSEvent.ModifierFlags, characters: String?) -> Shortcut {
        var mask = 0
        if flags.contains(.command) { mask |= cmdKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.control) { mask |= controlKey }
        if flags.contains(.shift) { mask |= shiftKey }
        let name = specialKeys[keyCode] ?? characters?.uppercased().first.map(String.init) ?? "Key \(keyCode)"
        return Shortcut(keyCode: keyCode, modifiers: mask, keyName: name)
    }
}

/// Quick picks shown next to the recorder.
enum HotkeyPreset: String, CaseIterable, Identifiable {
    case optionSpace = "⌥ Space"
    case controlSpace = "⌃ Space"
    case commandOptionSpace = "⌥⌘ Space"
    case controlOptionSpace = "⌃⌥ Space"

    var id: String { rawValue }

    var shortcut: Shortcut {
        switch self {
        case .optionSpace: return Shortcut(keyCode: kVK_Space, modifiers: optionKey, keyName: "Space")
        case .controlSpace: return Shortcut(keyCode: kVK_Space, modifiers: controlKey, keyName: "Space")
        case .commandOptionSpace: return Shortcut(keyCode: kVK_Space, modifiers: optionKey | cmdKey, keyName: "Space")
        case .controlOptionSpace: return Shortcut(keyCode: kVK_Space, modifiers: controlKey | optionKey, keyName: "Space")
        }
    }
}
