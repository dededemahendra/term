import CTermCore
import XCTest
@testable import TermKit

final class PaletteTests: XCTestCase {
    func testXterm256Formula() {
        XCTAssertEqual(Palette.xterm256(16), RGB(0, 0, 0))
        XCTAssertEqual(Palette.xterm256(21), RGB(0, 0, 255))
        XCTAssertEqual(Palette.xterm256(231), RGB(255, 255, 255))
        XCTAssertEqual(Palette.xterm256(232), RGB(8, 8, 8))
        XCTAssertEqual(Palette.xterm256(255), RGB(238, 238, 238))
    }

    func testPackingAndResolution() {
        var config = Config()
        config.foreground = RGB(1, 2, 3)
        config.background = RGB(4, 5, 6)
        config.palette[1] = RGB(9, 9, 9)
        let p = Palette(config: config)
        XCTAssertEqual(p.resolve(Cell.defaultColor, overflow: [], isForeground: true), 0xFF03_0201)
        XCTAssertEqual(p.resolve(Cell.defaultColor, overflow: [], isForeground: false), 0xFF06_0504)
        XCTAssertEqual(p.resolve(1, overflow: [], isForeground: true), 0xFF09_0909)
        XCTAssertEqual(p.resolve(21, overflow: [], isForeground: true), 0xFFFF_0000)
        let overflow = [TermRgb(r: 10, g: 20, b: 30)]
        XCTAssertEqual(p.resolve(256, overflow: overflow, isForeground: true), 0xFF1E_140A)
        XCTAssertEqual(p.resolve(257, overflow: overflow, isForeground: false), p.background)
    }
}
