import Carbon.HIToolbox

/// System-wide hotkey via Carbon. Needs no accessibility permission.
final class GlobalHotKey {
    private static var handlers: [UInt32: (press: () -> Void, release: (() -> Void)?)] = [:]
    private static var installed = false
    private var ref: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, onRelease: (() -> Void)? = nil, handler: @escaping () -> Void) {
        let id = UInt32(Self.handlers.count + 1)
        Self.handlers[id] = (handler, onRelease)
        Self.installHandlerOnce()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4A525653), id: id)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
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
