import AppKit
import Carbon.HIToolbox

/// A single global hotkey registered with the Carbon Hot Key API.
///
/// Carbon is deprecated but remains the most reliable way to capture a system
/// wide shortcut without any private API or extra entitlements.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id = EventHotKeyID(signature: OSType(0x4454_4f48), id: 1) // 'DTOH'
    var onPressed: (() -> Void)?

    /// `keyCode` is a Carbon virtual key code; `modifiers` are Carbon modifier
    /// flags (e.g. `cmdKey | shiftKey`).
    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let hk = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hk.onPressed?() }
            return noErr
        }, 1, &eventType, selfPtr, &handler)

        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }

    deinit { unregister() }
}
