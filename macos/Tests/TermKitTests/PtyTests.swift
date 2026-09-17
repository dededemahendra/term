import XCTest
@testable import TermKit

final class PtyTests: XCTestCase {
    private func collect(program: String, arguments: [String], cols: Int = 80, rows: Int = 24,
                         timeout: TimeInterval = 5) throws -> String {
        let pty = try Pty(program: program, arguments: arguments, environment: Pty.childEnvironment(), cols: cols, rows: rows)
        let done = expectation(description: "exit")
        var output = [UInt8]()
        let lock = NSLock()
        pty.startReading(onData: { bytes in
            lock.lock()
            output.append(contentsOf: bytes)
            lock.unlock()
        }, onExit: { done.fulfill() })
        wait(for: [done], timeout: timeout)
        return String(decoding: output, as: UTF8.self)
    }

    func testSpawnReadsOutputAndReportsExit() throws {
        let out = try collect(program: "/bin/echo", arguments: ["echo", "hello pty"])
        XCTAssertTrue(out.contains("hello pty"))
    }

    func testWindowSizeReachesTheChild() throws {
        let out = try collect(program: "/bin/sh", arguments: ["sh", "-c", "stty size"], cols: 100, rows: 30)
        XCTAssertTrue(out.contains("30 100"), out)
    }

    func testWriteReachesTheChild() throws {
        let pty = try Pty(program: "/bin/cat", arguments: ["cat"], environment: Pty.childEnvironment(), cols: 20, rows: 5)
        let seen = expectation(description: "echo")
        var output = [UInt8]()
        let lock = NSLock()
        var fulfilled = false
        pty.startReading(onData: { bytes in
            lock.lock()
            output.append(contentsOf: bytes)
            let hit = !fulfilled && String(decoding: output, as: UTF8.self).contains("ping")
            if hit { fulfilled = true }
            lock.unlock()
            if hit { seen.fulfill() }
        }, onExit: {})
        pty.write(Array("ping\r".utf8))
        wait(for: [seen], timeout: 5)
        pty.close()
    }

    func testMissingProgramThrowsSpawnFailed() {
        XCTAssertThrowsError(try Pty(program: "/nonexistent/program", arguments: ["x"], environment: [:], cols: 1, rows: 1)) { error in
            XCTAssertEqual(error as? PtyError, .spawnFailed(errno: ENOENT))
        }
    }

    /// The guards in write, resize and close are trivial by inspection; this
    /// pins the flag's transition and that late calls are safe.
    func testExitedFlagTransitionsAndLateCallsAreSafe() throws {
        let pty = try Pty(program: "/bin/echo", arguments: ["echo", "bye"], environment: Pty.childEnvironment(), cols: 10, rows: 2)
        XCTAssertFalse(pty.hasExited)
        let done = expectation(description: "exit")
        pty.startReading(onData: { _ in }, onExit: { done.fulfill() })
        wait(for: [done], timeout: 5)
        XCTAssertTrue(pty.hasExited)
        pty.close()
        pty.write(Array("ignored".utf8))
        pty.resize(cols: 5, rows: 5)
        XCTAssertTrue(pty.hasExited)
    }
}
