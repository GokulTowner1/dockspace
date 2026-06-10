import Carbon.HIToolbox
import AppKit

// MARK: - KeyCombo

struct KeyCombo: Equatable, Hashable, Codable {
    var keyCode: UInt32        // Virtual key code (matches NSEvent.keyCode)
    var carbonModifiers: UInt32 // Carbon modifier format (cmdKey, shiftKey, etc.)

    // Default: ⌘⇧P — avoids conflicting with in-app "⌘P" quick-open in editors.
    static let `default` = KeyCombo(
        keyCode: UInt32(kVK_ANSI_P),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )

    // MARK: - Display

    /// Human-readable representation: "⌘P", "⌃⇧Space", etc.
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += Self.keyName(for: Int(keyCode))
        return s
    }

    /// Split into individual key-cap strings for the UI: ["⌘", "P"]
    var keyCaps: [String] {
        var caps: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { caps.append("⌃") }
        if carbonModifiers & UInt32(optionKey)  != 0 { caps.append("⌥") }
        if carbonModifiers & UInt32(shiftKey)   != 0 { caps.append("⇧") }
        if carbonModifiers & UInt32(cmdKey)     != 0 { caps.append("⌘") }
        caps.append(Self.keyName(for: Int(keyCode)))
        return caps
    }

    // MARK: - Conversion from NSEvent

    static func from(nsKeyCode: UInt16, nsModifiers: NSEvent.ModifierFlags) -> KeyCombo {
        var mods: UInt32 = 0
        let flags = nsModifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return KeyCombo(keyCode: UInt32(nsKeyCode), carbonModifiers: mods)
    }

    /// True if this combo matches a live NSEvent
    func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(keyCode) else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var expected = NSEvent.ModifierFlags()
        if carbonModifiers & UInt32(cmdKey)     != 0 { expected.insert(.command) }
        if carbonModifiers & UInt32(shiftKey)   != 0 { expected.insert(.shift) }
        if carbonModifiers & UInt32(optionKey)  != 0 { expected.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { expected.insert(.control) }
        return flags == expected
    }

    // MARK: - UserDefaults Persistence

    private static let keyCodeKey       = "dockspace.hotkey.keyCode"
    private static let modifiersKey     = "dockspace.hotkey.modifiers"

    static func loadFromDefaults() -> KeyCombo {
        let code = UserDefaults.standard.integer(forKey: keyCodeKey)
        let mods = UserDefaults.standard.integer(forKey: modifiersKey)
        guard code > 0 else { return .default }
        return KeyCombo(keyCode: UInt32(code), carbonModifiers: UInt32(mods))
    }

    func saveToDefaults() {
        UserDefaults.standard.set(Int(keyCode), forKey: Self.keyCodeKey)
        UserDefaults.standard.set(Int(carbonModifiers), forKey: Self.modifiersKey)
    }

    // MARK: - Key Name Lookup

    static func keyName(for code: Int) -> String {
        let map: [Int: String] = [
            0: "A",  1: "S",  2: "D",  3: "F",  4: "H",  5: "G",
            6: "Z",  7: "X",  8: "C",  9: "V",  11: "B", 12: "Q",
            13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
            49: "Space", 51: "⌫", 53: "ESC", 76: "↩",
            96: "F5",  97: "F6",  98: "F7",  99: "F3",
            100: "F8", 101: "F9", 103: "F11", 109: "F10",
            111: "F12", 118: "F4", 120: "F2", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return map[code] ?? "?\(code)"
    }
}
