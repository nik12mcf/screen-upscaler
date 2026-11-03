import Carbon.HIToolbox

/// A system-wide keyboard shortcut via Carbon's hot key API, which - unlike
/// an NSEvent global monitor - needs no Accessibility permission.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// `keyCode` is a virtual key code (kVK_*), `modifiers` Carbon flags (cmdKey etc).
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, selfPtr, &handler)
        guard status == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x5355_5052), id: 1)   // 'SUPR'
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                                  GetApplicationEventTarget(), 0, &ref) == noErr else {
            RemoveEventHandler(handler)
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
