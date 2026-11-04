import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut. Uses the Carbon hot-key API, which macOS still provides for exactly
/// this: it works while any app is in front and needs no Accessibility permission.
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }

    /// Registers the shortcut, replacing any previous one. Returns false if another app already owns it.
    @discardableResult
    func register(_ shortcut: AppSettings.Shortcut) -> Bool {
        unregister()
        guard let key = shortcut.key else { return true }   // "Off"
        let id = EventHotKeyID(signature: OSType(0x4141_5952), id: 1)   // 'AAYR'
        return RegisterEventHotKey(key.code, key.modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}

extension AppSettings.Shortcut {
    /// Carbon key code and modifier flags, or nil for "Off".
    var key: (code: UInt32, modifiers: UInt32)? {
        let m = UInt32(kVK_ANSI_M)
        switch self {
        case .off: return nil
        case .optionCommandM: return (m, UInt32(optionKey | cmdKey))
        case .controlOptionM: return (m, UInt32(controlKey | optionKey))
        case .controlOptionCommandM: return (m, UInt32(controlKey | optionKey | cmdKey))
        }
    }
}
