import ApplicationServices
import Foundation

enum HotkeyAction {
    case paste
    case dump
    case bluetooth

    var displayName: String {
        switch self {
        case .paste:
            return "paste"
        case .dump:
            return "dump"
        case .bluetooth:
            return "bluetooth"
        }
    }
}

enum RecordingState {
    case idle
    case recordingInformation(action: HotkeyAction)
    case recordingInstruction(action: HotkeyAction, informationURL: URL)
    case recordingHermesInstruction(informationURL: URL, screenshotURL: URL?)
}

struct HotkeysConfig: Codable {
    var paste = HotkeyConfig(control: false, option: true, command: true, shift: false)
    var dump = HotkeyConfig(control: true, option: true, command: false, shift: false)
    var bluetooth = KeyChordConfig(keys: [])

    enum CodingKeys: String, CodingKey {
        case paste
        case dump
        case bluetooth
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paste = try container.decodeIfPresent(HotkeyConfig.self, forKey: .paste) ?? paste
        dump = try container.decodeIfPresent(HotkeyConfig.self, forKey: .dump) ?? dump
        bluetooth = try container.decodeIfPresent(KeyChordConfig.self, forKey: .bluetooth) ?? bluetooth
    }

    func action(for flags: CGEventFlags) -> HotkeyAction? {
        if paste.isPressed(in: flags) {
            return .paste
        }
        if dump.isPressed(in: flags) {
            return .dump
        }
        return nil
    }

    func isCommandOnlyPressed(in flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand)
            && !flags.contains(.maskAlternate)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskShift)
    }

    func isOptionOnlyPressed(in flags: CGEventFlags) -> Bool {
        flags.contains(.maskAlternate)
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskShift)
    }

    func isContinuationPressed(for action: HotkeyAction, in flags: CGEventFlags) -> Bool {
        switch action {
        case .paste:
            return isCommandOnlyPressed(in: flags)
        case .dump:
            return isOptionOnlyPressed(in: flags)
        case .bluetooth:
            return false
        }
    }

    func isHermesAgentContinuationPressed(for action: HotkeyAction, in flags: CGEventFlags) -> Bool {
        switch action {
        case .paste:
            return isOptionOnlyPressed(in: flags)
        case .dump, .bluetooth:
            return false
        }
    }
}

struct HotkeyKey: Codable, Hashable, RawRepresentable {
    let rawValue: String

    static let rightShift = HotkeyKey(rawValue: "right_shift")
    static let defaultBluetoothKey = HotkeyKey.rightShift

    init(rawValue: String) {
        self.rawValue = Self.normalized(rawValue)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var keyCode: CGKeyCode? {
        Self.keyCodes[rawValue]
    }

    var displayName: String {
        if let displayName = Self.displayNames[rawValue] {
            return displayName
        }
        return rawValue
            .split(separator: "_")
            .map { $0.uppercased().hasPrefix("F") ? $0.uppercased() : $0.capitalized }
            .joined(separator: " ")
    }

    var modifierFlag: CGEventFlags? {
        Self.modifierFlags[rawValue]
    }

    var deviceFlag: CGEventFlags? {
        Self.deviceFlags[rawValue]
    }

    var isModifier: Bool {
        modifierFlag != nil
    }

    static func parse(_ value: String) -> HotkeyKey? {
        let key = HotkeyKey(rawValue: value)
        guard key.keyCode != nil else {
            return nil
        }
        return key
    }

    private static func normalized(_ value: String) -> String {
        let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = lowercased.replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        let aliases = [
            "rightshift": "right_shift",
            "rshift": "right_shift",
            "shift_right": "right_shift",
            "rechts_shift": "right_shift",
            "rechte_shift": "right_shift",
            "leftshift": "left_shift",
            "lshift": "left_shift",
            "shift_left": "left_shift",
            "links_shift": "left_shift",
            "linke_shift": "left_shift",
            "rightoption": "right_option",
            "roption": "right_option",
            "right_alt": "right_option",
            "alt_right": "right_option",
            "leftoption": "left_option",
            "loption": "left_option",
            "left_alt": "left_option",
            "alt_left": "left_option",
            "rightcontrol": "right_control",
            "rcontrol": "right_control",
            "right_ctrl": "right_control",
            "ctrl_right": "right_control",
            "leftcontrol": "left_control",
            "lcontrol": "left_control",
            "left_ctrl": "left_control",
            "ctrl_left": "left_control",
            "rightcommand": "right_command",
            "rcmd": "right_command",
            "right_cmd": "right_command",
            "cmd_right": "right_command",
            "leftcommand": "left_command",
            "lcmd": "left_command",
            "left_cmd": "left_command",
            "cmd_left": "left_command",
            "enter": "return",
            "esc": "escape",
            "backspace": "delete",
            "del": "delete",
        ]
        return aliases[key] ?? key
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53,
        "left_command": 55, "left_shift": 56, "caps_lock": 57, "left_option": 58,
        "left_control": 59, "right_shift": 60, "right_option": 61,
        "right_control": 62, "right_command": 54,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103,
        "f12": 111, "f13": 105, "f14": 107, "f15": 113, "f16": 106,
        "f17": 64, "f18": 79, "f19": 80, "f20": 90,
    ]

    private static let displayNames: [String: String] = [
        "left_command": "Left Command",
        "right_command": "Right Command",
        "left_shift": "Left Shift",
        "right_shift": "Right Shift",
        "left_option": "Left Option",
        "right_option": "Right Option",
        "left_control": "Left Control",
        "right_control": "Right Control",
        "caps_lock": "Caps Lock",
        "return": "Return",
        "escape": "Escape",
        "delete": "Delete",
        "space": "Space",
        "tab": "Tab",
    ]

    private static let modifierFlags: [String: CGEventFlags] = [
        "left_command": .maskCommand,
        "right_command": .maskCommand,
        "left_shift": .maskShift,
        "right_shift": .maskShift,
        "left_option": .maskAlternate,
        "right_option": .maskAlternate,
        "left_control": .maskControl,
        "right_control": .maskControl,
    ]

    private static let deviceFlags: [String: CGEventFlags] = [
        "left_control": CGEventFlags(rawValue: 0x1),
        "left_shift": CGEventFlags(rawValue: 0x2),
        "right_shift": CGEventFlags(rawValue: 0x4),
        "left_command": CGEventFlags(rawValue: 0x8),
        "right_command": CGEventFlags(rawValue: 0x10),
        "left_option": CGEventFlags(rawValue: 0x20),
        "right_option": CGEventFlags(rawValue: 0x40),
        "right_control": CGEventFlags(rawValue: 0x2000),
    ]
}

struct KeyChordConfig: Codable {
    var enabled: Bool
    var keys: [HotkeyKey]

    init(keys: [HotkeyKey], enabled: Bool = false) {
        self.enabled = enabled
        self.keys = keys
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case keys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        keys = try container.decodeIfPresent([HotkeyKey].self, forKey: .keys) ?? []
    }

    var isEnabled: Bool {
        enabled && !keys.isEmpty
    }

    var keyCodes: Set<CGKeyCode> {
        Set(keys.compactMap(\.keyCode))
    }

    var keysByCode: [CGKeyCode: HotkeyKey] {
        keys.reduce(into: [:]) { result, key in
            if let keyCode = key.keyCode {
                result[keyCode] = key
            }
        }
    }

    var hasRegularKey: Bool {
        keys.contains { !$0.isModifier }
    }

    var displayName: String {
        keys.map(\.displayName).joined(separator: " + ")
    }
}

struct HotkeyConfig: Codable {
    var control = true
    var option = true
    var command = false
    var shift = false

    init(control: Bool = true, option: Bool = true, command: Bool = false, shift: Bool = false) {
        self.control = control
        self.option = option
        self.command = command
        self.shift = shift
    }

    var displayName: String {
        var parts: [String] = []
        if control { parts.append("Control") }
        if command { parts.append("Command") }
        if option { parts.append("Option") }
        if shift { parts.append("Shift") }
        return parts.isEmpty ? "no modifiers" : parts.joined(separator: " + ")
    }

    func isPressed(in flags: CGEventFlags) -> Bool {
        let expected: [(Bool, CGEventFlags)] = [
            (control, .maskControl),
            (option, .maskAlternate),
            (command, .maskCommand),
            (shift, .maskShift),
        ]

        return expected.allSatisfy { required, flag in
            required == flags.contains(flag)
        }
    }
}
