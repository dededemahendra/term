import Foundation

public struct RGB: Equatable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Parses `#rrggbb` or `rrggbb`.
    public init?(hex: String) {
        var s = Substring(hex.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF))
    }
}

public enum CursorStyle: String {
    case block
    case bar
    case underline
}

/// Settings from `~/.config/term/config`, a flat `key = value` file.
public struct Config: Equatable {
    public var font = "Menlo"
    public var fontSize = 13.0
    public var lineHeight = 1.0
    /// Nil means the login shell from `SHELL`.
    public var shell: String? = nil
    public var scrollback = 10_000
    public var padding = 8.0
    public var cursorStyle = CursorStyle.block
    public var cursorBlink = false
    public var cursorColor = RGB(255, 255, 255)
    public var foreground = RGB(0xD0, 0xD0, 0xD0)
    public var background = RGB(0, 0, 0)
    public var selectionBackground = RGB(0x44, 0x44, 0x44)
    public var palette = Config.xtermPalette
    public var altIsMeta = true
    public var copyOnSelect = false

    public init() {}

    public static let xtermPalette: [RGB] = [
        RGB(0, 0, 0), RGB(205, 0, 0), RGB(0, 205, 0), RGB(205, 205, 0),
        RGB(0, 0, 238), RGB(205, 0, 205), RGB(0, 205, 205), RGB(229, 229, 229),
        RGB(127, 127, 127), RGB(255, 0, 0), RGB(0, 255, 0), RGB(255, 255, 0),
        RGB(92, 92, 255), RGB(255, 0, 255), RGB(0, 255, 255), RGB(255, 255, 255),
    ]

    public static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.config/term/config"
    }

    /// Loads the file at `path`; a missing file gives the defaults.
    public static func load(path: String = Config.defaultPath, warn: (String) -> Void = { _ in }) -> Config {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return Config() }
        return parse(text, warn: warn)
    }

    public static func parse(_ text: String, warn: (String) -> Void = { _ in }) -> Config {
        var config = Config()
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") { continue }
            guard let eq = trimmedLine.firstIndex(of: "=") else {
                warn("config line \(index + 1): expected key = value")
                continue
            }
            let key = trimmedLine[..<eq].trimmingCharacters(in: .whitespaces)
            var value = trimmedLine[trimmedLine.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // A "#" starts a trailing comment, but not when it opens the value itself
            // (hex colours are written "#rrggbb").
            if let hashIndex = value.firstIndex(of: "#"), hashIndex > value.startIndex {
                value = value[..<hashIndex].trimmingCharacters(in: .whitespaces)
            }
            if !config.apply(key: key, value: value) {
                warn("config line \(index + 1): ignored \(key) = \(value)")
            }
        }
        return config
    }

    private static func bool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    /// Returns false for an unknown key or an unusable value.
    private mutating func apply(key: String, value: String) -> Bool {
        switch key {
        case "font":
            guard !value.isEmpty else { return false }
            font = value
        case "font-size":
            guard let v = Double(value), v >= 4, v <= 200 else { return false }
            fontSize = v
        case "line-height":
            guard let v = Double(value), v >= 0.5, v <= 3 else { return false }
            lineHeight = v
        case "shell":
            guard !value.isEmpty else { return false }
            shell = value
        case "scrollback":
            guard let v = Int(value), v >= 0, v <= 1_000_000 else { return false }
            scrollback = v
        case "padding":
            guard let v = Double(value), v >= 0, v <= 200 else { return false }
            padding = v
        case "cursor-style":
            guard let v = CursorStyle(rawValue: value) else { return false }
            cursorStyle = v
        case "cursor-blink":
            guard let v = Config.bool(value) else { return false }
            cursorBlink = v
        case "cursor-color":
            guard let v = RGB(hex: value) else { return false }
            cursorColor = v
        case "foreground":
            guard let v = RGB(hex: value) else { return false }
            foreground = v
        case "background":
            guard let v = RGB(hex: value) else { return false }
            background = v
        case "selection-background":
            guard let v = RGB(hex: value) else { return false }
            selectionBackground = v
        case "alt-is-meta":
            guard let v = Config.bool(value) else { return false }
            altIsMeta = v
        case "copy-on-select":
            guard let v = Config.bool(value) else { return false }
            copyOnSelect = v
        default:
            guard key.hasPrefix("color"), let n = Int(key.dropFirst(5)), (0..<16).contains(n),
                  let v = RGB(hex: value) else { return false }
            palette[n] = v
        }
        return true
    }
}
