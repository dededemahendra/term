import Foundation

public enum MouseButton: Int {
    case left = 0
    case middle = 1
    case right = 2
    case wheelUp = 64
    case wheelDown = 65
}

/// Encodes mouse reports for programs that enabled mouse tracking.
public enum MouseEncoder {
    /// `motion` marks a drag report (modes 1002 and 1003). `sgr` selects the
    /// 1006 encoding; otherwise the legacy byte encoding is used, which
    /// cannot express coordinates past column or row 223 and returns
    /// nothing for them.
    public static func encode(button: MouseButton, col: Int, row: Int, pressed: Bool, motion: Bool,
                              modifiers: KeyModifiers, sgr: Bool) -> [UInt8] {
        var code = button.rawValue
        if modifiers.contains(.shift) { code += 4 }
        if modifiers.contains(.option) { code += 8 }
        if modifiers.contains(.control) { code += 16 }
        if motion { code += 32 }
        if sgr {
            return Array("\u{1B}[<\(code);\(col + 1);\(row + 1)\(pressed ? "M" : "m")".utf8)
        }
        if !pressed {
            code = (code & ~3) | 3
        }
        let x = col + 33
        let y = row + 33
        guard x <= 255, y <= 255 else { return [] }
        return [0x1B, 0x5B, 0x4D, UInt8(32 + code), UInt8(x), UInt8(y)]
    }
}
