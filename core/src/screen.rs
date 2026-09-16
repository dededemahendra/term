//! Screen state: cursor, modes, attributes, scroll region and the
//! alternate screen. Implements `vte::Perform`, so the parser drives
//! it directly.

use unicode_width::UnicodeWidthChar;
use vte::{Params, Perform};

use crate::cell::{flags, Cell, DEFAULT_COLOR};
use crate::grid::Grid;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Cursor {
    pub col: usize,
    pub row: usize,
    /// Set after printing in the last column. The next printable
    /// character wraps first when autowrap is on.
    pub pending_wrap: bool,
}

/// Mode flags the shell needs. `#[repr(C)]` with one-byte fields only,
/// so it crosses the C ABI unchanged.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Modes {
    pub bracketed_paste: bool,
    /// 0 off, 1 X10 (mode 9), 2 normal (1000), 3 button (1002), 4 any (1003).
    pub mouse: u8,
    /// SGR mouse encoding (1006).
    pub mouse_sgr: bool,
    /// DECCKM.
    pub app_cursor: bool,
    /// DECKPAM.
    pub app_keypad: bool,
    /// Mode 1004.
    pub focus_events: bool,
    pub alt_screen: bool,
    /// DECOM.
    pub origin: bool,
    /// DECAWM.
    pub autowrap: bool,
    /// IRM.
    pub insert: bool,
    /// DECTCEM.
    pub cursor_visible: bool,
    pub cursor_blink: bool,
    /// 0 block, 1 underline, 2 bar.
    pub cursor_shape: u8,
}

impl Default for Modes {
    fn default() -> Self {
        Modes {
            bracketed_paste: false,
            mouse: 0,
            mouse_sgr: false,
            app_cursor: false,
            app_keypad: false,
            focus_events: false,
            alt_screen: false,
            origin: false,
            autowrap: true,
            insert: false,
            cursor_visible: true,
            cursor_blink: false,
            cursor_shape: 0,
        }
    }
}

fn default_tabs(cols: usize) -> Vec<bool> {
    (0..cols).map(|c| c % 8 == 0).collect()
}

/// Parameter `index`, with 0 and absent both meaning `default`.
fn param(params: &Params, index: usize, default: u16) -> u16 {
    match params.iter().nth(index).and_then(|p| p.first().copied()) {
        Some(0) | None => default,
        Some(v) => v,
    }
}

/// Parameter `index`, 0 when absent. For selectors where 0 is meaningful.
fn param0(params: &Params, index: usize) -> u16 {
    params.iter().nth(index).and_then(|p| p.first().copied()).unwrap_or(0)
}

pub struct Screen {
    primary: Grid,
    alt: Grid,
    cursor: Cursor,
    /// Current SGR attributes. The codepoint field is ignored.
    template: Cell,
    scroll_top: usize,
    scroll_bottom: usize,
    tabs: Vec<bool>,
    modes: Modes,
    responses: Vec<u8>,
    last_char: Option<char>,
}

impl Screen {
    pub fn new(cols: usize, rows: usize, scrollback: usize) -> Screen {
        let cols = cols.max(1);
        let rows = rows.max(1);
        Screen {
            primary: Grid::new(cols, rows, scrollback),
            alt: Grid::new(cols, rows, 0),
            cursor: Cursor::default(),
            template: Cell::default(),
            scroll_top: 0,
            scroll_bottom: rows - 1,
            tabs: default_tabs(cols),
            modes: Modes::default(),
            responses: Vec::new(),
            last_char: None,
        }
    }

    pub fn grid(&self) -> &Grid {
        if self.modes.alt_screen {
            &self.alt
        } else {
            &self.primary
        }
    }

    pub fn grid_mut(&mut self) -> &mut Grid {
        if self.modes.alt_screen {
            &mut self.alt
        } else {
            &mut self.primary
        }
    }

    pub fn cols(&self) -> usize {
        self.primary.cols()
    }

    pub fn rows(&self) -> usize {
        self.primary.rows()
    }

    pub fn cursor(&self) -> Cursor {
        self.cursor
    }

    pub fn modes(&self) -> Modes {
        self.modes
    }

    pub fn template(&self) -> Cell {
        self.template
    }

    /// Text of screen row `r`: wide spacers dropped, trailing blanks trimmed.
    pub fn row_text(&self, r: usize) -> String {
        let text: String = self
            .grid()
            .row(r)
            .cells()
            .iter()
            .filter(|c| !c.has(flags::WIDE_SPACER))
            .map(|c| c.codepoint())
            .collect();
        text.trim_end().to_string()
    }

    /// Cell used for erased and newly exposed positions: current
    /// background colour, nothing else.
    fn blank(&self) -> Cell {
        Cell::new(' ', 0, DEFAULT_COLOR, self.template.bg())
    }

    fn linefeed(&mut self) {
        self.cursor.pending_wrap = false;
        if self.cursor.row == self.scroll_bottom {
            let (top, bottom, blank) = (self.scroll_top, self.scroll_bottom, self.blank());
            self.grid_mut().scroll_up_region(top, bottom, 1, blank);
        } else if self.cursor.row < self.rows() - 1 {
            self.cursor.row += 1;
        }
    }

    fn carriage_return(&mut self) {
        self.cursor.col = 0;
        self.cursor.pending_wrap = false;
    }

    fn backspace(&mut self) {
        self.cursor.col = self.cursor.col.saturating_sub(1);
        self.cursor.pending_wrap = false;
    }

    fn tab_forward(&mut self) {
        let cols = self.cols();
        let mut c = self.cursor.col + 1;
        while c < cols - 1 && !self.tabs[c] {
            c += 1;
        }
        self.cursor.col = c.min(cols - 1);
        self.cursor.pending_wrap = false;
    }

    /// If `col` holds half of a wide glyph, blank the other half so no
    /// orphaned WIDE or WIDE_SPACER cell survives an overwrite.
    fn split_wide(&mut self, col: usize, row: usize) {
        let cols = self.cols();
        let cell = self.grid().cell(col, row);
        let blank = self.blank();
        if cell.has(flags::WIDE_SPACER) && col > 0 {
            self.grid_mut().set_cell(col - 1, row, blank);
        }
        if cell.has(flags::WIDE) && col + 1 < cols {
            self.grid_mut().set_cell(col + 1, row, blank);
        }
    }

    /// Writes one glyph of `width` (1 or 2) columns at the cursor.
    fn put_char(&mut self, c: char, width: usize) {
        let cols = self.cols();
        if self.cursor.pending_wrap {
            if self.modes.autowrap {
                let row = self.cursor.row;
                self.grid_mut().row_mut(row).wrapped = true;
                self.carriage_return();
                self.linefeed();
            } else {
                self.cursor.pending_wrap = false;
            }
        }
        if width == 2 && self.cursor.col == cols - 1 {
            let (col, row, blank) = (self.cursor.col, self.cursor.row, self.blank());
            self.split_wide(col, row);
            self.grid_mut().set_cell(col, row, blank);
            if cols < 2 {
                return;
            }
            if self.modes.autowrap {
                self.grid_mut().row_mut(row).wrapped = true;
                self.carriage_return();
                self.linefeed();
            } else {
                self.cursor.col = cols - 2;
            }
        }
        let (col, row) = (self.cursor.col, self.cursor.row);
        self.split_wide(col, row);
        if width == 2 {
            self.split_wide(col + 1, row);
        }
        if self.modes.insert {
            let n = width.min(cols - col);
            self.grid_mut().row_mut(row).cells_mut()[col..].rotate_right(n);
        }
        let cell = self.template.with_codepoint(c);
        if width == 2 {
            let wide = cell.with_flags(self.template.flags() | flags::WIDE);
            let spacer = self
                .template
                .with_codepoint(' ')
                .with_flags(self.template.flags() | flags::WIDE_SPACER);
            self.grid_mut().set_cell(col, row, wide);
            self.grid_mut().set_cell(col + 1, row, spacer);
        } else {
            self.grid_mut().set_cell(col, row, cell);
        }
        let next = col + width;
        if next >= cols {
            self.cursor.col = cols - 1;
            self.cursor.pending_wrap = true;
        } else {
            self.cursor.col = next;
            self.cursor.pending_wrap = false;
        }
        self.last_char = Some(c);
    }

    /// Drains up to `out.len()` pending response bytes into `out`.
    pub fn take_responses(&mut self, out: &mut [u8]) -> usize {
        let n = out.len().min(self.responses.len());
        out[..n].copy_from_slice(&self.responses[..n]);
        self.responses.drain(..n);
        n
    }

    pub fn responses_len(&self) -> usize {
        self.responses.len()
    }

    fn report(&mut self, s: &str) {
        self.responses.extend_from_slice(s.as_bytes());
    }

    /// Changes the screen size. Cursor follows its row when rows move
    /// into or out of scrollback. Scroll region and tab stops reset.
    pub fn resize(&mut self, cols: usize, rows: usize) {
        let cols = cols.max(1);
        let rows = rows.max(1);
        let old_rows = self.rows();
        let blank = self.blank();
        let pulled = if rows > old_rows {
            (rows - old_rows).min(self.grid().scrollback_len())
        } else {
            0
        };
        self.primary.resize(cols, rows, blank);
        self.alt.resize(cols, rows, blank);
        if rows < old_rows {
            self.cursor.row = self.cursor.row.saturating_sub(old_rows - rows);
        } else {
            self.cursor.row += pulled;
        }
        self.cursor.row = self.cursor.row.min(rows - 1);
        self.cursor.col = self.cursor.col.min(cols - 1);
        self.cursor.pending_wrap = false;
        self.scroll_top = 0;
        self.scroll_bottom = rows - 1;
        self.tabs = default_tabs(cols);
    }

    /// Absolute placement. `row` is relative to the scroll region top
    /// when origin mode is on.
    fn move_cursor_to(&mut self, row: usize, col: usize) {
        let (min_row, max_row) = if self.modes.origin {
            (self.scroll_top, self.scroll_bottom)
        } else {
            (0, self.rows() - 1)
        };
        self.cursor.row = (min_row + row).min(max_row);
        self.cursor.col = col.min(self.cols() - 1);
        self.cursor.pending_wrap = false;
    }

    fn cursor_up(&mut self, n: usize) {
        let bound = if self.cursor.row >= self.scroll_top { self.scroll_top } else { 0 };
        self.cursor.row = self.cursor.row.saturating_sub(n).max(bound);
        self.cursor.pending_wrap = false;
    }

    fn cursor_down(&mut self, n: usize) {
        let bound = if self.cursor.row <= self.scroll_bottom {
            self.scroll_bottom
        } else {
            self.rows() - 1
        };
        self.cursor.row = (self.cursor.row + n).min(bound);
        self.cursor.pending_wrap = false;
    }

    fn cursor_forward(&mut self, n: usize) {
        self.cursor.col = (self.cursor.col + n).min(self.cols() - 1);
        self.cursor.pending_wrap = false;
    }

    fn cursor_back(&mut self, n: usize) {
        self.cursor.col = self.cursor.col.saturating_sub(n);
        self.cursor.pending_wrap = false;
    }

    /// Blanks `from..=to` on `row`. Clears the wrap flag when the row end is included.
    fn erase_in_row(&mut self, row: usize, from: usize, to: usize) {
        let cols = self.cols();
        let to = to.min(cols - 1);
        if from > to {
            return;
        }
        let blank = self.blank();
        self.split_wide(from, row);
        self.split_wide(to, row);
        let r = self.grid_mut().row_mut(row);
        r.cells_mut()[from..=to].fill(blank);
        if to == cols - 1 {
            r.wrapped = false;
        }
    }

    fn erase_display(&mut self, mode: u16) {
        let (col, row, rows, cols) = (self.cursor.col, self.cursor.row, self.rows(), self.cols());
        match mode {
            0 => {
                self.erase_in_row(row, col, cols - 1);
                for r in row + 1..rows {
                    self.erase_in_row(r, 0, cols - 1);
                }
            }
            1 => {
                for r in 0..row {
                    self.erase_in_row(r, 0, cols - 1);
                }
                self.erase_in_row(row, 0, col);
            }
            2 | 3 => {
                for r in 0..rows {
                    self.erase_in_row(r, 0, cols - 1);
                }
                if mode == 3 {
                    self.grid_mut().clear_scrollback();
                }
            }
            _ => {}
        }
    }

    fn erase_line(&mut self, mode: u16) {
        let (col, row, cols) = (self.cursor.col, self.cursor.row, self.cols());
        match mode {
            0 => self.erase_in_row(row, col, cols - 1),
            1 => self.erase_in_row(row, 0, col),
            2 => self.erase_in_row(row, 0, cols - 1),
            _ => {}
        }
    }

    fn insert_blanks(&mut self, n: usize) {
        let (col, row, cols, blank) = (self.cursor.col, self.cursor.row, self.cols(), self.blank());
        let n = n.min(cols - col);
        self.split_wide(col, row);
        let cells = self.grid_mut().row_mut(row).cells_mut();
        cells[col..].rotate_right(n);
        cells[col..col + n].fill(blank);
        self.cursor.pending_wrap = false;
    }

    fn delete_chars(&mut self, n: usize) {
        let (col, row, cols, blank) = (self.cursor.col, self.cursor.row, self.cols(), self.blank());
        let n = n.min(cols - col);
        self.split_wide(col, row);
        let cells = self.grid_mut().row_mut(row).cells_mut();
        cells[col..].rotate_left(n);
        cells[cols - n..].fill(blank);
        self.cursor.pending_wrap = false;
    }

    fn erase_chars(&mut self, n: usize) {
        let (col, row, cols) = (self.cursor.col, self.cursor.row, self.cols());
        let n = n.min(cols - col).max(1);
        self.erase_in_row(row, col, col + n - 1);
        self.cursor.pending_wrap = false;
    }

    fn insert_lines(&mut self, n: usize) {
        let row = self.cursor.row;
        if row < self.scroll_top || row > self.scroll_bottom {
            return;
        }
        let (bottom, blank) = (self.scroll_bottom, self.blank());
        self.grid_mut().scroll_down_region(row, bottom, n, blank);
        self.cursor.pending_wrap = false;
    }

    fn delete_lines(&mut self, n: usize) {
        let row = self.cursor.row;
        if row < self.scroll_top || row > self.scroll_bottom {
            return;
        }
        let (bottom, blank) = (self.scroll_bottom, self.blank());
        self.grid_mut().scroll_up_region(row, bottom, n, blank);
        self.cursor.pending_wrap = false;
    }

    fn set_scroll_region(&mut self, top: usize, bottom: usize) {
        let bottom = bottom.min(self.rows() - 1);
        if top < bottom {
            self.scroll_top = top;
            self.scroll_bottom = bottom;
            self.move_cursor_to(0, 0);
        }
    }

    fn repeat_last(&mut self, n: usize) {
        if let Some(c) = self.last_char {
            let width = c.width().unwrap_or(1).clamp(1, 2);
            for _ in 0..n.min(self.cols()) {
                self.put_char(c, width);
            }
        }
    }

    fn tab_back(&mut self) {
        let mut c = self.cursor.col;
        while c > 0 {
            c -= 1;
            if self.tabs[c] {
                break;
            }
        }
        self.cursor.col = c;
        self.cursor.pending_wrap = false;
    }

    fn device_status(&mut self, what: u16) {
        match what {
            5 => self.report("\x1b[0n"),
            6 => {
                let row = if self.modes.origin {
                    self.cursor.row.saturating_sub(self.scroll_top)
                } else {
                    self.cursor.row
                } + 1;
                let col = self.cursor.col + 1;
                let s = format!("\x1b[{row};{col}R");
                self.report(&s);
            }
            _ => {}
        }
    }

    /// DECSCUSR: 0 and 1 blinking block, 2 steady block, 3 and 4
    /// underline, 5 and 6 bar. Odd values blink.
    fn set_cursor_style(&mut self, style: u16) {
        let (shape, blink) = match style {
            0 | 1 => (0, true),
            2 => (0, false),
            3 => (1, true),
            4 => (1, false),
            5 => (2, true),
            6 => (2, false),
            _ => return,
        };
        self.modes.cursor_shape = shape;
        self.modes.cursor_blink = blink;
    }
}

impl Perform for Screen {
    fn print(&mut self, c: char) {
        let width = match c.width() {
            Some(w) if w > 0 => w.min(2),
            _ => return,
        };
        self.put_char(c, width);
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            0x08 => self.backspace(),
            0x09 => self.tab_forward(),
            0x0A | 0x0B | 0x0C => self.linefeed(),
            0x0D => self.carriage_return(),
            _ => {}
        }
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], ignore: bool, action: char) {
        if ignore {
            return;
        }
        let n = param(params, 0, 1) as usize;
        match (intermediates, action) {
            (b"", 'A') => self.cursor_up(n),
            (b"", 'B') | (b"", 'e') => self.cursor_down(n),
            (b"", 'C') | (b"", 'a') => self.cursor_forward(n),
            (b"", 'D') => self.cursor_back(n),
            (b"", 'E') => {
                self.cursor_down(n);
                self.cursor.col = 0;
            }
            (b"", 'F') => {
                self.cursor_up(n);
                self.cursor.col = 0;
            }
            (b"", 'G') | (b"", '`') => {
                self.cursor.col = (n - 1).min(self.cols() - 1);
                self.cursor.pending_wrap = false;
            }
            (b"", 'H') | (b"", 'f') => {
                let col = param(params, 1, 1) as usize;
                self.move_cursor_to(n - 1, col - 1);
            }
            (b"", 'd') => {
                let col = self.cursor.col;
                self.move_cursor_to(n - 1, col);
            }
            (b"", 'J') => self.erase_display(param0(params, 0)),
            (b"", 'K') => self.erase_line(param0(params, 0)),
            (b"", '@') => self.insert_blanks(n),
            (b"", 'P') => self.delete_chars(n),
            (b"", 'X') => self.erase_chars(n),
            (b"", 'L') => self.insert_lines(n),
            (b"", 'M') => self.delete_lines(n),
            (b"", 'S') => {
                let (top, bottom, blank) = (self.scroll_top, self.scroll_bottom, self.blank());
                self.grid_mut().scroll_up_region(top, bottom, n, blank);
            }
            (b"", 'T') => {
                let (top, bottom, blank) = (self.scroll_top, self.scroll_bottom, self.blank());
                self.grid_mut().scroll_down_region(top, bottom, n, blank);
            }
            (b"", 'r') => {
                let bottom = param(params, 1, self.rows() as u16) as usize;
                self.set_scroll_region(n - 1, bottom - 1);
            }
            (b"", 'b') => self.repeat_last(n),
            (b"", 'I') => {
                for _ in 0..n {
                    self.tab_forward();
                }
            }
            (b"", 'Z') => {
                for _ in 0..n {
                    self.tab_back();
                }
            }
            (b"", 'g') => match param0(params, 0) {
                0 => {
                    let c = self.cursor.col;
                    self.tabs[c] = false;
                }
                3 => self.tabs.fill(false),
                _ => {}
            },
            (b"", 'n') => self.device_status(param0(params, 0)),
            (b"", 'c') => self.report("\x1b[?1;2c"),
            (b">", 'c') => self.report("\x1b[>0;0;0c"),
            (b" ", 'q') => self.set_cursor_style(param0(params, 0)),
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cell::flags;

    fn feed(s: &mut Screen, bytes: &[u8]) {
        let mut parser = vte::Parser::new();
        parser.advance(s, bytes);
    }

    fn screen(cols: usize, rows: usize) -> Screen {
        Screen::new(cols, rows, 10)
    }

    #[test]
    fn prints_text_and_advances_cursor() {
        let mut s = screen(10, 2);
        feed(&mut s, b"hello");
        assert_eq!(s.row_text(0), "hello");
        assert_eq!(s.cursor().col, 5);
        assert_eq!(s.cursor().row, 0);
    }

    #[test]
    fn wraps_at_right_edge_and_flags_row() {
        let mut s = screen(5, 2);
        feed(&mut s, b"abcdefg");
        assert_eq!(s.row_text(0), "abcde");
        assert_eq!(s.row_text(1), "fg");
        assert!(s.grid().row(0).wrapped);
        assert!(!s.grid().row(1).wrapped);
        assert_eq!((s.cursor().col, s.cursor().row), (2, 1));
    }

    #[test]
    fn cursor_sticks_in_last_column_until_next_char() {
        let mut s = screen(5, 2);
        feed(&mut s, b"abcde");
        assert_eq!(s.cursor().col, 4);
        assert!(s.cursor().pending_wrap);
        feed(&mut s, b"\rX");
        assert_eq!(s.row_text(0), "Xbcde");
        assert_eq!(s.cursor().row, 0);
    }

    #[test]
    fn linefeed_at_bottom_scrolls() {
        let mut s = screen(3, 2);
        feed(&mut s, b"a\nb\nc");
        assert_eq!(s.row_text(0), " b");
        assert_eq!(s.row_text(1), "  c");
        assert_eq!(s.grid().scrollback_len(), 1);
        let first = s.grid().line(s.grid().first_line_id()).unwrap();
        assert_eq!(first.cells()[0].codepoint(), 'a');
    }

    #[test]
    fn carriage_return_and_backspace() {
        let mut s = screen(10, 1);
        feed(&mut s, b"ab\x08c");
        assert_eq!(s.row_text(0), "ac");
        assert_eq!(s.cursor().col, 2);
        feed(&mut s, b"\r");
        assert_eq!(s.cursor().col, 0);
    }

    #[test]
    fn tab_moves_to_next_stop() {
        let mut s = screen(20, 1);
        feed(&mut s, b"\tx");
        assert_eq!(s.row_text(0), "        x");
        assert_eq!(s.cursor().col, 9);
        feed(&mut s, b"\t\t\t");
        assert_eq!(s.cursor().col, 19);
    }

    #[test]
    fn wide_char_takes_two_cells() {
        let mut s = screen(10, 1);
        feed(&mut s, "日x".as_bytes());
        let first = s.grid().cell(0, 0);
        let second = s.grid().cell(1, 0);
        assert_eq!(first.codepoint(), '日');
        assert!(first.has(flags::WIDE));
        assert!(second.has(flags::WIDE_SPACER));
        assert_eq!(s.grid().cell(2, 0).codepoint(), 'x');
        assert_eq!(s.row_text(0), "日x");
        assert_eq!(s.cursor().col, 3);
    }

    #[test]
    fn wide_char_at_last_column_wraps() {
        let mut s = screen(3, 2);
        feed(&mut s, "ab日".as_bytes());
        assert_eq!(s.row_text(0), "ab");
        assert_eq!(s.row_text(1), "日");
        assert!(s.grid().row(0).wrapped);
        assert_eq!((s.cursor().col, s.cursor().row), (2, 1));
    }

    #[test]
    fn overwriting_half_a_wide_char_clears_the_other_half() {
        let mut s = screen(10, 1);
        feed(&mut s, "日".as_bytes());
        feed(&mut s, b"\rx");
        assert_eq!(s.grid().cell(0, 0).codepoint(), 'x');
        let second = s.grid().cell(1, 0);
        assert_eq!(second.codepoint(), ' ');
        assert!(!second.has(flags::WIDE_SPACER));
    }

    #[test]
    fn control_chars_are_not_printed() {
        let mut s = screen(10, 1);
        feed(&mut s, b"a\x01b\x7fc");
        assert_eq!(s.row_text(0), "abc");
    }

    #[test]
    fn cup_moves_cursor() {
        let mut s = screen(10, 5);
        feed(&mut s, b"\x1b[3;4H");
        assert_eq!((s.cursor().col, s.cursor().row), (3, 2));
        feed(&mut s, b"\x1b[H");
        assert_eq!((s.cursor().col, s.cursor().row), (0, 0));
        feed(&mut s, b"\x1b[99;99f");
        assert_eq!((s.cursor().col, s.cursor().row), (9, 4));
    }

    #[test]
    fn relative_moves_clamp() {
        let mut s = screen(10, 5);
        feed(&mut s, b"\x1b[99C");
        assert_eq!(s.cursor().col, 9);
        feed(&mut s, b"\x1b[99A");
        assert_eq!(s.cursor().row, 0);
        feed(&mut s, b"\x1b[2B");
        assert_eq!(s.cursor().row, 2);
        feed(&mut s, b"\x1b[D");
        assert_eq!(s.cursor().col, 8);
        feed(&mut s, b"\x1b[E");
        assert_eq!((s.cursor().col, s.cursor().row), (0, 3));
        feed(&mut s, b"\x1b[5G\x1b[2d");
        assert_eq!((s.cursor().col, s.cursor().row), (4, 1));
    }

    #[test]
    fn ed_0_clears_to_end_of_screen() {
        let mut s = screen(10, 5);
        feed(&mut s, b"aaaa\r\nbbbb\r\ncccc\x1b[2;3H\x1b[J");
        assert_eq!(s.row_text(0), "aaaa");
        assert_eq!(s.row_text(1), "bb");
        assert_eq!(s.row_text(2), "");
    }

    #[test]
    fn ed_1_clears_to_start_and_ed_2_clears_all() {
        let mut s = screen(10, 5);
        feed(&mut s, b"aaaa\r\nbbbb\r\ncccc\x1b[2;3H\x1b[1J");
        assert_eq!(s.row_text(0), "");
        assert_eq!(s.row_text(1), "   b");
        assert_eq!(s.row_text(2), "cccc");
        feed(&mut s, b"\x1b[2J");
        assert_eq!(s.row_text(2), "");
        assert_eq!((s.cursor().col, s.cursor().row), (2, 1));
    }

    #[test]
    fn ed_3_clears_scrollback() {
        let mut s = screen(10, 2);
        feed(&mut s, b"a\r\nb\r\nc");
        assert_eq!(s.grid().scrollback_len(), 1);
        feed(&mut s, b"\x1b[3J");
        assert_eq!(s.grid().scrollback_len(), 0);
        assert_eq!(s.row_text(0), "");
    }

    #[test]
    fn el_variants() {
        let mut s = screen(10, 1);
        feed(&mut s, b"abcdef\x1b[4G\x1b[K");
        assert_eq!(s.row_text(0), "abc");
        let mut s = screen(10, 1);
        feed(&mut s, b"abcdef\x1b[4G\x1b[1K");
        assert_eq!(s.row_text(0), "    ef");
        let mut s = screen(10, 1);
        feed(&mut s, b"abcdef\x1b[2K");
        assert_eq!(s.row_text(0), "");
    }

    #[test]
    fn ich_and_dch() {
        let mut s = screen(10, 1);
        feed(&mut s, b"abcdef\x1b[1G\x1b[2@");
        assert_eq!(s.row_text(0), "  abcdef");
        feed(&mut s, b"\x1b[3P");
        assert_eq!(s.row_text(0), "bcdef");
    }

    #[test]
    fn ech_blanks_without_shifting() {
        let mut s = screen(10, 1);
        feed(&mut s, b"abcdef\x1b[2G\x1b[3X");
        assert_eq!(s.row_text(0), "a   ef");
    }

    #[test]
    fn il_and_dl_within_region() {
        let mut s = screen(10, 5);
        feed(&mut s, b"1\r\n2\r\n3\r\n4\r\n5\x1b[2;4r\x1b[2;1H\x1b[L");
        let rows: Vec<String> = (0..5).map(|r| s.row_text(r)).collect();
        assert_eq!(rows, ["1", "", "2", "3", "5"]);
        feed(&mut s, b"\x1b[2M");
        let rows: Vec<String> = (0..5).map(|r| s.row_text(r)).collect();
        assert_eq!(rows, ["1", "3", "", "", "5"]);
    }

    #[test]
    fn scroll_region_confines_linefeed() {
        let mut s = screen(10, 5);
        feed(&mut s, b"\x1b[2;3r");
        assert_eq!((s.cursor().col, s.cursor().row), (0, 0));
        feed(&mut s, b"\x1b[3;1Hx\ny");
        let rows: Vec<String> = (0..5).map(|r| s.row_text(r)).collect();
        assert_eq!(rows, ["", "x", " y", "", ""]);
        assert_eq!(s.grid().scrollback_len(), 0);
    }

    #[test]
    fn su_and_sd() {
        let mut s = screen(10, 5);
        feed(&mut s, b"1\r\n2\r\n3\x1b[S");
        let rows: Vec<String> = (0..5).map(|r| s.row_text(r)).collect();
        assert_eq!(rows, ["2", "3", "", "", ""]);
        assert_eq!(s.grid().scrollback_len(), 1);
        feed(&mut s, b"\x1b[T");
        let rows: Vec<String> = (0..5).map(|r| s.row_text(r)).collect();
        assert_eq!(rows, ["", "2", "3", "", ""]);
    }

    #[test]
    fn dsr_reports_position_and_status() {
        let mut s = screen(10, 5);
        feed(&mut s, b"\x1b[2;5H\x1b[6n\x1b[5n");
        let mut out = [0u8; 32];
        let n = s.take_responses(&mut out);
        assert_eq!(&out[..n], b"\x1b[2;5R\x1b[0n");
        assert_eq!(s.responses_len(), 0);
    }

    #[test]
    fn da_reports() {
        let mut s = screen(10, 5);
        feed(&mut s, b"\x1b[c\x1b[>c");
        let mut out = [0u8; 32];
        let n = s.take_responses(&mut out);
        assert_eq!(&out[..n], b"\x1b[?1;2c\x1b[>0;0;0c");
    }

    #[test]
    fn rep_repeats_last_char() {
        let mut s = screen(10, 1);
        feed(&mut s, b"ab\x1b[3b");
        assert_eq!(s.row_text(0), "abbbb");
    }

    #[test]
    fn tab_stops_cht_cbt_tbc() {
        let mut s = screen(40, 1);
        feed(&mut s, b"\x1b[2I");
        assert_eq!(s.cursor().col, 16);
        feed(&mut s, b"\x1b[Z");
        assert_eq!(s.cursor().col, 8);
        feed(&mut s, b"\x1b[3g\t");
        assert_eq!(s.cursor().col, 39);
    }

    #[test]
    fn decscusr_sets_cursor_shape() {
        let mut s = screen(10, 1);
        feed(&mut s, b"\x1b[4 q");
        assert_eq!((s.modes().cursor_shape, s.modes().cursor_blink), (1, false));
        feed(&mut s, b"\x1b[5 q");
        assert_eq!((s.modes().cursor_shape, s.modes().cursor_blink), (2, true));
        feed(&mut s, b"\x1b[0 q");
        assert_eq!((s.modes().cursor_shape, s.modes().cursor_blink), (0, true));
    }

    #[test]
    fn resize_clamps_cursor_and_resets_region() {
        let mut s = screen(10, 5);
        feed(&mut s, b"\x1b[2;4r\x1b[9;9H");
        assert_eq!((s.cursor().col, s.cursor().row), (8, 4));
        s.resize(4, 2);
        assert_eq!(s.cols(), 4);
        assert_eq!(s.rows(), 2);
        assert_eq!((s.cursor().col, s.cursor().row), (3, 1));
        feed(&mut s, b"\x1b[1;1Ha\nb\nc");
        assert_eq!(s.row_text(1), "  c");
        assert_eq!(s.grid().scrollback_len(), 4);
    }

    #[test]
    fn resize_taller_moves_cursor_with_pulled_rows() {
        let mut s = screen(10, 2);
        feed(&mut s, b"a\r\nb\r\nc");
        assert_eq!(s.cursor().row, 1);
        s.resize(10, 4);
        assert_eq!(s.cursor().row, 2);
        let rows: Vec<String> = (0..4).map(|r| s.row_text(r)).collect();
        assert_eq!(rows, ["a", "b", "c", ""]);
    }
}
