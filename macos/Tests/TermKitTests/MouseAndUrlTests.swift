import XCTest
@testable import TermKit

final class MouseEncoderTests: XCTestCase {
    func testSgrEncoding() {
        XCTAssertEqual(MouseEncoder.encode(button: .left, col: 0, row: 0, pressed: true, motion: false, modifiers: [], sgr: true),
                       Array("\u{1B}[<0;1;1M".utf8))
        XCTAssertEqual(MouseEncoder.encode(button: .left, col: 9, row: 4, pressed: false, motion: false, modifiers: [], sgr: true),
                       Array("\u{1B}[<0;10;5m".utf8))
        XCTAssertEqual(MouseEncoder.encode(button: .right, col: 0, row: 0, pressed: true, motion: false, modifiers: [.control], sgr: true),
                       Array("\u{1B}[<18;1;1M".utf8))
        XCTAssertEqual(MouseEncoder.encode(button: .left, col: 3, row: 3, pressed: true, motion: true, modifiers: [], sgr: true),
                       Array("\u{1B}[<32;4;4M".utf8))
        XCTAssertEqual(MouseEncoder.encode(button: .wheelUp, col: 0, row: 0, pressed: true, motion: false, modifiers: [], sgr: true),
                       Array("\u{1B}[<64;1;1M".utf8))
    }

    func testLegacyEncoding() {
        XCTAssertEqual(MouseEncoder.encode(button: .left, col: 0, row: 0, pressed: true, motion: false, modifiers: [], sgr: false),
                       [0x1B, 0x5B, 0x4D, 32, 33, 33])
        XCTAssertEqual(MouseEncoder.encode(button: .left, col: 0, row: 0, pressed: false, motion: false, modifiers: [], sgr: false),
                       [0x1B, 0x5B, 0x4D, 35, 33, 33])
        XCTAssertEqual(MouseEncoder.encode(button: .middle, col: 5, row: 2, pressed: true, motion: false, modifiers: [.shift], sgr: false),
                       [0x1B, 0x5B, 0x4D, 37, 38, 35])
        XCTAssertEqual(MouseEncoder.encode(button: .left, col: 300, row: 0, pressed: true, motion: false, modifiers: [], sgr: false), [])
    }

    func testWheelIsAlwaysAPress() {
        XCTAssertEqual(MouseEncoder.encode(button: .wheelDown, col: 0, row: 0, pressed: false, motion: false, modifiers: [], sgr: true),
                       Array("\u{1B}[<65;1;1M".utf8))
        XCTAssertEqual(MouseEncoder.encode(button: .wheelUp, col: 0, row: 0, pressed: false, motion: false, modifiers: [], sgr: false),
                       [0x1B, 0x5B, 0x4D, 96, 33, 33])
    }
}

final class UrlDetectorTests: XCTestCase {
    func testFindsUrlUnderColumn() {
        let line = "see https://example.com/a?b=1. now"
        XCTAssertEqual(UrlDetector.url(in: line, at: 10), "https://example.com/a?b=1")
        XCTAssertEqual(UrlDetector.url(in: line, at: 4), "https://example.com/a?b=1")
        XCTAssertNil(UrlDetector.url(in: line, at: 1))
        XCTAssertNil(UrlDetector.url(in: line, at: 3))
        XCTAssertNil(UrlDetector.url(in: line, at: 99))
    }

    func testBracketsAndSchemes() {
        XCTAssertEqual(UrlDetector.url(in: "(https://x.y/z)", at: 5), "https://x.y/z")
        XCTAssertEqual(UrlDetector.url(in: "https://en.wikipedia.org/wiki/Foo_(bar)", at: 5), "https://en.wikipedia.org/wiki/Foo_(bar)")
        XCTAssertEqual(UrlDetector.url(in: "\"file:///tmp/a.txt\"", at: 3), "file:///tmp/a.txt")
        XCTAssertNil(UrlDetector.url(in: "not a url", at: 2))
        XCTAssertNil(UrlDetector.url(in: "1://bad", at: 2))
    }
}
