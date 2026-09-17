import XCTest
@testable import TermKit

final class TerminalSessionTests: XCTestCase {
    private func rowText(_ terminal: Terminal, row: Int) -> String {
        var cells: [UInt64] = []
        terminal.copyGrid(into: &cells)
        let cols = terminal.cols
        let scalars = cells[(row * cols)..<((row + 1) * cols)].map { Cell(raw: $0).scalar }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    func testMissingProgramPrintsTheErrorIntoTheGrid() throws {
        let session = try TerminalSession(config: Config(), command: ["/nonexistent/program"], cols: 100, rows: 4)
        let shown = expectation(description: "message rendered")
        var fulfilled = false
        session.onOutput = { [terminal = session.terminal] in
            if !fulfilled, self.rowText(terminal, row: 0).contains("Press any key") {
                fulfilled = true
                shown.fulfill()
            }
        }
        session.start()
        wait(for: [shown], timeout: 5)
        let line = rowText(session.terminal, row: 0)
        XCTAssertTrue(line.contains("could not start /nonexistent/program"), line)
        XCTAssertTrue(line.contains("No such file or directory"), line)
        let exited = expectation(description: "exit on key")
        session.onExit = { exited.fulfill() }
        session.write("x")
        wait(for: [exited], timeout: 5)
    }

    func testPasteTextNormalisesNewlinesAndBrackets() {
        XCTAssertEqual(TerminalSession.pasteText("a\r\nb\nc", bracketed: false), "a\rb\rc")
        XCTAssertEqual(TerminalSession.pasteText("x\n", bracketed: true), "\u{1B}[200~x\r\u{1B}[201~")
    }
}
