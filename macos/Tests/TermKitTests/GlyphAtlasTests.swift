import CoreText
import Metal
import XCTest
@testable import TermKit

final class GlyphAtlasTests: XCTestCase {
    private func makeAtlas() throws -> GlyphAtlas {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        return GlyphAtlas(device: device, fontName: "Menlo", pointSize: 13, scale: 2, lineHeight: 1)
    }

    private func inkedPixels(_ atlas: GlyphAtlas, _ rect: GlyphRect) -> Int {
        let w = Int(rect.w), h = Int(rect.h)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { raw in
            atlas.texture.getBytes(raw.baseAddress!, bytesPerRow: w * 4,
                                   from: MTLRegionMake2D(Int(rect.x), Int(rect.y), w, h), mipmapLevel: 0)
        }
        return stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 }.count
    }

    func testMetricsAreSensible() throws {
        let atlas = try makeAtlas()
        XCTAssertGreaterThan(atlas.cellWidth, 8)
        XCTAssertGreaterThan(atlas.cellHeight, atlas.cellWidth)
        XCTAssertGreaterThan(atlas.baseline, 0)
        XCTAssertLessThan(atlas.baseline, atlas.cellHeight)
        let m = GlyphAtlas.metrics(fontName: "Menlo", pointSize: 13, scale: 2, lineHeight: 1)
        XCTAssertEqual(m.cellWidth, atlas.cellWidth)
        XCTAssertEqual(m.cellHeight, atlas.cellHeight)
    }

    func testGlyphIsRasterisedOnceAndInked() throws {
        let atlas = try makeAtlas()
        let m = atlas.glyph(for: "M", style: [], wide: false)
        XCTAssertNotEqual(m.index, 0)
        XCTAssertFalse(m.isColor)
        XCTAssertGreaterThan(inkedPixels(atlas, atlas.rects[Int(m.index)]), 50)
        XCTAssertEqual(atlas.glyph(for: "M", style: [], wide: false), m)
        XCTAssertNotEqual(atlas.glyph(for: "M", style: .bold, wide: false).index, m.index)
        XCTAssertEqual(atlas.glyph(for: " ", style: [], wide: false).index, 0)
    }

    func testEmojiIsColourAndWide() throws {
        let atlas = try makeAtlas()
        let thumbs = atlas.glyph(for: "\u{1F44D}", style: [], wide: true)
        XCTAssertTrue(thumbs.isColor)
        let rect = atlas.rects[Int(thumbs.index)]
        XCTAssertEqual(Int(rect.w), atlas.cellWidth * 2)
        XCTAssertGreaterThan(inkedPixels(atlas, rect), 100)
        let heart = atlas.glyph(for: "\u{2764}", style: [], wide: true)
        XCTAssertTrue(heart.isColor, "a two cell text glyph should use the emoji font")
        let cjk = atlas.glyph(for: "\u{65E5}", style: [], wide: true)
        XCTAssertFalse(cjk.isColor)
        XCTAssertEqual(Int(atlas.rects[Int(cjk.index)].w), atlas.cellWidth * 2)
    }

    func testUnknownFontFallsBackToMenloWithWarning() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        var warnings: [String] = []
        let atlas = GlyphAtlas(device: device, fontName: "No Such Font 123", pointSize: 13, scale: 2, lineHeight: 1,
                               warn: { warnings.append($0) })
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(atlas.cellWidth, GlyphAtlas.metrics(fontName: "Menlo", pointSize: 13, scale: 2, lineHeight: 1).cellWidth)
    }

    func testAtlasGrowsAndKeepsOldGlyphs() throws {
        let atlas = try makeAtlas()
        let first = atlas.glyph(for: "M", style: [], wide: false)
        let before = inkedPixels(atlas, atlas.rects[Int(first.index)])
        let startGeneration = atlas.generation
        for cp in 0x4E00..<(0x4E00 + 700) {
            _ = atlas.glyph(for: Unicode.Scalar(cp)!, style: [], wide: true)
        }
        XCTAssertGreaterThan(atlas.generation, startGeneration)
        XCTAssertEqual(inkedPixels(atlas, atlas.rects[Int(first.index)]), before)
    }

    func testAtlasStopsGrowingAtItsCapAndDrawsBlanks() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let atlas = GlyphAtlas(device: device, fontName: "Menlo", pointSize: 13, scale: 2, lineHeight: 1, maxTextureSize: 512)
        let first = atlas.glyph(for: "M", style: [], wide: false)
        var blanks = 0
        for cp in 0x4E00..<(0x4E00 + 400) where atlas.glyph(for: Unicode.Scalar(cp)!, style: [], wide: true).index == 0 {
            blanks += 1
        }
        XCTAssertEqual(atlas.generation, 0)
        XCTAssertEqual(atlas.texture.width, 512)
        XCTAssertGreaterThan(blanks, 0)
        XCTAssertEqual(atlas.glyph(for: "M", style: [], wide: false).index, first.index, "cached glyphs still resolve")
    }

    func testNerdFontFallbackRendersIconGlyphsWithoutConfig() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let families = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        guard families.contains(where: { $0.range(of: "Nerd Font", options: .caseInsensitive) != nil }) else {
            throw XCTSkip("no Nerd Font installed on this machine")
        }
        // Menlo lacks the powerline separator U+E0B0, and the system cascade has
        // no font for private-use icons, so only the Nerd Font fallback resolves it.
        let atlas = GlyphAtlas(device: device, fontName: "Menlo", pointSize: 13, scale: 2, lineHeight: 1)
        let ref = atlas.glyph(for: Unicode.Scalar(0xE0B0)!, style: [], wide: false)
        XCTAssertNotEqual(ref.index, 0, "index 0 is the blank sentinel; a non-zero index means the glyph rasterised")
    }
}
