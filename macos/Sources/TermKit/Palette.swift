import CTermCore
import Foundation

/// Resolves cell colour indices to packed RGBA8 for the renderer.
/// Packed layout is `r | g << 8 | b << 16 | a << 24`.
public struct Palette {
    public private(set) var packed: [UInt32]
    public let foreground: UInt32
    public let background: UInt32
    public let selectionBackground: UInt32
    public let cursorColor: UInt32

    public init(config: Config) {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<16 {
            table[i] = Palette.pack(config.palette[i])
        }
        for i in 16..<256 {
            table[i] = Palette.pack(Palette.xterm256(i))
        }
        packed = table
        foreground = Palette.pack(config.foreground)
        background = Palette.pack(config.background)
        selectionBackground = Palette.pack(config.selectionBackground)
        cursorColor = Palette.pack(config.cursorColor)
    }

    public static func pack(_ c: RGB) -> UInt32 {
        UInt32(c.r) | UInt32(c.g) << 8 | UInt32(c.b) << 16 | 0xFF00_0000
    }

    public static func pack(_ c: TermRgb) -> UInt32 {
        UInt32(c.r) | UInt32(c.g) << 8 | UInt32(c.b) << 16 | 0xFF00_0000
    }

    /// The xterm 256 colour formula for indices 16 to 255.
    public static func xterm256(_ index: Int) -> RGB {
        if index < 16 { return Config.xtermPalette[index] }
        if index < 232 {
            let i = index - 16
            func cube(_ v: Int) -> UInt8 { v == 0 ? 0 : UInt8(55 + v * 40) }
            return RGB(cube(i / 36), cube((i % 36) / 6), cube(i % 6))
        }
        let v = UInt8(8 + (index - 232) * 10)
        return RGB(v, v, v)
    }

    /// Resolves a cell colour index. `overflow` is the core's interned
    /// 24-bit table, index 256 upward.
    public func resolve(_ index: UInt16, overflow: [TermRgb], isForeground: Bool) -> UInt32 {
        if index == Cell.defaultColor {
            return isForeground ? foreground : background
        }
        if index < 256 {
            return packed[Int(index)]
        }
        let i = Int(index) - 256
        if i < overflow.count {
            return Palette.pack(overflow[i])
        }
        return isForeground ? foreground : background
    }
}
