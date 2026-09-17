import CTermCore
import XCTest
@testable import TermKit

final class KeyEncoderTests: XCTestCase {
    private func key(_ chars: String, code: UInt16 = 0, _ mods: KeyModifiers = [], base: String? = nil) -> KeyInput {
        KeyInput(characters: chars, charactersIgnoringModifiers: base ?? chars, keyCode: code, modifiers: mods)
    }

    private func encode(_ input: KeyInput, appCursor: Bool = false, altIsMeta: Bool = true) -> [UInt8]? {
        var modes = TermModes()
        modes.app_cursor = appCursor
        return KeyEncoder.encode(input, modes: modes, altIsMeta: altIsMeta)
    }

    func testPlainTextGoesToTextInput() {
        XCTAssertNil(encode(key("a")))
        XCTAssertNil(encode(key("A", [.shift])))
        XCTAssertNil(encode(key("n", [.command])))
        XCTAssertNil(encode(key("", code: KeyCode.left, [.command])))
        XCTAssertNil(encode(key("\r", code: KeyCode.returnKey, [.command])))
    }

    func testArrowsNormalAndApplicationMode() {
        XCTAssertEqual(encode(key("", code: KeyCode.up)), Array("\u{1B}[A".utf8))
        XCTAssertEqual(encode(key("", code: KeyCode.up), appCursor: true), Array("\u{1B}OA".utf8))
        XCTAssertEqual(encode(key("", code: KeyCode.left, [.control])), Array("\u{1B}[1;5D".utf8))
        XCTAssertEqual(encode(key("", code: KeyCode.right, [.shift, .option])), Array("\u{1B}[1;4C".utf8))
    }

    func testEditingAndFunctionKeys() {
        XCTAssertEqual(encode(key("", code: KeyCode.home)), Array("\u{1B}[H".utf8))
        XCTAssertEqual(encode(key("", code: KeyCode.end), appCursor: true), Array("\u{1B}OF".utf8))
        XCTAssertEqual(encode(key("", code: KeyCode.pageUp)), Array("\u{1B}[5~".utf8))
        XCTAssertEqual(encode(key("", code: KeyCode.pageDown, [.shift])), Array("\u{1B}[6;2~".utf8))
        XCTAssertEqual(encode(key("", code: KeyCode.forwardDelete)), Array("\u{1B}[3~".utf8))
        XCTAssertEqual(encode(key("", code: KeyCode.f1)), Array("\u{1B}OP".utf8))
        XCTAssertEqual(encode(key("", code: KeyCode.f5)), Array("\u{1B}[15~".utf8))
        XCTAssertEqual(encode(key("", code: KeyCode.f12)), Array("\u{1B}[24~".utf8))
    }

    func testReturnTabEscapeBackspace() {
        XCTAssertEqual(encode(key("\r", code: KeyCode.returnKey)), [0x0D])
        XCTAssertEqual(encode(key("\r", code: KeyCode.returnKey, [.option])), [0x1B, 0x0D])
        XCTAssertEqual(encode(key("\t", code: KeyCode.tab)), [0x09])
        XCTAssertEqual(encode(key("\t", code: KeyCode.tab, [.shift])), Array("\u{1B}[Z".utf8))
        XCTAssertEqual(encode(key("\u{1B}", code: KeyCode.escape)), [0x1B])
        XCTAssertEqual(encode(key("\u{7F}", code: KeyCode.backspace)), [0x7F])
        XCTAssertEqual(encode(key("\u{7F}", code: KeyCode.backspace, [.option])), [0x1B, 0x7F])
    }

    func testControlCombinations() {
        XCTAssertEqual(encode(key("\u{03}", [.control], base: "c")), [0x03])
        XCTAssertEqual(encode(key(" ", [.control], base: " ")), [0x00])
        XCTAssertEqual(encode(key("[", [.control], base: "[")), [0x1B])
        XCTAssertEqual(encode(key("_", [.control, .shift], base: "_")), [0x1F])
        XCTAssertEqual(encode(key("?", [.control, .shift], base: "?")), [0x7F])
        XCTAssertEqual(encode(key("A", [.control, .shift], base: "A")), [0x01])
        XCTAssertNil(encode(key("1", [.control], base: "1")))
    }

    func testOptionAsMeta() {
        XCTAssertEqual(encode(key("ø", [.option], base: "o")), [0x1B, 0x6F])
        XCTAssertEqual(encode(key("Ø", [.option, .shift], base: "O")), [0x1B, 0x4F])
        XCTAssertNil(encode(key("ø", [.option], base: "o"), altIsMeta: false))
    }
}
