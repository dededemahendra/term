import CoreGraphics
import CoreText
import Foundation
import Metal

public struct GlyphStyle: OptionSet, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let bold = GlyphStyle(rawValue: 1)
    public static let italic = GlyphStyle(rawValue: 2)
}

/// A glyph's place in the atlas, in pixels. Layout matches the shader.
public struct GlyphRect {
    public var x: UInt16
    public var y: UInt16
    public var w: UInt16
    public var h: UInt16
}

public struct GlyphRef: Equatable {
    /// Index into `GlyphAtlas.rects`. Zero is the blank glyph.
    public let index: UInt32
    /// True for glyphs that carry their own colour, such as emoji.
    public let isColor: Bool
}

/// Rasterises glyphs with CoreText into one RGBA texture, lazily.
/// Monochrome glyphs are white with coverage in alpha; the shader tints
/// them. Colour glyphs are stored as drawn.
public final class GlyphAtlas {
    private struct Key: Hashable {
        let codepoint: UInt32
        let style: GlyphStyle
        let wide: Bool
    }

    public let device: MTLDevice
    public let fontName: String
    public let pointSize: CGFloat
    public let scale: CGFloat
    public let cellWidth: Int
    public let cellHeight: Int
    /// Pixels from the bottom of a cell to the baseline.
    public let baseline: Int
    public private(set) var texture: MTLTexture
    public private(set) var rects: [GlyphRect] = [GlyphRect(x: 0, y: 0, w: 0, h: 0)]
    /// Bumped whenever `texture` is replaced by a larger one.
    public private(set) var generation = 0

    private let queue: MTLCommandQueue
    private let fonts: [GlyphStyle: CTFont]
    private var cache: [Key: GlyphRef] = [:]
    private var cursorX = 0
    private var cursorY = 0

    /// Resolves `name` or falls back to Menlo, reporting through `warn`.
    public static func resolveFont(name: String, size: CGFloat, warn: (String) -> Void) -> CTFont {
        let descriptor = CTFontDescriptorCreateWithNameAndSize(name as CFString, size)
        if CTFontDescriptorCreateMatchingFontDescriptor(descriptor, nil) != nil {
            return CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }
        warn("font \(name) not found, using Menlo")
        return CTFontCreateWithName("Menlo" as CFString, size, nil)
    }

    /// Cell size in pixels and baseline for a font, without a GPU.
    public static func metrics(fontName: String, pointSize: CGFloat, scale: CGFloat, lineHeight: CGFloat)
        -> (cellWidth: Int, cellHeight: Int, baseline: Int) {
        let base = resolveFont(name: fontName, size: pointSize * scale, warn: { _ in })
        return metrics(font: base, lineHeight: lineHeight)
    }

    private static func metrics(font base: CTFont, lineHeight: CGFloat) -> (cellWidth: Int, cellHeight: Int, baseline: Int) {
        let ascent = CTFontGetAscent(base)
        let descent = CTFontGetDescent(base)
        let leading = CTFontGetLeading(base)
        var zero: UniChar = 0x30
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(base, &zero, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(base, .horizontal, &glyph, &advance, 1)
        let cellWidth = max(1, Int(ceil(advance.width)))
        let natural = ascent + descent + leading
        let cellHeight = max(1, Int(ceil(natural * lineHeight)))
        let baseline = Int((descent + (CGFloat(cellHeight) - natural) / 2).rounded())
        return (cellWidth, cellHeight, baseline)
    }

    public init(device: MTLDevice, fontName: String, pointSize: CGFloat, scale: CGFloat, lineHeight: CGFloat,
                warn: (String) -> Void = { _ in }) {
        self.device = device
        self.fontName = fontName
        self.pointSize = pointSize
        self.scale = scale
        queue = device.makeCommandQueue()!
        let base = GlyphAtlas.resolveFont(name: fontName, size: pointSize * scale, warn: warn)
        func styled(_ traits: CTFontSymbolicTraits) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
        }
        fonts = [
            []: base,
            .bold: styled(.traitBold),
            .italic: styled(.traitItalic),
            [.bold, .italic]: styled([.traitBold, .traitItalic]),
        ]
        let m = GlyphAtlas.metrics(font: base, lineHeight: lineHeight)
        cellWidth = m.cellWidth
        cellHeight = m.cellHeight
        baseline = m.baseline
        texture = GlyphAtlas.makeTexture(device: device, size: 512)
    }

    private static func makeTexture(device: MTLDevice, size: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        texture.label = "glyph atlas \(size)"
        return texture
    }

    /// The glyph for `scalar` in `style`, rasterising on first sight.
    /// `wide` glyphs get a two cell slot.
    public func glyph(for scalar: Unicode.Scalar, style: GlyphStyle, wide: Bool) -> GlyphRef {
        if scalar == " " { return GlyphRef(index: 0, isColor: false) }
        let key = Key(codepoint: scalar.value, style: style, wide: wide)
        if let hit = cache[key] { return hit }
        let ref = rasterise(scalar, style: style, wide: wide)
        cache[key] = ref
        return ref
    }

    private func lookup(_ scalar: Unicode.Scalar, style: GlyphStyle) -> (CGGlyph, CTFont)? {
        let font = fonts[style] ?? fonts[[]]!
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        if CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count), glyphs[0] != 0 {
            return (glyphs[0], font)
        }
        let fallback = CTFontCreateForString(font, String(scalar) as CFString, CFRange(location: 0, length: units.count))
        if CTFontGetGlyphsForCharacters(fallback, &units, &glyphs, units.count), glyphs[0] != 0 {
            return (glyphs[0], fallback)
        }
        return nil
    }

    private func rasterise(_ scalar: Unicode.Scalar, style: GlyphStyle, wide: Bool) -> GlyphRef {
        guard var (glyph, font) = lookup(scalar, style: style) else {
            return GlyphRef(index: 0, isColor: false)
        }
        let slotWidth = cellWidth * (wide ? 2 : 1)
        var isColor = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        if wide && !isColor && advance.width < CGFloat(cellWidth) * 1.5 {
            // A two cell slot holding a narrow text glyph means the core saw
            // an emoji presentation selector: prefer the colour emoji font.
            let emojiFont = CTFontCreateWithName("Apple Color Emoji" as CFString, CTFontGetSize(font), nil)
            var units = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            if CTFontGetGlyphsForCharacters(emojiFont, &units, &glyphs, units.count), glyphs[0] != 0 {
                glyph = glyphs[0]
                font = emojiFont
                isColor = true
                CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            }
        }
        if advance.width > CGFloat(slotWidth) + 0.5 {
            // Shrink fallback glyphs (emoji) that do not fit the slot.
            let size = CTFontGetSize(font) * CGFloat(slotWidth) / advance.width
            font = CTFontCreateCopyWithAttributes(font, size, nil, nil)
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        }
        let width = slotWidth
        let height = cellHeight
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space, bitmapInfo: info) else { return }
            ctx.setAllowsFontSmoothing(false)
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            var position = CGPoint(x: max(0, (CGFloat(slotWidth) - advance.width) / 2), y: CGFloat(baseline))
            CTFontDrawGlyphs(font, &glyph, &position, 1, ctx)
        }
        let rect = place(width: width, height: height)
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(Int(rect.x), Int(rect.y), width, height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: width * 4)
        }
        rects.append(rect)
        return GlyphRef(index: UInt32(rects.count - 1), isColor: isColor)
    }

    /// Reserves a slot, moving to the next shelf or growing the texture.
    private func place(width: Int, height: Int) -> GlyphRect {
        if cursorX + width > texture.width {
            cursorX = 0
            cursorY += height
        }
        while cursorY + height > texture.height {
            grow()
        }
        let rect = GlyphRect(x: UInt16(cursorX), y: UInt16(cursorY), w: UInt16(width), h: UInt16(height))
        cursorX += width
        return rect
    }

    /// Doubles the texture, copying existing glyphs into the top left.
    private func grow() {
        let bigger = GlyphAtlas.makeTexture(device: device, size: texture.width * 2)
        let commands = queue.makeCommandBuffer()!
        let blit = commands.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: bigger, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        texture = bigger
        generation += 1
    }
}
