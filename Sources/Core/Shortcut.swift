import Foundation

/// A global keyboard shortcut as written in the config: modifiers and one key joined by "+",
/// e.g. "ctrl+opt+cmd+j". Foundation only; the app registers it as a Carbon hot key.
/// Key codes are the ANSI key positions (kVK_ANSI_*), as Carbon expects them.
struct Shortcut: Equatable {
    struct Modifiers: OptionSet, Equatable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let shift = Modifiers(rawValue: 4)
        static let command = Modifiers(rawValue: 8)
    }

    let key: String
    let keyCode: UInt32
    let modifiers: Modifiers

    enum ParseError: LocalizedError, Equatable {
        case unknownKey(String)
        case unknownModifier(String)
        case noKey
        case needsModifier

        var errorDescription: String? {
            switch self {
            case .unknownKey(let k): return "unknown key '\(k)' (use a-z, 0-9, space or f1-f12)"
            case .unknownModifier(let m): return "unknown modifier '\(m)' (use ctrl, opt, shift, cmd)"
            case .noKey: return "no key after the modifiers"
            case .needsModifier: return "needs ctrl, opt or cmd (shift alone is not enough), except for f1-f12"
            }
        }
    }

    /// nil for an empty string (shortcut off). Case and spaces do not matter.
    static func parse(_ text: String) throws -> Shortcut? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.allSatisfy(\.isEmpty) else { return nil }
        guard let key = parts.last, !key.isEmpty else { throw ParseError.noKey }
        var mods: Modifiers = []
        for m in parts.dropLast() {
            switch m {
            case "ctrl", "control", "⌃": mods.insert(.control)
            case "opt", "option", "alt", "⌥": mods.insert(.option)
            case "shift", "⇧": mods.insert(.shift)
            case "cmd", "command", "⌘": mods.insert(.command)
            default: throw ParseError.unknownModifier(m)
            }
        }
        guard let code = keyCodes[key] else {
            throw modifierNames.contains(key) ? ParseError.noKey : ParseError.unknownKey(key)
        }
        let isFunctionKey = key.hasPrefix("f") && key.count > 1
        if !isFunctionKey && mods.isDisjoint(with: [.control, .option, .command]) { throw ParseError.needsModifier }
        return Shortcut(key: key, keyCode: code, modifiers: mods)
    }

    /// "⌃⌥⌘J", in the order macOS menus use.
    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (key == "space" ? "Space" : key.uppercased())
    }

    private static let modifierNames: Set<String> = ["ctrl", "control", "opt", "option", "alt", "shift", "cmd", "command"]

    static let keyCodes: [String: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19,
        "7": 0x1A, "8": 0x1C, "0": 0x1D, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25,
        "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E, "space": 0x31,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
        "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]
}
