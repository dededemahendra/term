import Metal
import XCTest
@testable import TermKit

final class RendererTests: XCTestCase {
    private struct Scene {
        let terminal: Terminal
        let renderer: Renderer
        let atlas: GlyphAtlas
        let width: Int
        let height: Int
        let padding: Int
        func pixel(col: Int, row: Int, _ frame: [UInt8]) -> (r: UInt8, g: UInt8, b: UInt8) {
            let x = padding + col * atlas.cellWidth + atlas.cellWidth / 2
            let y = padding + row * atlas.cellHeight + atlas.cellHeight / 2
            let i = (y * width + x) * 4
            return (frame[i + 2], frame[i + 1], frame[i])
        }
    }

    private func makeScene(cols: Int = 6, rows: Int = 2) throws -> Scene {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        var config = Config()
        config.background = RGB(0, 0, 200)
        config.foreground = RGB(200, 200, 200)
        config.cursorColor = RGB(255, 255, 0)
        config.selectionBackground = RGB(0, 120, 0)
        let atlas = GlyphAtlas(device: device, fontName: "Menlo", pointSize: 13, scale: 2, lineHeight: 1)
        let padding = 4
        let renderer = try Renderer(device: device, pixelFormat: .bgra8Unorm, atlas: atlas, palette: Palette(config: config),
                                    paddingPixels: Float(padding))
        let terminal = Terminal(cols: cols, rows: rows, scrollback: 0)
        return Scene(terminal: terminal, renderer: renderer, atlas: atlas,
                     width: padding * 2 + cols * atlas.cellWidth, height: padding * 2 + rows * atlas.cellHeight, padding: padding)
    }

    private func frame(_ s: Scene) -> [UInt8] {
        s.renderer.update(from: s.terminal)
        return s.renderer.renderOffscreen(width: s.width, height: s.height)
    }

    func testBackgroundAndInverseCells() throws {
        let s = try makeScene()
        s.terminal.feed(Array("\u{1B}[7m \u{1B}[0m\u{1B}[41m \u{1B}[0m\u{1B}[3;1H".utf8))
        s.terminal.feed(Array("\u{1B}[1;6H".utf8))
        let f = frame(s)
        let empty = s.pixel(col: 4, row: 1, f)
        XCTAssertEqual([empty.r, empty.g, empty.b], [0, 0, 200])
        let inverse = s.pixel(col: 0, row: 0, f)
        XCTAssertEqual([inverse.r, inverse.g, inverse.b], [200, 200, 200])
        let red = s.pixel(col: 1, row: 0, f)
        XCTAssertEqual([red.r, red.g, red.b], [205, 0, 0])
    }

    func testBlockCursorAndSelectionColours() throws {
        let s = try makeScene()
        s.terminal.feed(Array("ab".utf8))
        var f = frame(s)
        let cursor = s.pixel(col: 2, row: 0, f)
        XCTAssertEqual([cursor.r, cursor.g, cursor.b], [255, 255, 0])
        s.terminal.selectionStart(col: 0, row: 1, mode: .normal)
        f = frame(s)
        let selected = s.pixel(col: 0, row: 1, f)
        XCTAssertEqual([selected.r, selected.g, selected.b], [0, 120, 0])
    }

    func testGlyphInksTheCell() throws {
        let s = try makeScene()
        s.terminal.feed(Array("\u{2588}\u{1B}[6;1H".utf8))
        let f = frame(s)
        let block = s.pixel(col: 0, row: 0, f)
        XCTAssertEqual([block.r, block.g, block.b], [200, 200, 200])
    }

    func testWideGlyphHidesSpacerCell() throws {
        let s = try makeScene()
        s.terminal.feed(Array("\u{1B}[42m\u{65E5}\u{1B}[0m\u{1B}[2;1H".utf8))
        let f = frame(s)
        let spacer = s.pixel(col: 1, row: 0, f)
        XCTAssertNotEqual([spacer.r, spacer.g, spacer.b], [0, 0, 200], "the wide glyph covers its second cell")
    }
}
