import Foundation

/// US keyboard layout, HID usage page 0x07.
enum KeyboardMap {
    /// A key usage together with the modifier bits that must stay held while
    /// that usage is pressed and released.
    struct Stroke {
        let code: UInt8
        let modifiers: UInt8
    }

    static let shift: UInt8 = 0x02

    static let modifiers: [String: UInt8] = [
        "ctrl": 0x01, "control": 0x01,
        "shift": 0x02,
        "alt": 0x04, "option": 0x04,
        "cmd": 0x08, "command": 0x08,
    ]

    static let named: [String: UInt8] = [
        "enter": 0x28, "return": 0x28, "escape": 0x29, "esc": 0x29,
        "backspace": 0x2A, "delete": 0x2A, "tab": 0x2B, "space": 0x2C,
        "capslock": 0x39, "caps_lock": 0x39,
        "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
        "forwarddelete": 0x4C, "home": 0x4A, "end": 0x4D, "pageup": 0x4B, "pagedown": 0x4E,
    ]

    private static let plain: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { map[c] = 0x04 + UInt8(i) }
        for (i, c) in "1234567890".enumerated() { map[c] = 0x1E + UInt8(i) }
        let rest: [(Character, UInt8)] = [
            ("\n", 0x28), ("\t", 0x2B), (" ", 0x2C), ("-", 0x2D), ("=", 0x2E), ("[", 0x2F), ("]", 0x30),
            ("\\", 0x31), (";", 0x33), ("'", 0x34), ("`", 0x35), (",", 0x36), (".", 0x37), ("/", 0x38),
        ]
        for (c, code) in rest { map[c] = code }
        return map
    }()

    private static let shifted: [Character: Character] = {
        var map: [Character: Character] = [:]
        for c in "abcdefghijklmnopqrstuvwxyz" { map[Character(c.uppercased())] = c }
        let pairs = Array(zip("!@#$%^&*()_+{}|:\"~<>?", "1234567890-=[]\\;'`,./"))
        for (upper, lower) in pairs { map[upper] = lower }
        return map
    }()

    /// Named keys take priority over character lookup. Callers retain their
    /// own failure policy: HTTP input throws, while window input returns false.
    /// Key commands supply their modifiers separately, so character lookup
    /// returns only the usage code and does not add an implicit Shift modifier.
    static func code(for name: String) -> UInt8? {
        named[name.lowercased()] ?? stroke(for: Character(name))?.code
    }

    static func modifierBit(for name: String) -> UInt8? {
        modifiers[name.lowercased()]
    }

    static func modifierMask(for names: [String]) -> UInt8? {
        var mask: UInt8 = 0
        for name in names {
            guard let bit = modifierBit(for: name) else { return nil }
            mask |= bit
        }
        return mask
    }

    private static let umlautU: [Character: Character] = [
        "ü": "v", "ǖ": "v", "ǘ": "v", "ǚ": "v", "ǜ": "v",
        "Ü": "V", "Ǖ": "V", "Ǘ": "V", "Ǚ": "V", "Ǜ": "V",
    ]

    private static let hanPattern = try! NSRegularExpression(pattern: "\\p{Han}")

    static func containsHanzi(_ text: String) -> Bool {
        hanPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Preflight the whole input before sending reports. Han runs become pinyin
    /// followed by a space to select the IME's current first candidate.
    static func keyboardText(for text: String) -> String? {
        var output = ""
        var han = ""
        func flush() -> Bool {
            guard !han.isEmpty else { return true }
            guard
                let toned = han.applyingTransform(.toLatin, reverse: false),
                // Map ü before removing tones; ICU already emits plain u after j/q/x/y.
                let latin = String(toned.precomposedStringWithCanonicalMapping.map { umlautU[$0] ?? $0 })
                    .applyingTransform(.stripCombiningMarks, reverse: false)
            else { return false }
            let pinyin = latin.lowercased().filter { !$0.isWhitespace }
            guard !pinyin.isEmpty, pinyin.allSatisfy({ $0 >= "a" && $0 <= "z" }) else { return false }
            output += pinyin + " "
            han = ""
            return true
        }
        for character in text {
            if containsHanzi(String(character)) {
                han.append(character)
            } else {
                guard flush(), stroke(for: character) != nil else { return nil }
                output.append(character)
            }
        }
        return flush() ? output : nil
    }

    static func stroke(for character: Character) -> Stroke? {
        if let code = plain[character] { return Stroke(code: code, modifiers: 0) }
        if let base = shifted[character], let code = plain[base] { return Stroke(code: code, modifiers: shift) }
        return nil
    }
}
