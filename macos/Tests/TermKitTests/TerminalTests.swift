import XCTest
@testable import TermKit

final class TerminalTests: XCTestCase {
    func testFeedGridCursorAndAttributes() {
        let t = Terminal(cols: 10, rows: 3, scrollback: 5)
        t.feed(Array("hi\u{1B}[1;31mX".utf8))
        var cells: [UInt64] = []
        t.copyGrid(into: &cells)
        XCTAssertEqual(cells.count, 30)
        XCTAssertEqual(Cell(raw: cells[0]).scalar, "h")
        XCTAssertEqual(Cell(raw: cells[2]).flags, .bold)
        XCTAssertEqual(Cell(raw: cells[2]).fg, 1)
        XCTAssertEqual(Cell(raw: cells[2]).bg, Cell.defaultColor)
        XCTAssertEqual(t.cursor.col, 3)
        XCTAssertTrue(t.cursor.visible)
    }

    func testDirtyRowsClearAfterTake() {
        let t = Terminal(cols: 4, rows: 2, scrollback: 0)
        var words: [UInt64] = []
        t.takeDirtyRows(into: &words)
        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words[0] & 0b11, 0b11)
        t.takeDirtyRows(into: &words)
        XCTAssertEqual(words[0], 0)
        t.feed(Array("x".utf8))
        t.takeDirtyRows(into: &words)
        XCTAssertEqual(words[0] & 0b11, 0b01)
    }

    func testModesResponsesAndTitle() {
        let t = Terminal(cols: 5, rows: 2, scrollback: 0)
        t.feed(Array("\u{1B}[?2004h\u{1B}[6n\u{1B}]0;Hello\u{07}".utf8))
        XCTAssertTrue(t.modes.bracketed_paste)
        XCTAssertEqual(t.drainResponses(), Array("\u{1B}[1;1R".utf8))
        XCTAssertEqual(t.drainResponses(), [])
        XCTAssertEqual(t.title, "Hello")
    }

    func testSelectionUsesVisibleRowsAndRejectsOutOfRange() {
        let t = Terminal(cols: 5, rows: 2, scrollback: 5)
        t.feed(Array("a\r\nb\r\nc".utf8))
        t.scrollViewport(by: 1)
        XCTAssertTrue(t.selectionStart(col: 0, row: 0, mode: .normal))
        XCTAssertTrue(t.selectionExtend(col: 0, row: 1))
        XCTAssertEqual(t.selectionText, "a\nb")
        XCTAssertFalse(t.selectionStart(col: 50, row: 0, mode: .normal))
        XCTAssertFalse(t.selectionExtend(col: 0, row: 9))
        var cells: [UInt64] = []
        t.copyGrid(into: &cells)
        XCTAssertTrue(Cell(raw: cells[0]).selected)
        XCTAssertFalse(t.cursor.visible)
        t.selectionClear()
        XCTAssertEqual(t.selectionText, "")
    }

    func testResizeAndOverflowColours() {
        let t = Terminal(cols: 4, rows: 2, scrollback: 2)
        t.feed(Array("\u{1B}[38;2;1;2;3mX".utf8))
        XCTAssertEqual(t.overflowColors.count, 1)
        XCTAssertEqual(t.overflowColors[0].r, 1)
        t.resize(cols: 8, rows: 3)
        XCTAssertEqual(t.cols, 8)
        XCTAssertEqual(t.rows, 3)
        var cells: [UInt64] = []
        t.copyGrid(into: &cells)
        XCTAssertEqual(cells.count, 24)
        XCTAssertEqual(t.dirtyWordCount, 1)
    }
}
