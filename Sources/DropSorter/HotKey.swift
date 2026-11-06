import AppKit
import Carbon.HIToolbox

/// One global hot key through Carbon's RegisterEventHotKey: works while any app is active and needs
/// no Accessibility permission. Registration fails when another app already holds the same keys.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// Throws the OSStatus when the keys are taken or the handler cannot be installed.
    init(_ shortcut: Shortcut, action: @escaping () -> Void) throws {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        var status = InstallEventHandler(GetApplicationEventTarget(), { _, _, user in
            guard let user else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(user).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, me, &handler)
        guard status == noErr else { throw HotKeyError.status(status) }
        let id = EventHotKeyID(signature: OSType(0x4453_4A50), id: 1)  // "DSJP"
        status = RegisterEventHotKey(shortcut.keyCode, Self.carbonModifiers(shortcut.modifiers), id,
                                     GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            RemoveEventHandler(handler)
            handler = nil
            throw HotKeyError.status(status)
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    private static func carbonModifiers(_ m: Shortcut.Modifiers) -> UInt32 {
        var flags = 0
        if m.contains(.command) { flags |= cmdKey }
        if m.contains(.option) { flags |= optionKey }
        if m.contains(.control) { flags |= controlKey }
        if m.contains(.shift) { flags |= shiftKey }
        return UInt32(flags)
    }

    /// The menu shows the shortcut next to Jump to Folder.
    static func menuModifiers(_ m: Shortcut.Modifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if m.contains(.command) { flags.insert(.command) }
        if m.contains(.option) { flags.insert(.option) }
        if m.contains(.control) { flags.insert(.control) }
        if m.contains(.shift) { flags.insert(.shift) }
        return flags
    }
}

enum HotKeyError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let s) where s == OSStatus(eventHotKeyExistsErr): return "another app already uses this shortcut"
        case .status(let s): return "macOS refused the shortcut (error \(s))"
        }
    }
}
