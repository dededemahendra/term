import XCTest
@testable import TermKit

final class ConfigTests: XCTestCase {
    func testDefaults() {
        let c = Config()
        XCTAssertEqual(c.font, "Menlo")
        XCTAssertEqual(c.fontSize, 13)
        XCTAssertEqual(c.scrollback, 10_000)
        XCTAssertEqual(c.padding, 8)
        XCTAssertEqual(c.cursorStyle, .block)
        XCTAssertFalse(c.cursorBlink)
        XCTAssertNil(c.shell)
        XCTAssertTrue(c.altIsMeta)
        XCTAssertFalse(c.copyOnSelect)
        XCTAssertEqual(c.palette.count, 16)
        XCTAssertEqual(c.palette[1], RGB(205, 0, 0))
    }

    func testParsesEveryKey() {
        let text = """
        # comment
        font = Fira Code
        font-size = 15
        line-height = 1.2
        shell = /bin/bash
        scrollback = 500
        padding = 4
        cursor-style = bar  # trailing comment
        cursor-blink = true
        cursor-color = #ff0000
        foreground = #ffffff
        background = 000000
        selection-background = #123456
        color3 = #010203
        alt-is-meta = no
        copy-on-select = yes
        """
        var warnings: [String] = []
        let c = Config.parse(text, warn: { warnings.append($0) })
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(c.font, "Fira Code")
        XCTAssertEqual(c.fontSize, 15)
        XCTAssertEqual(c.lineHeight, 1.2)
        XCTAssertEqual(c.shell, "/bin/bash")
        XCTAssertEqual(c.scrollback, 500)
        XCTAssertEqual(c.padding, 4)
        XCTAssertEqual(c.cursorStyle, .bar)
        XCTAssertTrue(c.cursorBlink)
        XCTAssertEqual(c.cursorColor, RGB(255, 0, 0))
        XCTAssertEqual(c.foreground, RGB(255, 255, 255))
        XCTAssertEqual(c.background, RGB(0, 0, 0))
        XCTAssertEqual(c.selectionBackground, RGB(0x12, 0x34, 0x56))
        XCTAssertEqual(c.palette[3], RGB(1, 2, 3))
        XCTAssertFalse(c.altIsMeta)
        XCTAssertTrue(c.copyOnSelect)
    }

    func testUnknownKeysAndBadValuesWarnAndKeepDefaults() {
        var warnings: [String] = []
        let c = Config.parse("colour = red\nfont-size = huge\nscrollback = -1\ncolor16 = #000000\nnonsense\n",
                             warn: { warnings.append($0) })
        XCTAssertEqual(warnings.count, 5)
        XCTAssertEqual(c.fontSize, 13)
        XCTAssertEqual(c.scrollback, 10_000)
        XCTAssertTrue(warnings[4].contains("expected key = value"))
    }

    func testHexValueWithTrailingComment() {
        var warnings: [String] = []
        let c = Config.parse("foreground = #ffffff # note\nbackground=#000000#dark\n", warn: { warnings.append($0) })
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(c.foreground, RGB(255, 255, 255))
        XCTAssertEqual(c.background, RGB(0, 0, 0))
    }

    func testMissingFileGivesDefaults() {
        XCTAssertEqual(Config.load(path: "/nonexistent/term/config"), Config())
    }

    func testHexParsing() {
        XCTAssertEqual(RGB(hex: "#0A0b0C"), RGB(10, 11, 12))
        XCTAssertNil(RGB(hex: "#12345"))
        XCTAssertNil(RGB(hex: "zzzzzz"))
    }
}
