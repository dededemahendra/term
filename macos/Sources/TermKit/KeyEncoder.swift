import CTermCore
import Foundation

public struct KeyModifiers: OptionSet, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1)
    public static let control = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)
}

/// The parts of a key event the encoder needs, so it can be tested
/// without constructing AppKit events.
public struct KeyInput: Equatable {
    public var characters: String
    public var charactersIgnoringModifiers: String
    public var keyCode: UInt16
    public var modifiers: KeyModifiers

    public init(characters: String, charactersIgnoringModifiers: String, keyCode: UInt16, modifiers: KeyModifiers = []) {
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// macOS virtual key codes the terminal maps itself.
public enum KeyCode {
    public static let returnKey: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let backspace: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let keypadEnter: UInt16 = 76
    public static let forwardDelete: UInt16 = 117
    public static let home: UInt16 = 115
    public static let end: UInt16 = 119
    public static let pageUp: UInt16 = 116
    public static let pageDown: UInt16 = 121
    public static let left: UInt16 = 123
    public static let right: UInt16 = 124
    public static let down: UInt16 = 125
    public static let up: UInt16 = 126
    public static let f1: UInt16 = 122
    public static let f2: UInt16 = 120
    public static let f3: UInt16 = 99
    public static let f4: UInt16 = 118
    public static let f5: UInt16 = 96
    public static let f6: UInt16 = 97
    public static let f7: UInt16 = 98
    public static let f8: UInt16 = 100
    public static let f9: UInt16 = 101
    public static let f10: UInt16 = 109
    public static let f11: UInt16 = 103
    public static let f12: UInt16 = 111
}

public enum KeyEncoder {
    private static let esc: UInt8 = 0x1B

    /// Bytes for keys the terminal handles itself, or nil when the event
    /// is ordinary text that should go through the text input system.
    public static func encode(_ key: KeyInput, modes: TermModes, altIsMeta: Bool) -> [UInt8]? {
        let m = key.modifiers
        let modParam = 1 + (m.contains(.shift) ? 1 : 0) + (m.contains(.option) ? 2 : 0) + (m.contains(.control) ? 4 : 0)
        let meta = m.contains(.option) && altIsMeta

        if m.contains(.command) {
            return nil
        }

        func arrow(_ final: String) -> [UInt8] {
            if modParam > 1 { return Array("\u{1B}[1;\(modParam)\(final)".utf8) }
            return Array((modes.app_cursor ? "\u{1B}O" : "\u{1B}[").utf8) + Array(final.utf8)
        }
        func tilde(_ n: Int) -> [UInt8] {
            if modParam > 1 { return Array("\u{1B}[\(n);\(modParam)~".utf8) }
            return Array("\u{1B}[\(n)~".utf8)
        }
        func ss3(_ final: String) -> [UInt8] {
            if modParam > 1 { return Array("\u{1B}[1;\(modParam)\(final)".utf8) }
            return Array("\u{1B}O\(final)".utf8)
        }
        func withMeta(_ bytes: [UInt8]) -> [UInt8] {
            meta ? [esc] + bytes : bytes
        }

        switch key.keyCode {
        case KeyCode.up: return arrow("A")
        case KeyCode.down: return arrow("B")
        case KeyCode.right: return arrow("C")
        case KeyCode.left: return arrow("D")
        case KeyCode.home: return arrow("H")
        case KeyCode.end: return arrow("F")
        case KeyCode.pageUp: return tilde(5)
        case KeyCode.pageDown: return tilde(6)
        case KeyCode.forwardDelete: return tilde(3)
        case KeyCode.f1: return ss3("P")
        case KeyCode.f2: return ss3("Q")
        case KeyCode.f3: return ss3("R")
        case KeyCode.f4: return ss3("S")
        case KeyCode.f5: return tilde(15)
        case KeyCode.f6: return tilde(17)
        case KeyCode.f7: return tilde(18)
        case KeyCode.f8: return tilde(19)
        case KeyCode.f9: return tilde(20)
        case KeyCode.f10: return tilde(21)
        case KeyCode.f11: return tilde(23)
        case KeyCode.f12: return tilde(24)
        case KeyCode.returnKey, KeyCode.keypadEnter: return withMeta([0x0D])
        case KeyCode.tab: return m.contains(.shift) ? Array("\u{1B}[Z".utf8) : withMeta([0x09])
        case KeyCode.escape: return [esc]
        case KeyCode.backspace: return withMeta([0x7F])
        default: break
        }

        let base = key.charactersIgnoringModifiers
        if m.contains(.control), let scalar = base.unicodeScalars.first {
            let c = scalar.value
            switch scalar {
            case "a"..."z": return withMeta([UInt8(c - 96)])
            case "A"..."Z": return withMeta([UInt8(c - 64)])
            case "[", "3": return withMeta([0x1B])
            case "\\", "4": return withMeta([0x1C])
            case "]", "5": return withMeta([0x1D])
            case "^", "6": return withMeta([0x1E])
            case "_", "-", "7", "/": return withMeta([0x1F])
            case " ", "2", "@": return withMeta([0x00])
            case "?", "8": return withMeta([0x7F])
            default: return nil
            }
        }
        if meta, !base.isEmpty {
            return [esc] + Array(base.utf8)
        }
        return nil
    }
}
