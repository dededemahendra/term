//! The one object the shell talks to: parser, screen and selection.

use crate::cell::Cell;
use crate::screen::Screen;
use crate::selection::{Point, Selection, SelectionMode};

pub struct Term {
    parser: vte::Parser,
    screen: Screen,
    selection: Option<Selection>,
}

impl Term {
    pub fn new(cols: usize, rows: usize, scrollback: usize) -> Term {
        Term {
            parser: vte::Parser::new(),
            screen: Screen::new(cols, rows, scrollback),
            selection: None,
        }
    }

    /// Parses `bytes` into the screen. Never panics, never allocates
    /// except when a new 24-bit colour is first seen.
    pub fn feed(&mut self, bytes: &[u8]) {
        self.parser.advance(&mut self.screen, bytes);
    }

    pub fn screen(&self) -> &Screen {
        &self.screen
    }

    pub fn screen_mut(&mut self) -> &mut Screen {
        &mut self.screen
    }

    pub fn resize(&mut self, cols: usize, rows: usize) {
        self.screen.resize(cols, rows);
        self.selection = None;
    }

    pub fn scroll_viewport(&mut self, delta: i32) {
        self.screen.grid_mut().scroll_viewport(delta);
    }

    pub fn selection(&self) -> Option<Selection> {
        self.selection
    }

    fn visible_point(&self, col: usize, row: usize) -> Option<Point> {
        let grid = self.screen.grid();
        if col >= grid.cols() || row >= grid.rows() {
            return None;
        }
        Some(Point { line: grid.visible_line_id(row), col })
    }

    /// Starts a selection at a visible cell. False if out of range.
    pub fn selection_start(&mut self, col: usize, row: usize, mode: SelectionMode) -> bool {
        let Some(point) = self.visible_point(col, row) else { return false };
        self.selection = Some(Selection::new(point, mode));
        self.screen.grid_mut().mark_all_dirty();
        true
    }

    /// Moves the selection head. False if out of range or no selection.
    pub fn selection_extend(&mut self, col: usize, row: usize) -> bool {
        let Some(point) = self.visible_point(col, row) else { return false };
        let Some(selection) = self.selection.as_mut() else { return false };
        selection.extend(point);
        self.screen.grid_mut().mark_all_dirty();
        true
    }

    pub fn selection_clear(&mut self) {
        if self.selection.take().is_some() {
            self.screen.grid_mut().mark_all_dirty();
        }
    }

    pub fn selection_text(&self) -> String {
        match &self.selection {
            Some(s) => s.text(self.screen.grid()),
            None => String::new(),
        }
    }

    /// Copies the visible grid (viewport applied) into `out` in row
    /// major order with the selected bit set. False if `out` is short.
    pub fn copy_visible(&self, out: &mut [Cell]) -> bool {
        let grid = self.screen.grid();
        let (cols, rows) = (grid.cols(), grid.rows());
        if out.len() < cols * rows {
            return false;
        }
        let bounds = self.selection.map(|s| s.bounds(grid));
        for r in 0..rows {
            let dst = &mut out[r * cols..(r + 1) * cols];
            dst.copy_from_slice(grid.visible_row(r).cells());
            let Some((start, end)) = bounds else { continue };
            let line = grid.visible_line_id(r);
            if line < start.line || line > end.line {
                continue;
            }
            let from = if line == start.line { start.col.min(cols - 1) } else { 0 };
            let to = if line == end.line { end.col.min(cols - 1) } else { cols - 1 };
            if from <= to {
                for cell in &mut dst[from..=to] {
                    *cell = cell.with_selected(true);
                }
            }
        }
        true
    }

    /// Screen rows (viewport ignored) joined with newlines, trailing
    /// blanks trimmed. For tests and snapshots.
    pub fn dump(&self) -> String {
        (0..self.screen.rows())
            .map(|r| self.screen.row_text(r))
            .collect::<Vec<_>>()
            .join("\n")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::selection::SelectionMode;

    #[test]
    fn feed_and_dump() {
        let mut t = Term::new(5, 2, 0);
        t.feed(b"hi\r\nyo");
        assert_eq!(t.dump(), "hi\nyo");
    }

    #[test]
    fn dump_ignores_the_viewport() {
        let mut t = Term::new(5, 2, 5);
        t.feed(b"a\r\nb\r\nc");
        t.scroll_viewport(1);
        assert_eq!(t.dump(), "b\nc");
        let mut out = vec![Cell::default(); 10];
        assert!(t.copy_visible(&mut out));
        assert_eq!(out[0].codepoint(), 'a');
    }

    #[test]
    fn resize_clears_selection() {
        let mut t = Term::new(5, 2, 0);
        t.feed(b"abc");
        assert!(t.selection_start(0, 0, SelectionMode::Normal));
        assert!(t.selection().is_some());
        t.resize(6, 3);
        assert!(t.selection().is_none());
        assert_eq!(t.screen().cols(), 6);
    }

    #[test]
    fn selection_uses_visible_rows() {
        let mut t = Term::new(5, 2, 5);
        t.feed(b"a\r\nb\r\nc");
        t.scroll_viewport(1);
        assert!(t.selection_start(0, 0, SelectionMode::Normal));
        assert!(t.selection_extend(0, 1));
        assert_eq!(t.selection_text(), "a\nb");
        assert!(!t.selection_start(50, 0, SelectionMode::Normal));
        assert!(!t.selection_extend(0, 9));
    }

    #[test]
    fn copy_visible_marks_selected_cells() {
        let mut t = Term::new(5, 2, 5);
        t.feed(b"a\r\nb\r\nc");
        t.scroll_viewport(1);
        t.selection_start(0, 0, SelectionMode::Normal);
        t.selection_extend(0, 1);
        let mut out = vec![Cell::default(); 10];
        assert!(t.copy_visible(&mut out));
        assert_eq!(out[0].codepoint(), 'a');
        assert!(out[0].selected());
        assert!(out[4].selected());
        assert!(out[5].selected());
        assert!(!out[6].selected());
        assert_eq!(out[5].codepoint(), 'b');
        t.selection_clear();
        assert!(t.copy_visible(&mut out));
        assert!(!out[0].selected());
    }

    #[test]
    fn copy_visible_rejects_small_buffer() {
        let t = Term::new(5, 2, 0);
        let mut out = vec![Cell::default(); 9];
        assert!(!t.copy_visible(&mut out));
    }

    #[test]
    fn selection_changes_mark_rows_dirty() {
        let mut t = Term::new(5, 2, 0);
        let mut words = [0u64; 1];
        t.screen_mut().grid_mut().take_dirty(&mut words);
        t.selection_start(0, 0, SelectionMode::Normal);
        t.screen_mut().grid_mut().take_dirty(&mut words);
        assert_ne!(words[0] & 0b11, 0);
    }

    #[test]
    fn responses_flow_through() {
        let mut t = Term::new(5, 2, 0);
        t.feed(b"\x1b[6n");
        let mut out = [0u8; 16];
        let n = t.screen_mut().take_responses(&mut out);
        assert_eq!(&out[..n], b"\x1b[1;1R");
    }
}
