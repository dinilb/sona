import Foundation

/// What's held to dictate: modifiers alone ("Right ⌘", "⌃⌥", fn), or modifiers plus one key ("⇪ A", "⌃⌥ Space").
/// A modifier with only one side set must be that side ("Right ⌘" isn't left ⌘); both sides set means either one.
public struct DictationShortcut: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let leftCommand = Modifiers(rawValue: 1 << 0)
        public static let rightCommand = Modifiers(rawValue: 1 << 1)
        public static let leftOption = Modifiers(rawValue: 1 << 2)
        public static let rightOption = Modifiers(rawValue: 1 << 3)
        public static let leftControl = Modifiers(rawValue: 1 << 4)
        public static let rightControl = Modifiers(rawValue: 1 << 5)
        public static let leftShift = Modifiers(rawValue: 1 << 6)
        public static let rightShift = Modifiers(rawValue: 1 << 7)
        public static let fn = Modifiers(rawValue: 1 << 8)
        /// Held like a modifier: while it's in the shortcut, Caps Lock is remapped so it stops toggling caps.
        public static let capsLock = Modifiers(rawValue: 1 << 9)

        public static let command: Modifiers = [.leftCommand, .rightCommand]
        public static let option: Modifiers = [.leftOption, .rightOption]
        public static let control: Modifiers = [.leftControl, .rightControl]
        public static let shift: Modifiers = [.leftShift, .rightShift]

        /// Two-sided groups in the order macOS writes them (⌃⌥⇧⌘).
        public static let groups: [(both: Modifiers, symbol: String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]

        /// Names in settings.json. A whole group's name ("command") means either side.
        static let names: [(Modifiers, String)] = [
            (.fn, "fn"), (.capsLock, "capsLock"), (.control, "control"), (.option, "option"), (.shift, "shift"),
            (.command, "command"), (.leftControl, "leftControl"), (.rightControl, "rightControl"),
            (.leftOption, "leftOption"), (.rightOption, "rightOption"), (.leftShift, "leftShift"),
            (.rightShift, "rightShift"), (.leftCommand, "leftCommand"), (.rightCommand, "rightCommand"),
        ]
    }

    public var modifiers: Modifiers
    /// The one other key, as a macOS virtual key code (kVK_ANSI_A is 0, Space 49), or nil for modifiers alone.
    public var key: UInt16?

    public init(modifiers: Modifiers, key: UInt16? = nil) {
        self.modifiers = modifiers
        self.key = key
    }

    public static let fn = DictationShortcut(modifiers: .fn)
    public static let rightOption = DictationShortcut(modifiers: .rightOption)
    public static let rightCommand = DictationShortcut(modifiers: .rightCommand)

    public var usesCapsLock: Bool { modifiers.contains(.capsLock) }

    /// Are these keys (each side separately) what the shortcut's modifiers ask for? Groups it doesn't use must be up.
    public func matches(_ held: Modifiers) -> Bool {
        for (both, _) in Modifiers.groups {
            let want = modifiers.intersection(both), have = held.intersection(both)
            if want == both ? have.isEmpty : have != want { return false }
        }
        return modifiers.intersection([.fn, .capsLock]) == held.intersection([.fn, .capsLock])
    }

    /// Why this can't be the shortcut, or nil. A bare key (or one with only ⇧) would be swallowed while typing;
    /// F1 to F20 alone are fine.
    public var problem: String? {
        guard let key else { return modifiers.isEmpty ? "Hold a modifier, or a modifier and a key." : nil }
        if modifiers.subtracting(.shift).isEmpty, Self.functionKeys[key] == nil {
            return "\(modifiers.isEmpty ? "" : "⇧ ")\(Self.name(of: key)) is used for typing. Add ⌃, ⌥, ⌘, fn or ⇪."
        }
        return nil
    }

    /// "fn", "Right ⌘", "⌃⌥", "⇪ A", "⌃⌥ Space", "Caps Lock".
    public var title: String {
        if modifiers == .capsLock, key == nil { return "Caps Lock" }
        var parts: [String] = []
        var symbols = modifiers.contains(.capsLock) ? "⇪" : ""
        if modifiers.contains(.fn) { parts.append("fn") }
        for (both, symbol) in Modifiers.groups {
            let mine = modifiers.intersection(both)
            if mine == both {
                symbols += symbol
            } else if !mine.isEmpty {
                // Sided keys get their own word, so "⌃" + "Right ⌘" reads "⌃ Right ⌘".
                if !symbols.isEmpty { parts.append(symbols) }
                symbols = ""
                parts.append((mine.rawValue & Modifiers.rightSides.rawValue != 0 ? "Right " : "Left ") + symbol)
            }
        }
        if !symbols.isEmpty { parts.append(symbols) }
        if let key { parts.append(Self.name(of: key)) }
        return parts.joined(separator: " ")
    }

    /// Key names on a US layout (the key's position, whatever the layout prints on it).
    public static func name(of key: UInt16) -> String {
        if let name = keyNames[key] { return name }
        return "Key \(key)"
    }

    static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    static let keyNames: [UInt16: String] = {
        // kVK_ANSI_A (0) to kVK_ANSI_Grave (50), in key code order.
        let ansi = [
            "A", "S", "D", "F", "H", "G", "Z", "X", "C", "V", "§", "B", "Q", "W", "E", "R", "Y", "T", "1", "2", "3", "4", "6",
            "5", "=", "9", "7", "-", "8", "0", "]", "O", "U", "[", "I", "P", "Return", "L", "J", "'", "K", ";", "\\", ",", "/",
            "N", "M", ".", "Tab", "Space", "`",
        ]
        var names = Dictionary(uniqueKeysWithValues: ansi.enumerated().map { (UInt16($0.offset), $0.element) })
        let others: [UInt16: String] = [
            51: "Delete", 53: "Esc", 71: "Clear", 76: "Enter", 114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete",
            119: "End", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑", 93: "¥", 94: "_", 102: "英数", 104: "かな",
            65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 75: "Keypad /", 78: "Keypad -", 81: "Keypad =", 95: "Keypad ,",
            82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6",
            89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
        ]
        names.merge(others) { a, _ in a }
        names.merge(functionKeys) { a, _ in a }
        return names
    }()
}

extension DictationShortcut.Modifiers {
    static let rightSides: DictationShortcut.Modifiers = [.rightCommand, .rightOption, .rightControl, .rightShift]
}

/// In settings.json, the three keys there were before ("fn", "rightOption", "rightCommand") stay those strings,
/// so a file still reads the same in an older version; anything else is `{"modifiers": [...], "key": 49}`.
extension DictationShortcut: Codable {
    private static let legacy: [(String, DictationShortcut)] = [("fn", .fn), ("rightOption", .rightOption), ("rightCommand", .rightCommand)]

    enum CodingKeys: String, CodingKey { case modifiers, key }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            guard let known = Self.legacy.first(where: { $0.0 == name }) else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "unknown dictation key \(name)")
            }
            self = known.1
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var modifiers: Modifiers = []
        for name in try c.decode([String].self, forKey: .modifiers) {
            guard let bits = Modifiers.names.first(where: { $0.1 == name })?.0 else {
                throw DecodingError.dataCorruptedError(forKey: .modifiers, in: c, debugDescription: "unknown modifier \(name)")
            }
            modifiers.formUnion(bits)
        }
        self.init(modifiers: modifiers, key: try c.decodeIfPresent(UInt16.self, forKey: .key))
    }

    public func encode(to encoder: Encoder) throws {
        if let name = Self.legacy.first(where: { $0.1 == self })?.0 {
            var single = encoder.singleValueContainer()
            try single.encode(name)
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Whole groups first, so either side is written "command", not both sides.
        var left = modifiers
        var names: [String] = []
        for (bits, name) in Modifiers.names where left.isSuperset(of: bits) {
            names.append(name)
            left.subtract(bits)
        }
        try c.encode(names, forKey: .modifiers)
        try c.encodeIfPresent(key, forKey: .key)
    }
}
