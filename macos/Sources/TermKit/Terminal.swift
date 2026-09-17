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
