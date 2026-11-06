import Carbon.HIToolbox

/// System-wide hotkey via Carbon. Needs no accessibility permission.
final class GlobalHotKey {
    private static var handlers: [UInt32: (press: () -> Void, release: (() -> Void)?)] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1
    private var ref: EventHotKeyRef?
    private let id: UInt32

    init(keyCode: Int, modifiers: Int, onRelease: (() -> Void)? = nil, handler: @escaping () -> Void) {
        let id = Self.nextID
        Self.nextID += 1
        self.id = id
        Self.handlers[id] = (handler, onRelease)
        Self.installHandlerOnce()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4A525653), id: id)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            DispatchQueue.main.async {
                guard let entry = GlobalHotKey.handlers[hotKeyID.id] else { return }
                if released { entry.release?() } else { entry.press() }
            }
            return noErr
        }, 2, &specs, nil, nil)
    }
}

/// Shortcut choices for showing Tristan. The push-to-talk key is the same combination plus Shift.
enum HotkeyPreset: String, CaseIterable, Identifiable {
    case optionSpace = "⌥ Space"
    case controlSpace = "⌃ Space"
    case commandOptionSpace = "⌥⌘ Space"
    case controlOptionSpace = "⌃⌥ Space"

    var id: String { rawValue }

    var modifiers: Int {
        switch self {
        case .optionSpace: return optionKey
        case .controlSpace: return controlKey
        case .commandOptionSpace: return optionKey | cmdKey
        case .controlOptionSpace: return controlKey | optionKey
        }
    }

    var talkLabel: String { rawValue.replacingOccurrences(of: " Space", with: "⇧ Space") }
}
