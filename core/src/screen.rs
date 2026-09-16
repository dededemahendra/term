//! Screen state: cursor, modes, attributes, scroll region and the
//! alternate screen. Implements `vte::Perform`, so the parser drives
//! it directly.

use unicode_width::UnicodeWidthChar;
use vte::Perform;

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
}
