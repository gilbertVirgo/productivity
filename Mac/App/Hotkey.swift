import AppKit
import Carbon.HIToolbox

/// ⌃⌥Space through Carbon `RegisterEventHotKey`: global, and no Accessibility permission (spec 2026-11-26 §6.3).
@MainActor
final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private(set) var registered = false

    init(action: @escaping () -> Void) { self.action = action }

    func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            guard let ctx else { return noErr }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { hotkey.action() } // Carbon delivers application events on the main thread
            return noErr
        }, 1, &spec, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x5354_4E54), id: 1) // 'STNT'
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &ref)
        registered = status == noErr
    }
}
