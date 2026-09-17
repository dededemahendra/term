# macOS Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `Term.app`, the macOS shell around the Rust core: a Swift package with an AppKit window, a pseudo-terminal, a CoreText glyph atlas, a single-draw-call Metal renderer, latency-first frame scheduling, keyboard, mouse and clipboard handling, a config file, benchmarks and release packaging.

**Architecture:** One Swift package in `macos/` with two C targets (`CTermCore` exposes the core's header and links `libtermcore.a`; `CPty` wraps `forkpty`), a library `TermKit` holding everything testable (core wrapper, config, palette, PTY, encoders, atlas, renderer, view, window) and a tiny executable `Term`. Output is parsed on the PTY reader thread inside the core; the main thread copies dirty rows into instance buffers and issues one instanced draw per frame. Scripts assemble the `.app`, precompile the shader when the Metal toolchain exists, run the benchmarks and package a release.

**Tech Stack:** Swift 5 language mode (tools 5.9), macOS 14 or newer, AppKit, Metal, CoreText, no third-party Swift packages. The core is `../core` (Rust), linked as a static library.

**Spec:** `docs/superpowers/specs/2026-09-16-terminal-emulator-design.md`

**Provenance:** every Swift source and script in this plan was built and run on this machine before the plan was written (the app rendered text, colour, wide glyphs and emoji, and measured 0.47 ms keystroke to commit, 100 ms warm startup, 140 MB/s throughput, 74 MB idle). The test files were written against that code but could not be compiled without Xcode's toolchain at the time; if one fails to compile, fix the test to the code's real API and say so in the report, unless the code is genuinely wrong.

## Global Constraints

- Build with plain `swift build` (command line tools suffice). Run tests with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`; the command line tools ship no XCTest. If `swift test` reports the Xcode licence is not accepted, stop and report BLOCKED: the user must run `sudo xcodebuild -license accept`.
- The core must be built first: `macos/scripts/build-core.sh` produces `target/release/libtermcore.a`, which `Package.swift` links.
- Swift 5 language mode; no strict concurrency annotations required. No third-party dependencies. Minimum macOS 14.
- The core is accessed only through `Terminal`, which holds a lock; the PTY reader thread feeds it, the main thread reads it. AppKit and Metal objects are used on the main thread only, except the presented-frame handler which only records a timestamp.
- Never call `close` on the PTY master from a thread other than the reader thread (it deadlocks on macOS); hang up the child with SIGHUP instead.
- No `fatalError` on a path reachable by user input or program output. `preconditionFailure` only for states the code makes impossible.
- The Metal layer runs with `displaySyncEnabled = false` and `presentsWithTransaction = false`. One render pipeline, one instanced draw per frame, instance buffers triple buffered behind a semaphore.
- The shader is loaded from `default.metallib` in the bundle when present, otherwise compiled from `Shaders.source` at runtime. The two must stay identical; `scripts/build-shaders.sh` derives the metallib from the Swift string.
- Names in each task's Interfaces block are consumed by later tasks by name.
- Australian English, no em dashes, sentence case in comments and docs. Conventional Commits, each commit ending with the `Co-Authored-By` trailer your environment specifies.

## File structure

```
macos/
  Package.swift                          targets, links ../target/release (or ../target/universal)
  Sources/CTermCore/include/termcore.h   symlink to ../../../../core/include/termcore.h
  Sources/CTermCore/anchor.c             keeps the C target non empty
  Sources/CPty/include/cpty.h            forkpty, resize and process start time
  Sources/CPty/pty.c
  Sources/TermKit/Version.swift
  Sources/TermKit/Terminal.swift         Swift face of the core, locked
  Sources/TermKit/Config.swift           ~/.config/term/config
  Sources/TermKit/Palette.swift          colour indices to packed RGBA
  Sources/TermKit/Pty.swift              spawn, read thread, write, resize, hangup
  Sources/TermKit/KeyEncoder.swift       keys to bytes
  Sources/TermKit/MouseEncoder.swift     mouse reports
  Sources/TermKit/UrlDetector.swift      cmd-click targets
  Sources/TermKit/GlyphAtlas.swift       CoreText into one RGBA texture
  Sources/TermKit/Shaders.swift          embedded Metal source
  Sources/TermKit/Renderer.swift         instances, uniforms, one draw
  Sources/TermKit/FrameScheduler.swift   1 ms coalescing
  Sources/TermKit/LatencyProbe.swift     TERM_PROBE measurements
  Sources/TermKit/TerminalSession.swift  terminal + pty wiring
  Sources/TermKit/TerminalView.swift     NSView, input, mouse, scroll
  Sources/TermKit/TerminalWindowController.swift
  Sources/TermKit/AppMenu.swift
  Sources/Term/main.swift                NSApplication, -e, AppDelegate
  Tests/TermKitTests/*.swift
  scripts/build-core.sh, build-shaders.sh, bundle.sh, run.sh, screenshot.sh, release.sh
  packaging/term.rb                      Homebrew cask template
bench-shell/
  startup.sh, latency.sh, throughput.sh, memory.sh, results.md
```

---

### Task 1: Package scaffold and core link

**Files:**
- Create: `macos/Package.swift`, `macos/Sources/CTermCore/include/termcore.h` (symlink), `macos/Sources/CTermCore/anchor.c`, `macos/Sources/CPty/include/cpty.h`, `macos/Sources/CPty/pty.c`, `macos/Sources/TermKit/Version.swift`, `macos/Sources/Term/main.swift`, `macos/Tests/TermKitTests/VersionTests.swift`, `macos/scripts/build-core.sh`
- Modify: `.gitignore` (add `/macos/.build` and `/macos/build`)

**Interfaces:**
- Produces: C module `CTermCore` (every `term_*` function and `TermCursor`, `TermModes`, `TermRgb` from the header), C module `CPty` with `cpty_spawn`, `cpty_resize`, `cpty_process_start_uptime`, library `TermKit`, executable `Term`, test target `TermKitTests`, `TermKitVersion.string`.

- [ ] **Step 1: Build the core and create the package files**

Run `macos/scripts/build-core.sh` after creating it:

```sh
#!/bin/sh
# Builds the Rust core as a release static library into ../target/release,
# which Package.swift links. Pass --universal to also build x86_64 and
# produce a fat archive for release packaging.
set -eu
cd "$(dirname "$0")/../.."
cargo build -p termcore --release
# A stale fat archive would shadow the fresh arm64 build.
rm -rf target/universal
if [ "${1:-}" = "--universal" ]; then
    rustup target add x86_64-apple-darwin >/dev/null
    cargo build -p termcore --release --target x86_64-apple-darwin
    cargo build -p termcore --release --target aarch64-apple-darwin
    mkdir -p target/universal
    lipo -create target/aarch64-apple-darwin/release/libtermcore.a \
        target/x86_64-apple-darwin/release/libtermcore.a \
        -output target/universal/libtermcore.a
    echo "built target/universal/libtermcore.a"
fi
echo "built target/release/libtermcore.a"
```

`macos/Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription
import Foundation

// The Rust core is built into ../target/release by scripts/build-core.sh.
// A fat archive in ../target/universal (from build-core.sh --universal)
// takes precedence so release builds can target both architectures.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let universalDir = packageRoot.appendingPathComponent("../target/universal").standardized.path
let releaseDir = packageRoot.appendingPathComponent("../target/release").standardized.path
let coreLibDir = FileManager.default.fileExists(atPath: universalDir + "/libtermcore.a") ? universalDir : releaseDir

let package = Package(
    name: "Term",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CTermCore",
            path: "Sources/CTermCore",
            linkerSettings: [.unsafeFlags(["-L", coreLibDir]), .linkedLibrary("termcore")]
        ),
        .target(name: "CPty", path: "Sources/CPty"),
        .target(name: "TermKit", dependencies: ["CTermCore", "CPty"], path: "Sources/TermKit"),
        .executableTarget(name: "Term", dependencies: ["TermKit"], path: "Sources/Term"),
        .testTarget(name: "TermKitTests", dependencies: ["TermKit"], path: "Tests/TermKitTests"),
    ]
)
```

Create the header symlink (the C target reads the core's header through it, so the two can never drift):

```bash
mkdir -p macos/Sources/CTermCore/include
ln -s ../../../../core/include/termcore.h macos/Sources/CTermCore/include/termcore.h
```

`macos/Sources/CTermCore/anchor.c`:

```c
void ctermcore_anchor(void) {}
```

`macos/Sources/CPty/include/cpty.h`:

```c
#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>

/* Forks a child on a new pseudo terminal of the given size and execs
 * path with argv and envp. Returns the master fd, or -1 with errno set.
 * pid_out receives the child's pid. */
int cpty_spawn(const char *path, char *const argv[], char *const envp[],
               unsigned short cols, unsigned short rows, pid_t *pid_out);

/* Tells the kernel the window size changed. Returns 0 or -1. */
int cpty_resize(int master_fd, unsigned short cols, unsigned short rows);

/* Seconds since boot at which this process started, on the same
 * timebase as CACurrentMediaTime and NSEvent.timestamp. */
double cpty_process_start_uptime(void);

#endif
```

`macos/Sources/CPty/pty.c`:

```c
#include "cpty.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

int cpty_spawn(const char *path, char *const argv[], char *const envp[],
               unsigned short cols, unsigned short rows, pid_t *pid_out) {
    struct winsize ws = { rows, cols, 0, 0 };
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        execve(path, argv, envp);
        _exit(127);
    }
    *pid_out = pid;
    return master;
}

int cpty_resize(int master_fd, unsigned short cols, unsigned short rows) {
    struct winsize ws = { rows, cols, 0, 0 };
    return ioctl(master_fd, TIOCSWINSZ, &ws);
}

double cpty_process_start_uptime(void) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    struct kinfo_proc info;
    size_t size = sizeof(info);
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return 0;
    }
    struct timeval start = info.kp_proc.p_starttime;
    struct timeval now;
    gettimeofday(&now, NULL);
    double age = (now.tv_sec - start.tv_sec) + (now.tv_usec - start.tv_usec) / 1e6;
    struct timespec uptime;
    clock_gettime(CLOCK_UPTIME_RAW, &uptime);
    return (uptime.tv_sec + uptime.tv_nsec / 1e9) - age;
}
```

`macos/Sources/TermKit/Version.swift`:

```swift
public enum TermKitVersion { public static let string = "0.1.0" }
```

`macos/Sources/Term/main.swift` (replaced in Task 11):

```swift
import TermKit

print("term \(TermKitVersion.string)")
```

`macos/Tests/TermKitTests/VersionTests.swift`:

```swift
import XCTest
@testable import TermKit

final class VersionTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertEqual(TermKitVersion.string, "0.1.0")
    }
}
```

Append to the root `.gitignore`:

```
/macos/.build
/macos/build
```

- [ ] **Step 2: Build and run**

Run from `macos/`: `macos/scripts/build-core.sh && swift build && .build/debug/Term`
Expected: `term 0.1.0`.

- [ ] **Step 3: Run the test**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` from `macos/`
Expected: `Executed 1 test, with 0 failures`. If the output says the Xcode licence is not accepted, report BLOCKED with that message.

- [ ] **Step 4: Commit**

```bash
git add .gitignore macos
git commit -m "feat(macos): scaffold the Swift package and link the core"
```

---

### Task 2: Terminal wrapper

**Files:**
- Create: `macos/Sources/TermKit/Terminal.swift`, `macos/Tests/TermKitTests/TerminalTests.swift`

**Interfaces:**
- Produces: `CellFlags`, `Cell` (`raw`, `codepoint`, `scalar`, `flags`, `fg`, `bg`, `selected`, `Cell.defaultColor`), `CursorInfo`, `SelectionMode`, `Terminal` (`init(cols:rows:scrollback:)`, `feed`, `resize`, `copyGrid(into:)`, `dirtyWordCount`, `takeDirtyRows(into:)`, `cursor`, `modes`, `scrollViewport(by:)`, `selectionStart/Extend/Clear`, `selectionText`, `title`, `drainResponses()`, `overflowColors`, `cols`, `rows`).

- [ ] **Step 1: Write the failing tests**

`macos/Tests/TermKitTests/TerminalTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TerminalTests` from `macos/`
Expected: compile error, `Terminal` not found.

- [ ] **Step 3: Write the implementation**

`macos/Sources/TermKit/Terminal.swift`:

```swift
import CTermCore
import Foundation

/// Style bits packed into a cell, matching `termcore.h`.
public struct CellFlags: OptionSet, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let bold = CellFlags(rawValue: 1 << 0)
    public static let italic = CellFlags(rawValue: 1 << 1)
    public static let underline = CellFlags(rawValue: 1 << 2)
    public static let strike = CellFlags(rawValue: 1 << 3)
    public static let inverse = CellFlags(rawValue: 1 << 4)
    public static let wide = CellFlags(rawValue: 1 << 5)
    public static let wideSpacer = CellFlags(rawValue: 1 << 6)
    public static let dim = CellFlags(rawValue: 1 << 7)
}

/// One packed cell as the core lays it out.
public struct Cell: Hashable {
    public let raw: UInt64
    public init(raw: UInt64) { self.raw = raw }
    public var codepoint: UInt32 { UInt32(raw & 0x1F_FFFF) }
    public var scalar: Unicode.Scalar { Unicode.Scalar(codepoint) ?? " " }
    public var flags: CellFlags { CellFlags(rawValue: UInt8((raw >> 21) & 0xFF)) }
    public var fg: UInt16 { UInt16((raw >> 29) & 0xFFFF) }
    public var bg: UInt16 { UInt16((raw >> 45) & 0xFFFF) }
    public var selected: Bool { (raw >> 61) & 1 == 1 }
    /// Colour index meaning "the configured default".
    public static let defaultColor: UInt16 = 0xFFFF
}

public struct CursorInfo: Equatable {
    public var col: Int
    public var row: Int
    /// 0 block, 1 underline, 2 bar.
    public var shape: UInt8
    public var blink: Bool
    public var visible: Bool
}

public enum SelectionMode: UInt8 {
    case normal = 0
    case word = 1
    case line = 2
}

/// Swift face of the core. Every method takes the internal lock, so the
/// PTY reader thread and the main thread may share one instance.
public final class Terminal {
    private let handle: OpaquePointer
    private let lock = NSLock()
    public private(set) var cols: Int
    public private(set) var rows: Int
    private var responseBuffer = [UInt8](repeating: 0, count: 4096)

    public init(cols: Int, rows: Int, scrollback: Int) {
        let c = UInt16(clamping: max(cols, 1))
        let r = UInt16(clamping: max(rows, 1))
        guard let handle = term_new(c, r, UInt32(clamping: max(scrollback, 0))) else {
            preconditionFailure("term_new rejected a non zero size")
        }
        self.handle = handle
        self.cols = Int(c)
        self.rows = Int(r)
    }

    deinit {
        term_free(handle)
    }

    public func feed(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        _ = term_feed(handle, base.assumingMemoryBound(to: UInt8.self), bytes.count)
    }

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { feed($0) }
    }

    public func resize(cols: Int, rows: Int) {
        let c = UInt16(clamping: max(cols, 1))
        let r = UInt16(clamping: max(rows, 1))
        lock.lock()
        defer { lock.unlock() }
        _ = term_resize(handle, c, r)
        self.cols = Int(c)
        self.rows = Int(r)
    }

    /// Copies the visible grid, viewport applied, into `cells`, which is
    /// resized to `cols * rows` when needed.
    public func copyGrid(into cells: inout [UInt64]) {
        lock.lock()
        defer { lock.unlock() }
        let need = cols * rows
        if cells.count != need {
            cells = [UInt64](repeating: 0, count: need)
        }
        cells.withUnsafeMutableBufferPointer { _ = term_grid(handle, $0.baseAddress, $0.count) }
    }

    /// Words needed by `takeDirtyRows`.
    public var dirtyWordCount: Int { (rows + 63) / 64 }

    /// Copies and clears the dirty row bitmap. `words` is resized when needed.
    public func takeDirtyRows(into words: inout [UInt64]) {
        lock.lock()
        defer { lock.unlock() }
        let need = (rows + 63) / 64
        if words.count != need {
            words = [UInt64](repeating: 0, count: need)
        }
        words.withUnsafeMutableBufferPointer { _ = term_dirty_rows(handle, $0.baseAddress, $0.count) }
    }

    public var cursor: CursorInfo {
        lock.lock()
        defer { lock.unlock() }
        var c = TermCursor()
        _ = term_cursor(handle, &c)
        return CursorInfo(col: Int(c.col), row: Int(c.row), shape: c.shape, blink: c.blink != 0, visible: c.visible != 0)
    }

    public var modes: TermModes {
        lock.lock()
        defer { lock.unlock() }
        var m = TermModes()
        _ = term_modes(handle, &m)
        return m
    }

    /// Positive scrolls towards older content.
    public func scrollViewport(by delta: Int) {
        lock.lock()
        defer { lock.unlock() }
        _ = term_scroll_viewport(handle, Int32(clamping: delta))
    }

    private func inRange(_ col: Int, _ row: Int) -> Bool {
        col >= 0 && row >= 0 && col < cols && row < rows
    }

    /// Coordinates are visible cells. False when out of range.
    @discardableResult
    public func selectionStart(col: Int, row: Int, mode: SelectionMode) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inRange(col, row) else { return false }
        return term_selection_start(handle, UInt16(col), UInt16(row), mode.rawValue) == 0
    }

    @discardableResult
    public func selectionExtend(col: Int, row: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inRange(col, row) else { return false }
        return term_selection_extend(handle, UInt16(col), UInt16(row)) == 0
    }

    public func selectionClear() {
        lock.lock()
        defer { lock.unlock() }
        _ = term_selection_clear(handle)
    }

    public var selectionText: String { text(term_selection_text) }

    /// The OSC 0 or 2 title, empty when none was set.
    public var title: String { text(term_title) }

    private func text(_ getter: (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int) -> Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        let needed = getter(handle, nil, 0)
        if needed == 0 { return "" }
        var buffer = [UInt8](repeating: 0, count: needed)
        let written = buffer.withUnsafeMutableBufferPointer { getter(handle, $0.baseAddress, $0.count) }
        return String(decoding: buffer[0..<min(written, needed)], as: UTF8.self)
    }

    /// Bytes the terminal wants written to the shell: replies to queries.
    public func drainResponses() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        let n = responseBuffer.withUnsafeMutableBufferPointer { term_responses(handle, $0.baseAddress, $0.count) }
        return Array(responseBuffer[0..<n])
    }

    /// 24-bit colours interned by the core, cell index 256 upward.
    public var overflowColors: [TermRgb] {
        lock.lock()
        defer { lock.unlock() }
        let count = term_colors(handle, nil, 0)
        if count == 0 { return [] }
        var out = [TermRgb](repeating: TermRgb(), count: count)
        out.withUnsafeMutableBufferPointer { _ = term_colors(handle, $0.baseAddress, $0.count) }
        return out
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TerminalTests` from `macos/`
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/TermKit/Terminal.swift macos/Tests/TermKitTests/TerminalTests.swift
git commit -m "feat(macos): wrap the core behind a locked Terminal type"
```

---

### Task 3: Config file

**Files:**
- Create: `macos/Sources/TermKit/Config.swift`, `macos/Tests/TermKitTests/ConfigTests.swift`

**Interfaces:**
- Produces: `RGB` (`init(_:_:_:)`, `init?(hex:)`), `CursorStyle`, `Config` (all keys from the spec as properties, `Config.parse(_:warn:)`, `Config.load(path:warn:)`, `Config.defaultPath`, `Config.xtermPalette`).

- [ ] **Step 1: Write the failing tests**

```swift
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

    func testMissingFileGivesDefaults() {
        XCTAssertEqual(Config.load(path: "/nonexistent/term/config"), Config())
    }

    func testHexParsing() {
        XCTAssertEqual(RGB(hex: "#0A0b0C"), RGB(10, 11, 12))
        XCTAssertNil(RGB(hex: "#12345"))
        XCTAssertNil(RGB(hex: "zzzzzz"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConfigTests` from `macos/`
Expected: compile error, `Config` not found.

- [ ] **Step 3: Write the implementation**

`macos/Sources/TermKit/Config.swift`:

```swift
import Foundation

public struct RGB: Equatable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Parses `#rrggbb` or `rrggbb`.
    public init?(hex: String) {
        var s = Substring(hex.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF))
    }
}

public enum CursorStyle: String {
    case block
    case bar
    case underline
}

/// Settings from `~/.config/term/config`, a flat `key = value` file.
public struct Config: Equatable {
    public var font = "Menlo"
    public var fontSize = 13.0
    public var lineHeight = 1.0
    /// Nil means the login shell from `SHELL`.
    public var shell: String? = nil
    public var scrollback = 10_000
    public var padding = 8.0
    public var cursorStyle = CursorStyle.block
    public var cursorBlink = false
    public var cursorColor = RGB(255, 255, 255)
    public var foreground = RGB(0xD0, 0xD0, 0xD0)
    public var background = RGB(0, 0, 0)
    public var selectionBackground = RGB(0x44, 0x44, 0x44)
    public var palette = Config.xtermPalette
    public var altIsMeta = true
    public var copyOnSelect = false

    public init() {}

    public static let xtermPalette: [RGB] = [
        RGB(0, 0, 0), RGB(205, 0, 0), RGB(0, 205, 0), RGB(205, 205, 0),
        RGB(0, 0, 238), RGB(205, 0, 205), RGB(0, 205, 205), RGB(229, 229, 229),
        RGB(127, 127, 127), RGB(255, 0, 0), RGB(0, 255, 0), RGB(255, 255, 0),
        RGB(92, 92, 255), RGB(255, 0, 255), RGB(0, 255, 255), RGB(255, 255, 255),
    ]

    public static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.config/term/config"
    }

    /// Loads the file at `path`; a missing file gives the defaults.
    public static func load(path: String = Config.defaultPath, warn: (String) -> Void = { _ in }) -> Config {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return Config() }
        return parse(text, warn: warn)
    }

    public static func parse(_ text: String, warn: (String) -> Void = { _ in }) -> Config {
        var config = Config()
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let eq = line.firstIndex(of: "=") else {
                warn("config line \(index + 1): expected key = value")
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !config.apply(key: key, value: value) {
                warn("config line \(index + 1): ignored \(key) = \(value)")
            }
        }
        return config
    }

    private static func bool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    /// Returns false for an unknown key or an unusable value.
    private mutating func apply(key: String, value: String) -> Bool {
        switch key {
        case "font":
            guard !value.isEmpty else { return false }
            font = value
        case "font-size":
            guard let v = Double(value), v >= 4, v <= 200 else { return false }
            fontSize = v
        case "line-height":
            guard let v = Double(value), v >= 0.5, v <= 3 else { return false }
            lineHeight = v
        case "shell":
            guard !value.isEmpty else { return false }
            shell = value
        case "scrollback":
            guard let v = Int(value), v >= 0, v <= 1_000_000 else { return false }
            scrollback = v
        case "padding":
            guard let v = Double(value), v >= 0, v <= 200 else { return false }
            padding = v
        case "cursor-style":
            guard let v = CursorStyle(rawValue: value) else { return false }
            cursorStyle = v
        case "cursor-blink":
            guard let v = Config.bool(value) else { return false }
            cursorBlink = v
        case "cursor-color":
            guard let v = RGB(hex: value) else { return false }
            cursorColor = v
        case "foreground":
            guard let v = RGB(hex: value) else { return false }
            foreground = v
        case "background":
            guard let v = RGB(hex: value) else { return false }
            background = v
        case "selection-background":
            guard let v = RGB(hex: value) else { return false }
            selectionBackground = v
        case "alt-is-meta":
            guard let v = Config.bool(value) else { return false }
            altIsMeta = v
        case "copy-on-select":
            guard let v = Config.bool(value) else { return false }
            copyOnSelect = v
        default:
            guard key.hasPrefix("color"), let n = Int(key.dropFirst(5)), (0..<16).contains(n),
                  let v = RGB(hex: value) else { return false }
            palette[n] = v
        }
        return true
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConfigTests` from `macos/`
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/TermKit/Config.swift macos/Tests/TermKitTests/ConfigTests.swift
git commit -m "feat(macos): parse the config file"
```

---

### Task 4: Palette

**Files:**
- Create: `macos/Sources/TermKit/Palette.swift`, `macos/Tests/TermKitTests/PaletteTests.swift`

**Interfaces:**
- Consumes: `Config`, `Cell.defaultColor`, `TermRgb`.
- Produces: `Palette(config:)` with `packed`, `foreground`, `background`, `selectionBackground`, `cursorColor`, `resolve(_:overflow:isForeground:) -> UInt32`, `Palette.pack`, `Palette.xterm256`. Packed layout is `r | g << 8 | b << 16 | a << 24`.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PaletteTests` from `macos/`
Expected: compile error, `Palette` not found.

- [ ] **Step 3: Write the implementation**

`macos/Sources/TermKit/Palette.swift`:

```swift
import CTermCore
import Foundation

/// Resolves cell colour indices to packed RGBA8 for the renderer.
/// Packed layout is `r | g << 8 | b << 16 | a << 24`.
public struct Palette {
    public private(set) var packed: [UInt32]
    public let foreground: UInt32
    public let background: UInt32
    public let selectionBackground: UInt32
    public let cursorColor: UInt32

    public init(config: Config) {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<16 {
            table[i] = Palette.pack(config.palette[i])
        }
        for i in 16..<256 {
            table[i] = Palette.pack(Palette.xterm256(i))
        }
        packed = table
        foreground = Palette.pack(config.foreground)
        background = Palette.pack(config.background)
        selectionBackground = Palette.pack(config.selectionBackground)
        cursorColor = Palette.pack(config.cursorColor)
    }

    public static func pack(_ c: RGB) -> UInt32 {
        UInt32(c.r) | UInt32(c.g) << 8 | UInt32(c.b) << 16 | 0xFF00_0000
    }

    public static func pack(_ c: TermRgb) -> UInt32 {
        UInt32(c.r) | UInt32(c.g) << 8 | UInt32(c.b) << 16 | 0xFF00_0000
    }

    /// The xterm 256 colour formula for indices 16 to 255.
    public static func xterm256(_ index: Int) -> RGB {
        if index < 16 { return Config.xtermPalette[index] }
        if index < 232 {
            let i = index - 16
            func cube(_ v: Int) -> UInt8 { v == 0 ? 0 : UInt8(55 + v * 40) }
            return RGB(cube(i / 36), cube((i % 36) / 6), cube(i % 6))
        }
        let v = UInt8(8 + (index - 232) * 10)
        return RGB(v, v, v)
    }

    /// Resolves a cell colour index. `overflow` is the core's interned
    /// 24-bit table, index 256 upward.
    public func resolve(_ index: UInt16, overflow: [TermRgb], isForeground: Bool) -> UInt32 {
        if index == Cell.defaultColor {
            return isForeground ? foreground : background
        }
        if index < 256 {
            return packed[Int(index)]
        }
        let i = Int(index) - 256
        if i < overflow.count {
            return Palette.pack(overflow[i])
        }
        return isForeground ? foreground : background
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PaletteTests` from `macos/`
Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/TermKit/Palette.swift macos/Tests/TermKitTests/PaletteTests.swift
git commit -m "feat(macos): resolve cell colours to packed RGBA"
```

---

### Task 5: Pseudo-terminal

**Files:**
- Create: `macos/Sources/TermKit/Pty.swift`, `macos/Tests/TermKitTests/PtyTests.swift`

**Interfaces:**
- Consumes: `CPty`.
- Produces: `PtyError`, `Pty` (`init(program:arguments:environment:cols:rows:)`, `pid`, `masterFd`, `Pty.loginShell`, `Pty.childEnvironment()`, `startReading(onData:onExit:)`, `write(_:)`, `resize(cols:rows:)`, `close()`).
- The close rule from the Global Constraints lives here: `close()` sends SIGHUP; the reader thread closes the descriptor after the child is reaped.

- [ ] **Step 1: Write the failing tests**

```swift
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
        pty.startReading(onData: { bytes in
            lock.lock()
            output.append(contentsOf: bytes)
            let text = String(decoding: output, as: UTF8.self)
            lock.unlock()
            if text.contains("ping") { seen.fulfill() }
        }, onExit: {})
        pty.write(Array("ping\r".utf8))
        wait(for: [seen], timeout: 5)
        pty.close()
    }

    func testMissingProgramExitsWithoutOutput() throws {
        // forkpty succeeds and exec fails in the child, which exits 127.
        let out = try collect(program: "/nonexistent/program", arguments: ["x"])
        XCTAssertEqual(out, "")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PtyTests` from `macos/`
Expected: compile error, `Pty` not found.

- [ ] **Step 3: Write the implementation**

`macos/Sources/TermKit/Pty.swift`:

```swift
import CPty
import Darwin
import Foundation

public enum PtyError: Error, Equatable {
    case spawnFailed(errno: Int32)
}

/// A child process on a pseudo terminal.
public final class Pty {
    public let pid: pid_t
    public let masterFd: Int32
    private var reader: Thread?

    /// Spawns `program` with `arguments` (argv[0] included) and `environment`.
    public init(program: String, arguments: [String], environment: [String: String], cols: Int, rows: Int) throws {
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let fd = cpty_spawn(program, argv, envp, UInt16(clamping: cols), UInt16(clamping: rows), &pid)
        if fd < 0 {
            throw PtyError.spawnFailed(errno: errno)
        }
        self.pid = pid
        self.masterFd = fd
    }

    /// The user's login shell, or zsh.
    public static var loginShell: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return shell.isEmpty ? "/bin/zsh" : shell
    }

    /// Environment for a child: the app's own plus the terminal identity.
    public static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "term"
        env.removeValue(forKey: "TERM_PROBE")
        return env
    }

    /// Starts a thread that reads output until the child closes the
    /// terminal. `onData` runs on that thread with a buffer that is only
    /// valid during the call. `onExit` runs once, after the child is reaped.
    public func startReading(onData: @escaping (UnsafeRawBufferPointer) -> Void, onExit: @escaping () -> Void) {
        let fd = masterFd
        let pid = self.pid
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    buffer.withUnsafeBytes { onData(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                    continue
                } else {
                    break
                }
            }
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            _ = Darwin.close(fd)
            onExit()
        }
        thread.name = "pty-reader"
        thread.qualityOfService = .userInteractive
        reader = thread
        thread.start()
    }

    /// Writes all of `bytes`, retrying on partial writes.
    public func write(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(masterFd, p, left)
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return
                }
                left -= n
                p += n
            }
        }
    }

    public func resize(cols: Int, rows: Int) {
        _ = cpty_resize(masterFd, UInt16(clamping: cols), UInt16(clamping: rows))
    }

    /// Hangs up the child. The reader thread closes the master once the
    /// child's side goes away; closing it here would deadlock against the
    /// blocked read on macOS.
    public func close() {
        kill(pid, SIGHUP)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PtyTests` from `macos/`
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/TermKit/Pty.swift macos/Tests/TermKitTests/PtyTests.swift
git commit -m "feat(macos): spawn the shell on a pseudo terminal"
```

---

### Task 6: Key encoder

**Files:**
- Create: `macos/Sources/TermKit/KeyEncoder.swift`, `macos/Tests/TermKitTests/KeyEncoderTests.swift`

**Interfaces:**
- Consumes: `TermModes` (`app_cursor`).
- Produces: `KeyModifiers`, `KeyInput`, `KeyCode` constants, `KeyEncoder.encode(_:modes:altIsMeta:) -> [UInt8]?` where nil means "let the text input system handle it".

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter KeyEncoderTests` from `macos/`
Expected: compile error, `KeyEncoder` not found.

- [ ] **Step 3: Write the implementation**

`macos/Sources/TermKit/KeyEncoder.swift`:

```swift
import CTermCore
import Foundation

public struct KeyModifiers: OptionSet, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1)
    public static let control = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)
}

/// The parts of a key event the encoder needs, so it can be tested
/// without constructing AppKit events.
public struct KeyInput: Equatable {
    public var characters: String
    public var charactersIgnoringModifiers: String
    public var keyCode: UInt16
    public var modifiers: KeyModifiers

    public init(characters: String, charactersIgnoringModifiers: String, keyCode: UInt16, modifiers: KeyModifiers = []) {
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// macOS virtual key codes the terminal maps itself.
public enum KeyCode {
    public static let returnKey: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let backspace: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let keypadEnter: UInt16 = 76
    public static let forwardDelete: UInt16 = 117
    public static let home: UInt16 = 115
    public static let end: UInt16 = 119
    public static let pageUp: UInt16 = 116
    public static let pageDown: UInt16 = 121
    public static let left: UInt16 = 123
    public static let right: UInt16 = 124
    public static let down: UInt16 = 125
    public static let up: UInt16 = 126
    public static let f1: UInt16 = 122
    public static let f2: UInt16 = 120
    public static let f3: UInt16 = 99
    public static let f4: UInt16 = 118
    public static let f5: UInt16 = 96
    public static let f6: UInt16 = 97
    public static let f7: UInt16 = 98
    public static let f8: UInt16 = 100
    public static let f9: UInt16 = 101
    public static let f10: UInt16 = 109
    public static let f11: UInt16 = 103
    public static let f12: UInt16 = 111
}

public enum KeyEncoder {
    private static let esc: UInt8 = 0x1B

    /// Bytes for keys the terminal handles itself, or nil when the event
    /// is ordinary text that should go through the text input system.
    public static func encode(_ key: KeyInput, modes: TermModes, altIsMeta: Bool) -> [UInt8]? {
        let m = key.modifiers
        let modParam = 1 + (m.contains(.shift) ? 1 : 0) + (m.contains(.option) ? 2 : 0) + (m.contains(.control) ? 4 : 0)
        let meta = m.contains(.option) && altIsMeta

        func arrow(_ final: String) -> [UInt8] {
            if modParam > 1 { return Array("\u{1B}[1;\(modParam)\(final)".utf8) }
            return Array((modes.app_cursor ? "\u{1B}O" : "\u{1B}[").utf8) + Array(final.utf8)
        }
        func tilde(_ n: Int) -> [UInt8] {
            if modParam > 1 { return Array("\u{1B}[\(n);\(modParam)~".utf8) }
            return Array("\u{1B}[\(n)~".utf8)
        }
        func ss3(_ final: String) -> [UInt8] {
            if modParam > 1 { return Array("\u{1B}[1;\(modParam)\(final)".utf8) }
            return Array("\u{1B}O\(final)".utf8)
        }
        func withMeta(_ bytes: [UInt8]) -> [UInt8] {
            meta ? [esc] + bytes : bytes
        }

        switch key.keyCode {
        case KeyCode.up: return arrow("A")
        case KeyCode.down: return arrow("B")
        case KeyCode.right: return arrow("C")
        case KeyCode.left: return arrow("D")
        case KeyCode.home: return arrow("H")
        case KeyCode.end: return arrow("F")
        case KeyCode.pageUp: return tilde(5)
        case KeyCode.pageDown: return tilde(6)
        case KeyCode.forwardDelete: return tilde(3)
        case KeyCode.f1: return ss3("P")
        case KeyCode.f2: return ss3("Q")
        case KeyCode.f3: return ss3("R")
        case KeyCode.f4: return ss3("S")
        case KeyCode.f5: return tilde(15)
        case KeyCode.f6: return tilde(17)
        case KeyCode.f7: return tilde(18)
        case KeyCode.f8: return tilde(19)
        case KeyCode.f9: return tilde(20)
        case KeyCode.f10: return tilde(21)
        case KeyCode.f11: return tilde(23)
        case KeyCode.f12: return tilde(24)
        case KeyCode.returnKey, KeyCode.keypadEnter: return withMeta([0x0D])
        case KeyCode.tab: return m.contains(.shift) ? Array("\u{1B}[Z".utf8) : withMeta([0x09])
        case KeyCode.escape: return [esc]
        case KeyCode.backspace: return withMeta([0x7F])
        default: break
        }

        if m.contains(.command) {
            return nil
        }
        let base = key.charactersIgnoringModifiers
        if m.contains(.control), let scalar = base.unicodeScalars.first {
            let c = scalar.value
            switch scalar {
            case "a"..."z": return withMeta([UInt8(c - 96)])
            case "A"..."Z": return withMeta([UInt8(c - 64)])
            case "[", "3": return withMeta([0x1B])
            case "\\", "4": return withMeta([0x1C])
            case "]", "5": return withMeta([0x1D])
            case "^", "6": return withMeta([0x1E])
            case "_", "-", "7", "/": return withMeta([0x1F])
            case " ", "2", "@": return withMeta([0x00])
            case "?", "8": return withMeta([0x7F])
            default: return nil
            }
        }
        if meta, !base.isEmpty {
            return [esc] + Array(base.utf8)
        }
        return nil
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter KeyEncoderTests` from `macos/`
Expected: 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/TermKit/KeyEncoder.swift macos/Tests/TermKitTests/KeyEncoderTests.swift
git commit -m "feat(macos): encode keys to terminal bytes"
```

---

### Task 7: Mouse reports and URL detection

**Files:**
- Create: `macos/Sources/TermKit/MouseEncoder.swift`, `macos/Sources/TermKit/UrlDetector.swift`, `macos/Tests/TermKitTests/MouseAndUrlTests.swift`

**Interfaces:**
- Produces: `MouseButton`, `MouseEncoder.encode(button:col:row:pressed:motion:modifiers:sgr:) -> [UInt8]`, `UrlDetector.url(in:at:) -> String?`.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MouseEncoderTests` from `macos/`
Expected: compile error, `MouseEncoder` not found.

- [ ] **Step 3: Write the implementation**

`macos/Sources/TermKit/MouseEncoder.swift`:

```swift
import Foundation

public enum MouseButton: Int {
    case left = 0
    case middle = 1
    case right = 2
    case wheelUp = 64
    case wheelDown = 65
}

/// Encodes mouse reports for programs that enabled mouse tracking.
public enum MouseEncoder {
    /// `motion` marks a drag report (modes 1002 and 1003). `sgr` selects the
    /// 1006 encoding; otherwise the legacy byte encoding is used, which
    /// cannot express coordinates past column or row 223 and returns
    /// nothing for them.
    public static func encode(button: MouseButton, col: Int, row: Int, pressed: Bool, motion: Bool,
                              modifiers: KeyModifiers, sgr: Bool) -> [UInt8] {
        var code = button.rawValue
        if modifiers.contains(.shift) { code += 4 }
        if modifiers.contains(.option) { code += 8 }
        if modifiers.contains(.control) { code += 16 }
        if motion { code += 32 }
        if sgr {
            return Array("\u{1B}[<\(code);\(col + 1);\(row + 1)\(pressed ? "M" : "m")".utf8)
        }
        if !pressed {
            code = (code & ~3) | 3
        }
        let x = col + 33
        let y = row + 33
        guard x <= 255, y <= 255 else { return [] }
        return [0x1B, 0x5B, 0x4D, UInt8(32 + code), UInt8(x), UInt8(y)]
    }
}
```

`macos/Sources/TermKit/UrlDetector.swift`:

```swift
import Foundation

/// Finds the URL under a column of a row's text, for cmd-click.
public enum UrlDetector {
    private static let stops: Set<Character> = [" ", "\t", "\"", "'", "<", ">", "`"]
    private static let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}"]

    public static func url(in line: String, at column: Int) -> String? {
        let chars = Array(line)
        guard column >= 0, column < chars.count, !stops.contains(chars[column]) else { return nil }
        var start = column
        while start > 0, !stops.contains(chars[start - 1]) { start -= 1 }
        var end = column
        while end + 1 < chars.count, !stops.contains(chars[end + 1]) { end += 1 }
        var run = String(chars[start...end])
        while run.first == "(" || run.first == "[" {
            run.removeFirst()
        }
        guard let schemeRange = run.range(of: "://") else { return nil }
        let scheme = run[..<schemeRange.lowerBound]
        guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0 == "+" || $0 == "-" || $0 == "." }) else { return nil }
        while let last = run.last, trailing.contains(last) {
            if last == ")" && run.filter({ $0 == "(" }).count == run.filter({ $0 == ")" }).count { break }
            if last == "]" && run.filter({ $0 == "[" }).count == run.filter({ $0 == "]" }).count { break }
            run.removeLast()
        }
        return run.contains("://") ? run : nil
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MouseEncoderTests` from `macos/` and `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter UrlDetectorTests` from `macos/`
Expected: 2 tests each, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/TermKit/MouseEncoder.swift macos/Sources/TermKit/UrlDetector.swift macos/Tests/TermKitTests/MouseAndUrlTests.swift
git commit -m "feat(macos): mouse reporting and cmd-click URL detection"
```

---

### Task 8: Glyph atlas

**Files:**
- Create: `macos/Sources/TermKit/GlyphAtlas.swift`, `macos/Tests/TermKitTests/GlyphAtlasTests.swift`

**Interfaces:**
- Produces: `GlyphStyle`, `GlyphRect` (8 bytes, matches the shader), `GlyphRef` (`index`, `isColor`), `GlyphAtlas` (`init(device:fontName:pointSize:scale:lineHeight:warn:)`, `cellWidth`, `cellHeight`, `baseline`, `texture`, `rects`, `generation`, `glyph(for:style:wide:)`, `GlyphAtlas.metrics(fontName:pointSize:scale:lineHeight:)`, `GlyphAtlas.resolveFont(name:size:warn:)`).
- Rules: index 0 is the blank glyph; monochrome glyphs are white with coverage in alpha; colour glyphs are stored as drawn; a two-cell slot holding a narrow text glyph switches to the colour emoji font; the texture starts at 512 pixels and doubles by blitting.

- [ ] **Step 1: Write the failing tests**

```swift
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
}
```

- [ ] **Step 2: Run to verify failure**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GlyphAtlasTests` from `macos/`
Expected: compile error, `GlyphAtlas` not found.

- [ ] **Step 3: Write the implementation**

`macos/Sources/TermKit/GlyphAtlas.swift`:

```swift
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
```

- [ ] **Step 4: Run to verify pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GlyphAtlasTests` from `macos/`
Expected: 5 tests, 0 failures (the growth test takes a few hundred milliseconds).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/TermKit/GlyphAtlas.swift macos/Tests/TermKitTests/GlyphAtlasTests.swift
git commit -m "feat(macos): rasterise glyphs into a Metal atlas"
```

---

### Task 9: Renderer, scheduler and probe

**Files:**
- Create: `macos/Sources/TermKit/Shaders.swift`, `macos/Sources/TermKit/Renderer.swift`, `macos/Sources/TermKit/FrameScheduler.swift`, `macos/Sources/TermKit/LatencyProbe.swift`, `macos/Tests/TermKitTests/RendererTests.swift`, `macos/Tests/TermKitTests/FrameSchedulerTests.swift`

**Interfaces:**
- Consumes: `Terminal`, `GlyphAtlas`, `Palette`, `CPty.cpty_process_start_uptime`.
- Produces: `Shaders.source`, `CellInstance` (20 bytes, matches the shader), `InstanceFlags`, `Uniforms`, `Renderer` (`init(device:pixelFormat:atlas:palette:paddingPixels:library:)`, `Renderer.bundledLibrary(device:)`, `replaceAtlas`, `gridChanged(cols:rows:)`, `update(from:)`, `encode(commandBuffer:target:)`, `render(to:presented:)`, `renderOffscreen(width:height:)`, `palette`, `paddingPixels`, `cursorShapeOverride`, `cursorHidden`), `FrameScheduler(coalesce:now:schedule:render:)` with `requestFrame()`, `LatencyProbe` (`enabled`, `keyDown(at:)`, `frameCommitted(at:)`, `framePresented(at:)`, `report()`, `LatencyProbe.mark`, `LatencyProbe.log`).

- [ ] **Step 1: Write the failing tests**

```swift
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
```

```swift
import XCTest
@testable import TermKit

final class FrameSchedulerTests: XCTestCase {
    func testRendersImmediatelyThenCoalesces() {
        var now: TimeInterval = 10
        var scheduled: [(TimeInterval, () -> Void)] = []
        var renders = 0
        let scheduler = FrameScheduler(coalesce: 0.001, now: { now }, schedule: { delay, block in scheduled.append((delay, block)) },
                                       render: { renders += 1 })
        scheduler.requestFrame()
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(scheduled.count, 0)
        now += 0.0002
        scheduler.requestFrame()
        scheduler.requestFrame()
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(scheduled[0].0, 0.0008, accuracy: 1e-9)
        now += 0.0008
        scheduled[0].1()
        XCTAssertEqual(renders, 2)
        now += 0.005
        scheduler.requestFrame()
        XCTAssertEqual(renders, 3)
        XCTAssertEqual(scheduled.count, 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RendererTests` from `macos/`
Expected: compile error, `Renderer` not found.

- [ ] **Step 3: Write the implementation**

`macos/Sources/TermKit/Shaders.swift`:

```swift
/// The Metal shader source, embedded so a build without the Metal
/// toolchain can still compile it at runtime. `scripts/build-shaders.sh`
/// precompiles the same text into `default.metallib`.
public enum Shaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct CellInstance { ushort col; ushort row; uint glyph; uint fg; uint bg; uint flags; };
    struct GlyphRect { ushort x; ushort y; ushort w; ushort h; };
    struct Uniforms {
        float4 cursor;
        float4 cursorColor;
        float4 selectionColor;
        float2 cellSize;
        float2 viewport;
        float2 padding;
        float2 atlasSize;
    };
    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float2 local;
        float4 fg;
        float4 bg;
        uint flags [[flat]];
    };

    constant uint FLAG_WIDE = 1;
    constant uint FLAG_UNDERLINE = 2;
    constant uint FLAG_STRIKE = 4;
    constant uint FLAG_DIM = 8;
    constant uint FLAG_COLOR = 16;
    constant uint FLAG_SELECTED = 32;
    constant uint FLAG_HIDDEN = 64;
    constant uint FLAG_CURSOR = 128;

    static float4 unpack(uint c) {
        return float4(c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF, (c >> 24) & 0xFF) / 255.0;
    }

    vertex VertexOut cell_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device CellInstance* cells [[buffer(0)]],
                                 const device GlyphRect* rects [[buffer(1)]],
                                 constant Uniforms& u [[buffer(2)]]) {
        CellInstance c = cells[iid];
        float2 corner = float2((vid == 1 || vid == 2 || vid == 4) ? 1.0 : 0.0,
                               (vid == 2 || vid == 4 || vid == 5) ? 1.0 : 0.0);
        uint flags = c.flags;
        float w = (flags & FLAG_WIDE) ? 2.0 * u.cellSize.x : u.cellSize.x;
        float2 origin = u.padding + float2(c.col * u.cellSize.x, c.row * u.cellSize.y);
        float2 size = (flags & FLAG_HIDDEN) ? float2(0.0) : float2(w, u.cellSize.y);
        float2 pixel = origin + corner * size;
        float2 ndc = float2(pixel.x / u.viewport.x * 2.0 - 1.0, 1.0 - pixel.y / u.viewport.y * 2.0);
        GlyphRect r = rects[c.glyph];
        float4 fg = unpack(c.fg);
        float4 bg = unpack(c.bg);
        if (flags & FLAG_SELECTED) { bg = u.selectionColor; }
        bool isCursor = u.cursor.w > 0.5 && c.col == uint(u.cursor.x) && c.row == uint(u.cursor.y);
        if (isCursor) {
            flags |= FLAG_CURSOR;
            if (u.cursor.z < 0.5) { fg = bg; bg = u.cursorColor; }
        }
        VertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = (float2(r.x, r.y) + corner * float2(r.w, r.h)) / u.atlasSize;
        out.local = corner * size;
        out.fg = fg;
        out.bg = bg;
        out.flags = flags;
        return out;
    }

    fragment float4 cell_fragment(VertexOut in [[stage_in]],
                                  texture2d<float> atlas [[texture(0)]],
                                  constant Uniforms& u [[buffer(2)]]) {
        constexpr sampler s(mag_filter::nearest, min_filter::nearest);
        float4 t = atlas.sample(s, in.uv);
        float4 glyph = (in.flags & FLAG_COLOR) ? t : float4(in.fg.rgb * t.a, t.a);
        if (in.flags & FLAG_DIM) { glyph *= 0.6; }
        float4 color = in.bg * (1.0 - glyph.a) + glyph;
        float thickness = max(1.0, floor(u.cellSize.y / 14.0));
        float y = in.local.y;
        if ((in.flags & FLAG_UNDERLINE) && y >= u.cellSize.y - thickness) { color = in.fg; }
        if ((in.flags & FLAG_STRIKE) && fabs(y - u.cellSize.y * 0.5) < thickness * 0.5) { color = in.fg; }
        if (in.flags & FLAG_CURSOR) {
            if (u.cursor.z == 1.0 && y >= u.cellSize.y - thickness * 2.0) { color = u.cursorColor; }
            if (u.cursor.z == 2.0 && in.local.x < thickness * 2.0) { color = u.cursorColor; }
        }
        return float4(color.rgb, 1.0);
    }
    """
}
```

`macos/Sources/TermKit/Renderer.swift`:

```swift
import CTermCore
import Foundation
import Metal
import QuartzCore
import simd

/// One instance per cell. Layout matches `CellInstance` in the shader.
public struct CellInstance {
    public var col: UInt16
    public var row: UInt16
    public var glyph: UInt32
    public var fg: UInt32
    public var bg: UInt32
    public var flags: UInt32
}

public enum InstanceFlags {
    public static let wide: UInt32 = 1
    public static let underline: UInt32 = 2
    public static let strike: UInt32 = 4
    public static let dim: UInt32 = 8
    public static let color: UInt32 = 16
    public static let selected: UInt32 = 32
    public static let hidden: UInt32 = 64
}

/// Per frame constants. Layout matches `Uniforms` in the shader.
public struct Uniforms {
    public var cursor: SIMD4<Float>
    public var cursorColor: SIMD4<Float>
    public var selectionColor: SIMD4<Float>
    public var cellSize: SIMD2<Float>
    public var viewport: SIMD2<Float>
    public var padding: SIMD2<Float>
    public var atlasSize: SIMD2<Float>
}

/// One pipeline, one instanced draw per frame. The CPU side keeps a
/// persistent instance array and rewrites only the rows the core marked
/// dirty; the whole array is then copied into one of three GPU buffers.
public final class Renderer {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public private(set) var atlas: GlyphAtlas
    public var palette: Palette
    public var paddingPixels: Float
    public var cursorShapeOverride: UInt8?
    /// Set by the view while blinking hides the cursor.
    public var cursorHidden = false

    private let pipeline: MTLRenderPipelineState
    private var instances: [CellInstance] = []
    private var instanceBuffers: [MTLBuffer] = []
    private var frameIndex = 0
    private let inflight = DispatchSemaphore(value: 3)
    private var rectBuffer: MTLBuffer
    private var rectsUploaded = 0
    private var cells: [UInt64] = []
    private var dirty: [UInt64] = []
    private var cursor = CursorInfo(col: 0, row: 0, shape: 0, blink: false, visible: true)
    public private(set) var cols = 0
    public private(set) var rows = 0

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat, atlas: GlyphAtlas, palette: Palette, paddingPixels: Float,
                library: MTLLibrary? = nil) throws {
        self.device = device
        self.atlas = atlas
        self.palette = palette
        self.paddingPixels = paddingPixels
        queue = device.makeCommandQueue()!
        let lib = try library ?? device.makeLibrary(source: Shaders.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "cells"
        descriptor.vertexFunction = lib.makeFunction(name: "cell_vertex")
        descriptor.fragmentFunction = lib.makeFunction(name: "cell_fragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        rectBuffer = device.makeBuffer(length: 1024 * MemoryLayout<GlyphRect>.stride, options: .storageModeShared)!
    }

    /// Loads a precompiled library from the app bundle when present.
    public static func bundledLibrary(device: MTLDevice) -> MTLLibrary? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("default.metallib"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? device.makeLibrary(URL: url)
    }

    /// Replaces the atlas, for example after a font size or scale change.
    public func replaceAtlas(_ newAtlas: GlyphAtlas) {
        atlas = newAtlas
        rectsUploaded = 0
        markAllDirty()
    }

    public func gridChanged(cols: Int, rows: Int) {
        guard cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        instances = (0..<(cols * rows)).map { i in
            CellInstance(col: UInt16(i % cols), row: UInt16(i / cols), glyph: 0, fg: palette.foreground,
                         bg: palette.background, flags: 0)
        }
        let length = max(1, instances.count) * MemoryLayout<CellInstance>.stride
        instanceBuffers = (0..<3).map { _ in device.makeBuffer(length: length, options: .storageModeShared)! }
        markAllDirty()
    }

    private func markAllDirty() {
        dirty = [UInt64](repeating: .max, count: max(1, (rows + 63) / 64))
    }

    /// Pulls the visible grid, dirty rows and cursor from the terminal
    /// and rebuilds instances for the dirty rows.
    public func update(from terminal: Terminal) {
        if terminal.cols != cols || terminal.rows != rows {
            gridChanged(cols: terminal.cols, rows: terminal.rows)
        }
        terminal.copyGrid(into: &cells)
        var fresh: [UInt64] = []
        terminal.takeDirtyRows(into: &fresh)
        for (i, word) in fresh.enumerated() where i < dirty.count {
            dirty[i] |= word
        }
        cursor = terminal.cursor
        let overflow = terminal.overflowColors
        for row in 0..<rows where dirty[row / 64] & (1 << UInt64(row % 64)) != 0 {
            rebuildRow(row, overflow: overflow)
        }
        dirty = [UInt64](repeating: 0, count: dirty.count)
    }

    private func rebuildRow(_ row: Int, overflow: [TermRgb]) {
        for col in 0..<cols {
            let cell = Cell(raw: cells[row * cols + col])
            let cf = cell.flags
            var instance = CellInstance(col: UInt16(col), row: UInt16(row), glyph: 0, fg: 0, bg: 0, flags: 0)
            var fg = palette.resolve(cell.fg, overflow: overflow, isForeground: true)
            var bg = palette.resolve(cell.bg, overflow: overflow, isForeground: false)
            if cf.contains(.inverse) { swap(&fg, &bg) }
            instance.fg = fg
            instance.bg = bg
            var flags: UInt32 = 0
            if cell.selected { flags |= InstanceFlags.selected }
            if cf.contains(.wideSpacer) {
                instance.flags = flags | InstanceFlags.hidden
                instances[row * cols + col] = instance
                continue
            }
            var style: GlyphStyle = []
            if cf.contains(.bold) { style.insert(.bold) }
            if cf.contains(.italic) { style.insert(.italic) }
            let ref = atlas.glyph(for: cell.scalar, style: style, wide: cf.contains(.wide))
            instance.glyph = ref.index
            if ref.isColor { flags |= InstanceFlags.color }
            if cf.contains(.wide) { flags |= InstanceFlags.wide }
            if cf.contains(.underline) { flags |= InstanceFlags.underline }
            if cf.contains(.strike) { flags |= InstanceFlags.strike }
            if cf.contains(.dim) { flags |= InstanceFlags.dim }
            instance.flags = flags
            instances[row * cols + col] = instance
        }
    }

    private func uploadRects() {
        let needed = atlas.rects.count * MemoryLayout<GlyphRect>.stride
        if rectBuffer.length < needed {
            rectBuffer = device.makeBuffer(length: needed * 2, options: .storageModeShared)!
            rectsUploaded = 0
        }
        if rectsUploaded < atlas.rects.count {
            atlas.rects.withUnsafeBytes { raw in
                let offset = rectsUploaded * MemoryLayout<GlyphRect>.stride
                memcpy(rectBuffer.contents() + offset, raw.baseAddress! + offset, raw.count - offset)
            }
            rectsUploaded = atlas.rects.count
        }
    }

    private func unpack(_ c: UInt32) -> SIMD4<Float> {
        SIMD4<Float>(Float(c & 0xFF), Float(c >> 8 & 0xFF), Float(c >> 16 & 0xFF), Float(c >> 24 & 0xFF)) / 255
    }

    /// Encodes one frame into `target`. `viewport` is the target size in pixels.
    public func encode(commandBuffer: MTLCommandBuffer, target: MTLTexture) {
        uploadRects()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        let bgc = unpack(palette.background)
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bgc.x), green: Double(bgc.y), blue: Double(bgc.z), alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "cells"
        if !instances.isEmpty {
            let buffer = instanceBuffers[frameIndex % 3]
            instances.withUnsafeBytes { raw in memcpy(buffer.contents(), raw.baseAddress!, raw.count) }
            let shape = cursorShapeOverride ?? cursor.shape
            let visible = cursor.visible && !cursorHidden
            var uniforms = Uniforms(
                cursor: SIMD4<Float>(Float(cursor.col), Float(cursor.row), Float(shape), visible ? 1 : 0),
                cursorColor: unpack(palette.cursorColor),
                selectionColor: unpack(palette.selectionBackground),
                cellSize: SIMD2<Float>(Float(atlas.cellWidth), Float(atlas.cellHeight)),
                viewport: SIMD2<Float>(Float(target.width), Float(target.height)),
                padding: SIMD2<Float>(paddingPixels, paddingPixels),
                atlasSize: SIMD2<Float>(Float(atlas.texture.width), Float(atlas.texture.height)))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBuffer(rectBuffer, offset: 0, index: 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
        }
        encoder.endEncoding()
    }

    /// Renders one frame to a drawable. `presented` runs when the frame
    /// reaches the screen, on an arbitrary thread.
    public func render(to drawable: CAMetalDrawable, presented: ((CFTimeInterval) -> Void)? = nil) {
        inflight.wait()
        frameIndex += 1
        guard let commandBuffer = queue.makeCommandBuffer() else {
            inflight.signal()
            return
        }
        commandBuffer.label = "frame \(frameIndex)"
        encode(commandBuffer: commandBuffer, target: drawable.texture)
        let semaphore = inflight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        if let presented {
            drawable.addPresentedHandler { _ in presented(CACurrentMediaTime()) }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Renders into a texture and returns its BGRA8 pixels, for tests.
    public func renderOffscreen(width: Int, height: Int) -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = device.makeTexture(descriptor: descriptor)!
        let commandBuffer = queue.makeCommandBuffer()!
        frameIndex += 1
        encode(commandBuffer: commandBuffer, target: target)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return pixels
    }
}
```

`macos/Sources/TermKit/FrameScheduler.swift`:

```swift
import Foundation
import QuartzCore

/// Renders as soon as asked, but folds requests that arrive within the
/// coalescing window into one frame. Call `requestFrame` on the main thread.
public final class FrameScheduler {
    public let coalesce: TimeInterval
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let render: () -> Void
    private var lastRender: TimeInterval = -1
    private var pending = false

    public init(coalesce: TimeInterval = 0.001,
                now: @escaping () -> TimeInterval = { CACurrentMediaTime() },
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
                },
                render: @escaping () -> Void) {
        self.coalesce = coalesce
        self.now = now
        self.schedule = schedule
        self.render = render
    }

    public func requestFrame() {
        if pending { return }
        let elapsed = now() - lastRender
        if elapsed >= coalesce {
            fire()
        } else {
            pending = true
            schedule(coalesce - elapsed) { [weak self] in
                guard let self else { return }
                self.pending = false
                self.fire()
            }
        }
    }

    private func fire() {
        lastRender = now()
        render()
    }
}
```

`macos/Sources/TermKit/LatencyProbe.swift`:

```swift
import CPty
import Foundation
import QuartzCore

/// Measures keystroke to presented frame, and process start to first
/// frame, when `TERM_PROBE` is set. Reports to standard error.
public final class LatencyProbe {
    public static let enabled = ProcessInfo.processInfo.environment["TERM_PROBE"] != nil
    private var pendingKey: TimeInterval?
    private var samples: [Double] = []
    private var commitSamples: [Double] = []
    private var reportedStartup = false
    private let lock = NSLock()

    public init() {}

    private static let processStart = cpty_process_start_uptime()

    /// Logs how long after process start `label` was reached.
    public static func mark(_ label: String) {
        guard enabled else { return }
        log(String(format: "mark %@: %.1f ms", label, (CACurrentMediaTime() - processStart) * 1000))
    }

    public func keyDown(at timestamp: TimeInterval) {
        lock.lock()
        if pendingKey == nil { pendingKey = timestamp }
        lock.unlock()
    }

    /// Called when a frame's commands were handed to the GPU; measures
    /// the terminal's own pipeline without the display's refresh wait.
    public func frameCommitted(at time: TimeInterval) {
        lock.lock()
        if let key = pendingKey { commitSamples.append((time - key) * 1000) }
        lock.unlock()
    }

    public func framePresented(at time: TimeInterval) {
        lock.lock()
        if !reportedStartup {
            reportedStartup = true
            let start = cpty_process_start_uptime()
            if start > 0 {
                LatencyProbe.log(String(format: "startup: %.1f ms (process start to first frame)", (time - start) * 1000))
            }
        }
        if let key = pendingKey {
            samples.append((time - key) * 1000)
            pendingKey = nil
            if samples.count % 50 == 0 { reportLocked() }
        }
        lock.unlock()
    }

    public func report() {
        lock.lock()
        reportLocked()
        lock.unlock()
    }

    private func reportLocked() {
        guard !samples.isEmpty else { return }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        let commits = commitSamples.sorted()
        let commitMedian = commits.isEmpty ? 0 : commits[commits.count / 2]
        LatencyProbe.log(String(format: "latency: n=%d key-to-present median=%.2f ms p99=%.2f ms max=%.2f ms; key-to-commit median=%.2f ms",
                                sorted.count, median, p99, sorted.last!, commitMedian))
    }

    public static func log(_ line: String) {
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RendererTests` from `macos/` and `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FrameSchedulerTests` from `macos/`
Expected: 4 and 1 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/TermKit/Shaders.swift macos/Sources/TermKit/Renderer.swift macos/Sources/TermKit/FrameScheduler.swift macos/Sources/TermKit/LatencyProbe.swift macos/Tests/TermKitTests/RendererTests.swift macos/Tests/TermKitTests/FrameSchedulerTests.swift
git commit -m "feat(macos): one draw call Metal renderer with coalesced frames"
```

---

### Task 10: Session and view

**Files:**
- Create: `macos/Sources/TermKit/TerminalSession.swift`, `macos/Sources/TermKit/TerminalView.swift`

**Interfaces:**
- Consumes: everything from Tasks 2 to 9.
- Produces: `TerminalSession` (`init(config:command:cols:rows:)`, `terminal`, `pty`, `onOutput`, `onExit`, `start()`, `write`, `paste`, `resize`, `close`), `TerminalView` (`init(session:config:)`, `requestFrame()`, `defaultTitle`, actions `copy:`, `paste:`, `selectAll:`, `increaseFontSize:`, `decreaseFontSize:`, `resetFontSize:`).
- Probe hooks: `TERM_PROBE_KEYS=n` types n synthetic keys and quits; `TERM_SCREENSHOT=path` captures the window after 1.5 s and quits. Task 11 and the benchmarks depend on both.

- [ ] **Step 1: Write the session**

`macos/Sources/TermKit/TerminalSession.swift`:

```swift
import Foundation

/// A terminal plus the process on its pseudo terminal. Output arrives on
/// the reader thread and is parsed there; the main thread is only told
/// that something changed.
public final class TerminalSession {
    public let terminal: Terminal
    public let pty: Pty
    public let config: Config
    /// Runs on the main thread after output arrived, at most once per
    /// pending notification.
    public var onOutput: (() -> Void)?
    /// Runs on the main thread once the child has exited.
    public var onExit: (() -> Void)?
    private let notifyLock = NSLock()
    private var notifyPending = false

    /// `command` replaces the login shell (argv, program first).
    public init(config: Config, command: [String]?, cols: Int, rows: Int) throws {
        self.config = config
        terminal = Terminal(cols: cols, rows: rows, scrollback: config.scrollback)
        let program: String
        let arguments: [String]
        if let command, let first = command.first {
            program = first
            arguments = command
        } else {
            program = config.shell ?? Pty.loginShell
            arguments = ["-" + (program as NSString).lastPathComponent]
        }
        pty = try Pty(program: program, arguments: arguments, environment: Pty.childEnvironment(), cols: cols, rows: rows)
        LatencyProbe.mark("shell spawned")
    }

    public func start() {
        pty.startReading(onData: { [weak self] bytes in
            guard let self else { return }
            self.terminal.feed(bytes)
            let replies = self.terminal.drainResponses()
            if !replies.isEmpty { self.pty.write(replies) }
            self.notifyLock.lock()
            let already = self.notifyPending
            self.notifyPending = true
            self.notifyLock.unlock()
            if !already {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.notifyLock.lock()
                    self.notifyPending = false
                    self.notifyLock.unlock()
                    self.onOutput?()
                }
            }
        }, onExit: { [weak self] in
            DispatchQueue.main.async { self?.onExit?() }
        })
    }

    public func write(_ bytes: [UInt8]) {
        pty.write(bytes)
    }

    public func write(_ text: String) {
        pty.write(Array(text.utf8))
    }

    /// Pastes text: newlines become carriage returns, and bracketed paste
    /// markers wrap it when the program asked for them.
    public func paste(_ text: String) {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if terminal.modes.bracketed_paste {
            write("\u{1B}[200~" + normalised + "\u{1B}[201~")
        } else {
            write(normalised)
        }
    }

    public func resize(cols: Int, rows: Int) {
        terminal.resize(cols: cols, rows: rows)
        pty.resize(cols: cols, rows: rows)
    }

    public func close() {
        pty.close()
    }
}
```

- [ ] **Step 2: Write the view**

`macos/Sources/TermKit/TerminalView.swift`:

```swift
import AppKit
import Metal
import QuartzCore

/// The terminal surface: a Metal layer driven by the renderer, plus
/// keyboard, text input, mouse and scroll handling.
public final class TerminalView: NSView, NSTextInputClient {
    public let session: TerminalSession
    public let config: Config
    public let palette: Palette
    public let probe = LatencyProbe()
    public var defaultTitle = "term"

    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice
    private var atlas: GlyphAtlas!
    private var atlasScale: CGFloat = 0
    private var atlasFontSize: CGFloat = 0
    private var renderer: Renderer!
    private var scheduler: FrameScheduler!
    private var fontSize: CGFloat
    private var scale: CGFloat = 2
    private var cols = 0
    private var rows = 0
    private var markedText = ""
    private var lastTitle = ""
    private var scrollAccumulator: CGFloat = 0
    private var blinkTimer: Timer?
    private var probeTimer: Timer?
    private var probeKeysLeft = 0

    public init(session: TerminalSession, config: Config) {
        self.session = session
        self.config = config
        palette = Palette(config: config)
        fontSize = CGFloat(config.fontSize)
        device = MTLCreateSystemDefaultDevice()!
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.displaySyncEnabled = false
        metalLayer.presentsWithTransaction = false
        metalLayer.isOpaque = true
        metalLayer.framebufferOnly = true
        rebuildAtlas()
        scheduler = FrameScheduler { [weak self] in self?.renderFrame() }
        session.onOutput = { [weak self] in self?.requestFrame() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    public override func makeBackingLayer() -> CALayer { metalLayer }
    public override var acceptsFirstResponder: Bool { true }
    public override var isOpaque: Bool { true }
    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() {}

    public var terminal: Terminal { session.terminal }
    public var cellSize: CGSize { CGSize(width: CGFloat(atlas.cellWidth) / scale, height: CGFloat(atlas.cellHeight) / scale) }

    // MARK: Layout and rendering

    /// Builds the atlas for the current scale and font size, once per change.
    private func rebuildAtlas() {
        let newScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if atlas != nil, newScale == atlasScale, fontSize == atlasFontSize { return }
        scale = newScale
        atlasScale = newScale
        atlasFontSize = fontSize
        metalLayer.contentsScale = scale
        let warn: (String) -> Void = { LatencyProbe.log($0) }
        atlas = GlyphAtlas(device: device, fontName: config.font, pointSize: fontSize, scale: scale,
                           lineHeight: CGFloat(config.lineHeight), warn: warn)
        LatencyProbe.mark("atlas built")
        if renderer == nil {
            renderer = try! Renderer(device: device, pixelFormat: .bgra8Unorm, atlas: atlas, palette: palette,
                                     paddingPixels: Float(config.padding * scale),
                                     library: Renderer.bundledLibrary(device: device))
            LatencyProbe.mark("pipeline built")
        } else {
            renderer.replaceAtlas(atlas)
            renderer.paddingPixels = Float(config.padding * scale)
        }
        switch config.cursorStyle {
        case .block: renderer.cursorShapeOverride = nil
        case .underline: renderer.cursorShapeOverride = 1
        case .bar: renderer.cursorShapeOverride = 2
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuildAtlas()
        updateGrid(force: true)
    }

    public override func layout() {
        super.layout()
        updateGrid(force: false)
    }

    private func updateGrid(force: Bool) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        metalLayer.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
        let pad = CGFloat(config.padding)
        let newCols = max(1, Int((size.width - 2 * pad) * scale / CGFloat(atlas.cellWidth)))
        let newRows = max(1, Int((size.height - 2 * pad) * scale / CGFloat(atlas.cellHeight)))
        if force || newCols != cols || newRows != rows {
            cols = newCols
            rows = newRows
            session.resize(cols: cols, rows: rows)
            renderer.gridChanged(cols: cols, rows: rows)
        }
        requestFrame()
    }

    public func requestFrame() {
        scheduler.requestFrame()
    }

    private var firstFrame = true

    private func renderFrame() {
        renderer.update(from: terminal)
        if firstFrame { firstFrame = false; LatencyProbe.mark("first frame") }
        guard let drawable = metalLayer.nextDrawable() else { return }
        renderer.render(to: drawable) { [probe] time in probe.framePresented(at: time) }
        probe.frameCommitted(at: CACurrentMediaTime())
        let title = terminal.title
        if title != lastTitle {
            lastTitle = title
            window?.title = title.isEmpty ? defaultTitle : title
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        rebuildAtlas()
        updateGrid(force: true)
        NotificationCenter.default.addObserver(self, selector: #selector(becameKey), name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(resignedKey), name: NSWindow.didResignKeyNotification, object: window)
        startProbeIfRequested()
    }

    @objc private func becameKey() {
        if terminal.modes.focus_events { session.write("\u{1B}[I") }
        startBlink()
    }

    @objc private func resignedKey() {
        if terminal.modes.focus_events { session.write("\u{1B}[O") }
        stopBlink()
    }

    private func startBlink() {
        guard config.cursorBlink, blinkTimer == nil else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.renderer.cursorHidden.toggle()
            self.requestFrame()
        }
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        renderer.cursorHidden = false
        requestFrame()
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        probe.keyDown(at: event.timestamp)
        terminal.scrollViewport(by: Int.min / 2)
        let input = KeyInput(characters: event.characters ?? "",
                             charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                             keyCode: event.keyCode, modifiers: TerminalView.modifiers(of: event))
        if let bytes = KeyEncoder.encode(input, modes: terminal.modes, altIsMeta: config.altIsMeta) {
            send(bytes)
        } else {
            interpretKeyEvents([event])
        }
    }

    static func modifiers(of event: NSEvent) -> KeyModifiers {
        var m: KeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }

    private func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        session.write(bytes)
    }

    // MARK: NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        send(Array(text.utf8))
    }

    public override func doCommand(by selector: Selector) {
        // Control and function keys never reach here: keyDown encodes them first.
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }

    public func unmarkText() { markedText = "" }
    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count)
    }
    public func hasMarkedText() -> Bool { !markedText.isEmpty }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let c = terminal.cursor
        let pad = CGFloat(config.padding)
        let rect = NSRect(x: pad + CGFloat(c.col) * cellSize.width, y: pad + CGFloat(c.row) * cellSize.height,
                          width: cellSize.width, height: cellSize.height)
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    // MARK: Mouse

    private func cell(at point: NSPoint) -> (col: Int, row: Int) {
        let pad = CGFloat(config.padding)
        let col = Int(((point.x - pad) / cellSize.width).rounded(.down))
        let row = Int(((point.y - pad) / cellSize.height).rounded(.down))
        return (min(max(col, 0), max(cols - 1, 0)), min(max(row, 0), max(rows - 1, 0)))
    }

    private func reporting(_ event: NSEvent) -> Bool {
        terminal.modes.mouse != 0 && !event.modifierFlags.contains(.shift)
    }

    private func report(_ button: MouseButton, event: NSEvent, pressed: Bool, motion: Bool = false) {
        let modes = terminal.modes
        if modes.mouse == 1 && (!pressed || motion) { return }
        if motion && modes.mouse < 3 { return }
        let (col, row) = cell(at: convert(event.locationInWindow, from: nil))
        send(MouseEncoder.encode(button: button, col: col, row: row, pressed: pressed, motion: motion,
                                 modifiers: TerminalView.modifiers(of: event), sgr: modes.mouse_sgr))
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let (col, row) = cell(at: convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.command) {
            openURL(col: col, row: row)
            return
        }
        if reporting(event) {
            report(.left, event: event, pressed: true)
            return
        }
        let mode: SelectionMode = event.clickCount >= 3 ? .line : (event.clickCount == 2 ? .word : .normal)
        terminal.selectionStart(col: col, row: row, mode: mode)
        requestFrame()
    }

    public override func mouseDragged(with event: NSEvent) {
        if reporting(event) {
            report(.left, event: event, pressed: true, motion: true)
            return
        }
        let (col, row) = cell(at: convert(event.locationInWindow, from: nil))
        terminal.selectionExtend(col: col, row: row)
        requestFrame()
    }

    public override func mouseUp(with event: NSEvent) {
        if reporting(event) {
            report(.left, event: event, pressed: false)
            return
        }
        if config.copyOnSelect { copySelection() }
    }

    public override func rightMouseDown(with event: NSEvent) {
        if reporting(event) { report(.right, event: event, pressed: true) }
    }

    public override func rightMouseUp(with event: NSEvent) {
        if reporting(event) { report(.right, event: event, pressed: false) }
    }

    public override func otherMouseDown(with event: NSEvent) {
        if reporting(event) { report(.middle, event: event, pressed: true) }
    }

    public override func otherMouseUp(with event: NSEvent) {
        if reporting(event) { report(.middle, event: event, pressed: false) }
    }

    public override func scrollWheel(with event: NSEvent) {
        let modes = terminal.modes
        let lineHeight = cellSize.height
        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= lineHeight }
        scrollAccumulator += delta
        let lines = Int((scrollAccumulator / lineHeight).rounded(.towardZero))
        guard lines != 0 else { return }
        scrollAccumulator -= CGFloat(lines) * lineHeight
        if reporting(event) {
            let button: MouseButton = lines > 0 ? .wheelUp : .wheelDown
            for _ in 0..<abs(lines) { report(button, event: event, pressed: true) }
        } else if modes.alt_screen {
            let key = lines > 0 ? "\u{1B}[A" : "\u{1B}[B"
            send(Array(String(repeating: key, count: abs(lines)).utf8))
        } else {
            terminal.scrollViewport(by: lines)
            requestFrame()
        }
    }

    private func openURL(col: Int, row: Int) {
        var cells: [UInt64] = []
        terminal.copyGrid(into: &cells)
        let start = row * cols
        let line = String(String.UnicodeScalarView(cells[start..<(start + cols)].map { Cell(raw: $0).scalar }))
        if let url = UrlDetector.url(in: line, at: col), let parsed = URL(string: url) {
            NSWorkspace.shared.open(parsed)
        }
    }

    // MARK: Actions

    @objc public func copy(_ sender: Any?) { copySelection() }

    private func copySelection() {
        let text = terminal.selectionText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc public func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) {
            terminal.scrollViewport(by: Int.min / 2)
            session.paste(text)
        }
    }

    public override func selectAll(_ sender: Any?) {
        terminal.selectionStart(col: 0, row: 0, mode: .normal)
        terminal.selectionExtend(col: cols - 1, row: rows - 1)
        requestFrame()
    }

    @objc public func increaseFontSize(_ sender: Any?) { setFontSize(fontSize + 1) }
    @objc public func decreaseFontSize(_ sender: Any?) { setFontSize(fontSize - 1) }
    @objc public func resetFontSize(_ sender: Any?) { setFontSize(CGFloat(config.fontSize)) }

    private func setFontSize(_ size: CGFloat) {
        fontSize = min(max(size, 4), 96)
        rebuildAtlas()
        updateGrid(force: true)
    }

    // MARK: Probe support

    /// `TERM_PROBE_KEYS=n` types n synthetic keys, prints latency stats
    /// and quits. `TERM_SCREENSHOT=path` captures the window and quits.
    private func startProbeIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let keys = env["TERM_PROBE_KEYS"].flatMap(Int.init), keys > 0, probeTimer == nil {
            probeKeysLeft = keys
            probeTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
                guard let self, let window = self.window else { return }
                if self.probeKeysLeft == 0 {
                    self.probeTimer?.invalidate()
                    self.probe.report()
                    NSApp.terminate(nil)
                    return
                }
                self.probeKeysLeft -= 1
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: "a",
                                                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0) {
                    self.keyDown(with: event)
                }
            }
        }
        if let path = env["TERM_SCREENSHOT"], let window {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-l", "\(window.windowNumber)", "-x", "-o", path]
                try? task.run()
                task.waitUntilExit()
                NSApp.terminate(nil)
            }
        }
    }
}
```

- [ ] **Step 3: Build and run the whole suite**

Run: `swift build` from `macos/`, then `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` from `macos/`
Expected: no warnings; 37 tests, 0 failures. There are no unit tests for the view; Task 11 verifies it on screen.

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/TermKit/TerminalSession.swift macos/Sources/TermKit/TerminalView.swift
git commit -m "feat(macos): terminal session and Metal backed view"
```

---

### Task 11: Window, menu, app and bundle

**Files:**
- Create: `macos/Sources/TermKit/TerminalWindowController.swift`, `macos/Sources/TermKit/AppMenu.swift`, `macos/scripts/bundle.sh`, `macos/scripts/run.sh`, `macos/scripts/screenshot.sh`
- Modify: `macos/Sources/Term/main.swift` (replace the placeholder)

**Interfaces:**
- Produces: `TerminalWindowController(config:command:)` with `show()` and the static `open` list, `AppMenu.build(appName:)`, the `Term` executable accepting `-e program [args...]` and `--version`, `build/Term.app`.

- [ ] **Step 1: Write the window controller and menu**

`macos/Sources/TermKit/TerminalWindowController.swift`:

```swift
import AppKit

/// One window, one shell.
public final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    public static var open: [TerminalWindowController] = []
    public let session: TerminalSession
    public let terminalView: TerminalView

    public init(config: Config, command: [String]?) throws {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let m = GlyphAtlas.metrics(fontName: config.font, pointSize: CGFloat(config.fontSize), scale: scale,
                                   lineHeight: CGFloat(config.lineHeight))
        let pad = CGFloat(config.padding)
        let size = NSSize(width: CGFloat(80 * m.cellWidth) / scale + 2 * pad,
                          height: CGFloat(24 * m.cellHeight) / scale + 2 * pad)
        session = try TerminalSession(config: config, command: command, cols: 80, rows: 24)
        terminalView = TerminalView(session: session, config: config)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "term"
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.contentView = terminalView
        window.center()
        super.init(window: window)
        window.delegate = self
        session.onExit = { [weak self] in self?.close() }
        session.start()
        TerminalWindowController.open.append(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    public func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(terminalView)
    }

    public func windowWillClose(_ notification: Notification) {
        session.close()
        TerminalWindowController.open.removeAll { $0 === self }
    }
}
```

`macos/Sources/TermKit/AppMenu.swift`:

```swift
import AppKit

/// The menu bar. Actions travel the responder chain to the view or the
/// app delegate.
public enum AppMenu {
    public static func build(appName: String = "Term") -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: appName))

        let shell = NSMenu(title: "Shell")
        shell.addItem(withTitle: "New Window", action: Selector(("newWindow:")), keyEquivalent: "n")
        shell.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(shell, title: "Shell"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Bigger", action: #selector(TerminalView.increaseFontSize(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Smaller", action: #selector(TerminalView.decreaseFontSize(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(TerminalView.resetFontSize(_:)), keyEquivalent: "0")
        view.addItem(.separator())
        let full = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu(view, title: "View"))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
```

- [ ] **Step 2: Replace the entry point**

`macos/Sources/Term/main.swift`:

```swift
import AppKit
import Metal
import TermKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let config: Config
    let command: [String]?

    init(config: Config, command: [String]?) {
        self.config = config
        self.command = command
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LatencyProbe.mark("did finish launching")
        openWindow(command: command)
        LatencyProbe.mark("window shown")
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func newWindow(_ sender: Any?) {
        openWindow(command: nil)
    }

    private func openWindow(command: [String]?) {
        do {
            let controller = try TerminalWindowController(config: config, command: command)
            controller.show()
        } catch {
            LatencyProbe.log("could not start the shell: \(error)")
            if TerminalWindowController.open.isEmpty { NSApp.terminate(nil) }
        }
    }
}

LatencyProbe.mark("main")
var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--version" {
    print("term \(TermKitVersion.string)")
    exit(0)
}
var command: [String]? = nil
if let e = arguments.firstIndex(of: "-e") {
    command = Array(arguments[(e + 1)...])
    if command?.isEmpty == true {
        FileHandle.standardError.write("usage: term [-e program [args...]]\n".data(using: .utf8)!)
        exit(2)
    }
}

guard MTLCreateSystemDefaultDevice() != nil else {
    FileHandle.standardError.write("term needs a Metal capable GPU and none is available\n".data(using: .utf8)!)
    exit(1)
}
let config = Config.load(warn: { LatencyProbe.log($0) })
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(config: config, command: command)
app.delegate = delegate
app.mainMenu = AppMenu.build()
LatencyProbe.mark("app configured")
app.run()
```

- [ ] **Step 3: Write the bundle, run and screenshot scripts**

`macos/scripts/bundle.sh`:

```sh
#!/bin/sh
# Builds the release binary and assembles build/Term.app with an ad hoc
# signature, so it launches without prompts. A precompiled shader
# library is included when scripts/build-shaders.sh produced one.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/TermKit/Version.swift)
if [ "${1:-}" = "--universal" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BINARY=.build/apple/Products/Release/Term
else
    swift build -c release
    BINARY=.build/release/Term
fi
APP=build/Term.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Term"
if [ -f build/default.metallib ]; then
    cp build/default.metallib "$APP/Contents/Resources/default.metallib"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.term.app</string>
    <key>CFBundleName</key><string>Term</string>
    <key>CFBundleDisplayName</key><string>Term</string>
    <key>CFBundleExecutable</key><string>Term</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" 2>/dev/null
echo "built $APP"
```

`macos/scripts/run.sh`:

```sh
#!/bin/sh
# Builds everything and launches the app from its bundle, passing
# through any arguments (for example -e /bin/zsh -l).
set -eu
cd "$(dirname "$0")/.."
scripts/build-core.sh >/dev/null
scripts/build-shaders.sh >/dev/null || true
scripts/bundle.sh >/dev/null
exec build/Term.app/Contents/MacOS/Term "$@"
```

`macos/scripts/screenshot.sh`:

```sh
#!/bin/sh
# Runs a command in the terminal, captures the window after 1.5 s and
# writes a PNG. Usage: scripts/screenshot.sh OUT.png COMMAND [ARGS...]
set -eu
cd "$(dirname "$0")/.."
out=$1
shift
TERM_SCREENSHOT="$out" build/Term.app/Contents/MacOS/Term -e /bin/sh -c "$*; sleep 3"
echo "wrote $out"
```

Make all three executable: `chmod +x macos/scripts/*.sh`.

- [ ] **Step 4: Build the bundle and take a screenshot**

Run from `macos/`:

```bash
scripts/bundle.sh
scripts/screenshot.sh build/first.png 'printf "hello \033[1;31mbold red\033[0m \033[4munderline\033[0m \033[7minverse\033[0m\n\033[38;2;80;200;120mtruecolor\033[0m 日本語 👍 ❤️ done\n"'
```

Expected: `wrote build/first.png`. Open the image (the Read tool shows it): a window titled `term` with a black background, line one `hello bold red underline inverse` where `bold red` is bold and red, `underline` is underlined and `inverse` is grey on light, line two `truecolor` in green, the three CJK glyphs each two cells wide, a colour thumbs up, a red heart, `done`, and a white block cursor at the start of line three. Describe what you see in the report.

- [ ] **Step 5: Check the probes end the process**

Run: `TERM_PROBE=1 TERM_PROBE_KEYS=50 build/Term.app/Contents/MacOS/Term -e /bin/cat`
Expected: the process exits by itself within a few seconds and prints a `startup:` line and a `latency:` line on standard error with a `key-to-commit median` under 2 ms.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources macos/scripts
git commit -m "feat(macos): window, menu, entry point and app bundle"
```

---

### Task 12: Precompiled shaders

**Files:**
- Create: `macos/scripts/build-shaders.sh`

**Interfaces:**
- Produces: `build/default.metallib` when the Metal toolchain is installed; `bundle.sh` (Task 11) already copies it into the app and `Renderer.bundledLibrary` (Task 9) already loads it.

- [ ] **Step 1: Write the script**

```sh
#!/bin/sh
# Precompiles the embedded shader source into build/default.metallib so
# the app skips the runtime compile at startup. Needs Xcode's Metal
# toolchain (xcodebuild -downloadComponent MetalToolchain). Without it
# the app compiles the shader at runtime instead, and this script says so.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build
if ! xcrun -sdk macosx -f metal >/dev/null 2>&1; then
    echo "metal compiler not available; the app will compile shaders at runtime"
    exit 0
fi
# Extract the shader text between the triple quotes in Shaders.swift.
awk '/public static let source = """/{f=1; next} /^    """/{f=0} f' Sources/TermKit/Shaders.swift \
    | sed 's/^    //' > build/cells.metal
xcrun -sdk macosx metal -c build/cells.metal -o build/cells.air
xcrun -sdk macosx metallib build/cells.air -o build/default.metallib
echo "built build/default.metallib"
```

`chmod +x macos/scripts/build-shaders.sh`.

- [ ] **Step 2: Run it**

Run from `macos/`: `scripts/build-shaders.sh`
Expected, without the toolchain: `metal compiler not available; the app will compile shaders at runtime`, exit 0. With it: `built build/default.metallib`; then `scripts/bundle.sh` and `TERM_PROBE=1 TERM_SCREENSHOT=/dev/null build/Term.app/Contents/MacOS/Term -e /bin/sleep 1` shows `mark pipeline built` within 2 ms of `mark atlas built` on a cold cache. Report which case you hit.

- [ ] **Step 3: Commit**

```bash
git add macos/scripts/build-shaders.sh
git commit -m "build(macos): precompile the shader library when the toolchain exists"
```

---

### Task 13: Shell benchmarks

**Files:**
- Create: `bench-shell/startup.sh`, `bench-shell/latency.sh`, `bench-shell/throughput.sh`, `bench-shell/memory.sh`, `bench-shell/results.md`

- [ ] **Step 1: Write the scripts**

`bench-shell/startup.sh`:

```sh
#!/bin/sh
# Median warm launch time (process start to first presented frame) over
# five runs of the bundled app. Prints one number in milliseconds.
set -eu
cd "$(dirname "$0")/../macos"
BIN=build/Term.app/Contents/MacOS/Term
TERM_PROBE=1 TERM_SCREENSHOT=/dev/null "$BIN" -e /bin/sleep 1 >/dev/null 2>&1 || true
for i in 1 2 3 4 5; do
    TERM_PROBE=1 TERM_SCREENSHOT=/dev/null "$BIN" -e /bin/sleep 1 2>&1 | sed -n 's/^startup: \([0-9.]*\) ms.*/\1/p'
done | sort -n | sed -n '3p'
```

`bench-shell/latency.sh`:

```sh
#!/bin/sh
# Keystroke latency: 200 synthetic keys echoed by the tty. Prints the
# probe's summary line: key to GPU commit is the terminal's own cost,
# key to present includes the display's refresh wait.
set -eu
cd "$(dirname "$0")/../macos"
TERM_PROBE=1 TERM_PROBE_KEYS=200 build/Term.app/Contents/MacOS/Term -e /bin/cat 2>&1 | grep '^latency' | tail -1
```

`bench-shell/throughput.sh`:

```sh
#!/bin/sh
# Time to cat a 100 MB text file through the terminal. Also runs the
# same file through Ghostty and Alacritty when they are installed.
set -eu
cd "$(dirname "$0")/../macos"
BIG=/tmp/term-bench-100mb.txt
if [ ! -f "$BIG" ]; then
    python3 -c "
import sys
line = ('the quick brown fox jumps over the lazy dog 0123456789 ' * 2) + '\n'
sys.stdout.write(line * (100 * 1024 * 1024 // len(line)))" > "$BIG"
fi
OUT=/tmp/term-bench-throughput.txt
rm -f "$OUT"
build/Term.app/Contents/MacOS/Term -e /bin/sh -c "( time cat $BIG ) 2> $OUT"
printf 'term: '; grep real "$OUT"
for app in Ghostty Alacritty; do
    if [ -d "/Applications/$app.app" ]; then
        rm -f "$OUT"
        open -W -n "/Applications/$app.app" --args -e /bin/sh -c "( time cat $BIG ) 2> $OUT"
        printf '%s: ' "$app"; grep real "$OUT" || echo "no result"
    fi
done
```

`bench-shell/memory.sh`:

```sh
#!/bin/sh
# Resident memory of the idle app after two seconds, in MB.
set -eu
cd "$(dirname "$0")/../macos"
build/Term.app/Contents/MacOS/Term -e /bin/sleep 4 >/dev/null 2>&1 &
sleep 2
ps -o rss= -p "$!" | awk '{printf "%.0f MB\n", $1 / 1024}'
wait
```

`chmod +x bench-shell/*.sh`.

- [ ] **Step 2: Write the results file and run everything**

`bench-shell/results.md`:

```markdown
# Shell benchmarks

Run each script from the repository root after `macos/scripts/bundle.sh`.
Latency splits into the terminal's own cost (key to GPU commit) and the
display's refresh wait (key to presented frame); the second depends on
the monitor. Add a row whenever a change affects performance.

| date | commit | machine and display | startup warm | key to commit | key to present | 100 MB cat | idle RSS |
|---|---|---|---|---|---|---|---|
| 2026-09-17 | pre-plan spike | Apple M4, 60 Hz 1080p external | 100 ms | 0.47 ms | 7.3 ms | 0.75 s | 74 MB |
```

Run from the repository root: `bench-shell/startup.sh`, `bench-shell/latency.sh`, `bench-shell/throughput.sh`, `bench-shell/memory.sh`. Add a row with today's date, `git rev-parse --short HEAD`, `sysctl -n machdep.cpu.brand_string` plus the display, and the numbers printed. Expected: startup under 110 ms, key to commit under 2 ms, cat under 1.5 s, RSS under 90 MB. Anything worse is a finding for the report, not something to tune here.

- [ ] **Step 3: Commit**

```bash
git add bench-shell
git commit -m "bench(shell): startup, latency, throughput and memory scripts"
```

---

### Task 14: Release packaging

**Files:**
- Create: `macos/scripts/release.sh`, `macos/packaging/term.rb`

- [ ] **Step 1: Write the release script and cask template**

`macos/scripts/release.sh`:

```sh
#!/bin/sh
# Universal release: fat core library, universal binary, signed and
# notarised bundle, and a dmg. Signing and notarisation run only when the
# environment provides them:
#   TERM_SIGN_IDENTITY   Developer ID Application certificate name
#   TERM_NOTARY_PROFILE  notarytool keychain profile name
# Without them the bundle is ad hoc signed and the dmg still builds.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/TermKit/Version.swift)
scripts/build-core.sh --universal
scripts/build-shaders.sh || true
scripts/bundle.sh --universal
APP=build/Term.app
if [ -n "${TERM_SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$TERM_SIGN_IDENTITY" "$APP"
fi
rm -rf build/dmg && mkdir -p build/dmg && cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
DMG="build/Term-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Term" -srcfolder build/dmg -ov -format UDZO "$DMG" >/dev/null
if [ -n "${TERM_SIGN_IDENTITY:-}" ] && [ -n "${TERM_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$TERM_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi
echo "built $DMG"
```

`macos/packaging/term.rb` (fill in the sha256 and URL when a release is published):

```ruby
cask "term" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_OF_THE_DMG"

  url "https://example.invalid/term/releases/download/v#{version}/Term-#{version}.dmg"
  name "Term"
  desc "Light and fast terminal emulator"
  homepage "https://example.invalid/term"

  depends_on macos: ">= :sonoma"

  app "Term.app"

  zap trash: "~/.config/term"
end
```

`chmod +x macos/scripts/release.sh`.

- [ ] **Step 2: Run the release script without credentials**

Run from `macos/`: `scripts/release.sh`
Expected: it installs the x86_64 Rust target if missing, builds a fat core archive, a universal binary (`lipo -info build/Term.app/Contents/MacOS/Term` lists `x86_64 arm64`), an ad hoc signed bundle and `build/Term-0.1.0.dmg`. Then run `scripts/build-core.sh` again so the arm64 archive is back in use for development.

- [ ] **Step 3: Commit**

```bash
git add macos/scripts/release.sh macos/packaging/term.rb
git commit -m "build(macos): universal release script and cask template"
```

---

## Done criteria for this plan

- `swift build` is warning free and `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` passes all 37 tests.
- `macos/scripts/run.sh` opens a working terminal: a login shell, colours, wide glyphs, emoji, selection, copy and paste, scrollback with the wheel, cmd-click URLs, font zoom, new window, full screen.
- `bench-shell/results.md` has a measured row for the built app.
- `scripts/release.sh` produces a universal dmg without credentials.

Known deviation from the spec, to rule on later: a shell that fails to spawn is logged to standard error and the app quits when no other window is open, instead of showing the error inside the window and waiting for a keypress.

Open items carried from the core plan remain: CI fuzz runs once the repository has a remote, real-program compat recordings captured through this shell, an attribute plane for snapshots, and core hot-path profiling.
