//! Cell grid: visible screen plus scrollback in one ring buffer.
//!
//! Storage is a `Vec<Row>` of fixed capacity `rows + scrollback`. Live
//! rows are `storage[start..start+len]` modulo capacity. The visible
//! screen is the last `rows` live rows, shifted up by `viewport` when
//! the user has scrolled back.

use crate::cell::Cell;

#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    cells: Vec<Cell>,
    /// True when the row overflowed into the next one (soft wrap).
    pub wrapped: bool,
}

impl Row {
    pub fn new(cols: usize) -> Row {
        Row { cells: vec![Cell::default(); cols], wrapped: false }
    }

    pub fn cells(&self) -> &[Cell] {
        &self.cells
    }

    pub fn cells_mut(&mut self) -> &mut [Cell] {
        &mut self.cells
    }

    pub fn len(&self) -> usize {
        self.cells.len()
    }

    pub fn is_empty(&self) -> bool {
        self.cells.is_empty()
    }

    pub fn clear(&mut self, template: Cell) {
        self.cells.fill(template);
        self.wrapped = false;
    }

    pub fn resize(&mut self, cols: usize, template: Cell) {
        self.cells.resize(cols, template);
    }
}

#[derive(Debug)]
pub struct Grid {
    cols: usize,
    rows: usize,
    scrollback: usize,
    storage: Vec<Row>,
    /// Storage index of the oldest live row.
    start: usize,
    /// Number of live rows. Always `rows <= len <= capacity`.
    len: usize,
    /// Rows evicted from the ring over the grid's lifetime.
    dropped: u64,
    /// Rows the user has scrolled back. 0 means live.
    viewport: usize,
    /// One bit per screen row.
    dirty: Vec<u64>,
}

impl Grid {
    pub fn new(cols: usize, rows: usize, scrollback: usize) -> Grid {
        let cols = cols.max(1);
        let rows = rows.max(1);
        let capacity = rows + scrollback;
        Grid {
            cols,
            rows,
            scrollback,
            storage: (0..capacity).map(|_| Row::new(cols)).collect(),
            start: 0,
            len: rows,
            dropped: 0,
            viewport: 0,
            dirty: vec![u64::MAX; rows.div_ceil(64)],
        }
    }

    pub fn cols(&self) -> usize {
        self.cols
    }

    pub fn rows(&self) -> usize {
        self.rows
    }

    pub fn scrollback_capacity(&self) -> usize {
        self.scrollback
    }

    /// Rows currently held above the screen.
    pub fn scrollback_len(&self) -> usize {
        self.len - self.rows
    }

    fn capacity(&self) -> usize {
        self.storage.len()
    }

    fn storage_index(&self, live: usize) -> usize {
        (self.start + live) % self.capacity()
    }

    /// Live index of screen row `r`, ignoring the viewport.
    fn screen_live(&self, r: usize) -> usize {
        self.len - self.rows + r
    }

    pub fn row(&self, r: usize) -> &Row {
        let i = self.storage_index(self.screen_live(r));
        &self.storage[i]
    }

    /// Mutable access to a screen row. Marks it dirty.
    pub fn row_mut(&mut self, r: usize) -> &mut Row {
        self.mark_dirty(r);
        let i = self.storage_index(self.screen_live(r));
        &mut self.storage[i]
    }

    pub fn cell(&self, col: usize, row: usize) -> Cell {
        self.row(row).cells()[col]
    }

    pub fn set_cell(&mut self, col: usize, row: usize, cell: Cell) {
        self.row_mut(row).cells_mut()[col] = cell;
    }

    pub fn mark_dirty(&mut self, r: usize) {
        self.dirty[r / 64] |= 1 << (r % 64);
    }

    pub fn mark_all_dirty(&mut self) {
        self.dirty.fill(u64::MAX);
    }

    pub fn is_dirty(&self, r: usize) -> bool {
        self.dirty[r / 64] & (1 << (r % 64)) != 0
    }

    /// Number of `u64` words in the dirty bitmap.
    pub fn dirty_words(&self) -> usize {
        self.dirty.len()
    }

    /// Copies the dirty bitmap into `out` and clears it. Extra words in
    /// `out` are zeroed. A short `out` receives a prefix and the bits
    /// that did not fit are lost, so size it with `dirty_words()`.
    pub fn take_dirty(&mut self, out: &mut [u64]) {
        let n = out.len().min(self.dirty.len());
        out[..n].copy_from_slice(&self.dirty[..n]);
        for w in &mut out[n..] {
            *w = 0;
        }
        self.dirty.fill(0);
    }

    /// Scrolls the whole screen up by `n`. Top rows enter scrollback and
    /// `n` rows cleared to `template` appear at the bottom. Closed form,
    /// so a huge `n` from an escape sequence costs at most one pass over
    /// the ring.
    pub fn scroll_up_full(&mut self, n: usize, template: Cell) {
        if n == 0 {
            return;
        }
        let capacity = self.capacity();
        let total = self.len.saturating_add(n);
        let evicted = total.saturating_sub(capacity);
        self.start = (self.start + evicted) % capacity;
        self.dropped += evicted as u64;
        self.len = total.min(capacity);
        // Only the newest min(n, capacity) live rows are fresh.
        let fresh = n.min(capacity);
        for live in (self.len - fresh)..self.len {
            let idx = self.storage_index(live);
            self.storage[idx].clear(template);
        }
        if self.viewport > 0 {
            self.viewport = (self.viewport + n).min(self.scrollback_len());
        }
        self.mark_all_dirty();
    }

    /// Line id of the oldest row still held.
    pub fn first_line_id(&self) -> u64 {
        self.dropped
    }

    /// Number of rows held, scrollback plus screen.
    pub fn line_count(&self) -> usize {
        self.len
    }

    /// Row by line id, or `None` if it has been evicted or does not exist yet.
    pub fn line(&self, id: u64) -> Option<&Row> {
        if id < self.dropped {
            return None;
        }
        let live = (id - self.dropped) as usize;
        if live >= self.len {
            return None;
        }
        Some(&self.storage[self.storage_index(live)])
    }

    /// Line id of screen row `r` (viewport ignored).
    pub fn screen_line_id(&self, r: usize) -> u64 {
        self.dropped + self.screen_live(r) as u64
    }

    /// Scrolls rows `top..=bottom` up by `n`. Rows leaving the top of a
    /// partial region are lost; a full screen region uses scrollback.
    pub fn scroll_up_region(&mut self, top: usize, bottom: usize, n: usize, template: Cell) {
        if n == 0 {
            return;
        }
        if top == 0 && bottom == self.rows - 1 {
            return self.scroll_up_full(n, template);
        }
        if top > bottom || bottom >= self.rows {
            return;
        }
        let n = n.min(bottom - top + 1);
        for r in top..(bottom + 1 - n) {
            let a = self.storage_index(self.screen_live(r));
            let b = self.storage_index(self.screen_live(r + n));
            self.storage.swap(a, b);
        }
        for r in (bottom + 1 - n)..=bottom {
            let i = self.storage_index(self.screen_live(r));
            self.storage[i].clear(template);
        }
        for r in top..=bottom {
            self.mark_dirty(r);
        }
    }

    /// Scrolls rows `top..=bottom` down by `n`. Rows leaving the bottom
    /// are lost; `n` cleared rows enter at `top`.
    pub fn scroll_down_region(&mut self, top: usize, bottom: usize, n: usize, template: Cell) {
        if top > bottom || bottom >= self.rows || n == 0 {
            return;
        }
        let n = n.min(bottom - top + 1);
        for r in ((top + n)..=bottom).rev() {
            let a = self.storage_index(self.screen_live(r));
            let b = self.storage_index(self.screen_live(r - n));
            self.storage.swap(a, b);
        }
        for r in top..(top + n) {
            let i = self.storage_index(self.screen_live(r));
            self.storage[i].clear(template);
        }
        for r in top..=bottom {
            self.mark_dirty(r);
        }
    }

    /// Drops every scrollback row. The screen is untouched.
    pub fn clear_scrollback(&mut self) {
        let extra = self.scrollback_len();
        self.start = (self.start + extra) % self.capacity();
        self.dropped += extra as u64;
        self.len = self.rows;
        self.viewport = 0;
        self.mark_all_dirty();
    }

    pub fn viewport(&self) -> usize {
        self.viewport
    }

    /// Moves the viewport by `delta` rows. Positive is towards older
    /// content. Clamped to the available scrollback.
    pub fn scroll_viewport(&mut self, delta: i32) {
        let max = self.scrollback_len() as i64;
        let next = (self.viewport as i64 + delta as i64).clamp(0, max) as usize;
        if next != self.viewport {
            self.viewport = next;
            self.mark_all_dirty();
        }
    }

    fn visible_live(&self, r: usize) -> usize {
        self.len - self.rows - self.viewport + r
    }

    /// Row `r` as the user currently sees it, viewport applied.
    pub fn visible_row(&self, r: usize) -> &Row {
        &self.storage[self.storage_index(self.visible_live(r))]
    }

    pub fn visible_line_id(&self, r: usize) -> u64 {
        self.dropped + self.visible_live(r) as u64
    }

    /// Changes the grid size. No reflow. Shrinking pushes top rows into
    /// scrollback; growing pulls them back, then pads with blank rows.
    pub fn resize(&mut self, cols: usize, rows: usize, template: Cell) {
        let cols = cols.max(1);
        let rows = rows.max(1);
        // Linearise the ring so live rows are storage[0..len].
        self.storage.rotate_left(self.start);
        self.start = 0;
        for row in &mut self.storage {
            row.resize(cols, template);
        }
        self.cols = cols;
        let want_capacity = rows + self.scrollback;
        // Evict the oldest rows that no longer fit under the scrollback cap.
        if self.len > want_capacity {
            let excess = self.len - want_capacity;
            self.storage.rotate_left(excess);
            self.len -= excess;
            self.dropped += excess as u64;
        }
        while self.storage.len() < want_capacity {
            self.storage.push(Row::new(cols));
        }
        while self.len < rows {
            self.storage[self.len].clear(template);
            self.len += 1;
        }
        self.storage.truncate(want_capacity);
        self.rows = rows;
        self.viewport = self.viewport.min(self.scrollback_len());
        self.dirty = vec![u64::MAX; rows.div_ceil(64)];
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cell::Cell;

    fn ch(c: char) -> Cell {
        Cell::default().with_codepoint(c)
    }

    fn row_text(g: &Grid, r: usize) -> String {
        g.row(r).cells().iter().map(|c| c.codepoint()).collect::<String>().trim_end().to_string()
    }

    #[test]
    fn new_grid_is_blank_and_fully_dirty() {
        let g = Grid::new(4, 3, 10);
        assert_eq!(g.cols(), 4);
        assert_eq!(g.rows(), 3);
        assert_eq!(g.scrollback_len(), 0);
        assert_eq!(g.scrollback_capacity(), 10);
        for r in 0..3 {
            assert_eq!(row_text(&g, r), "");
            assert!(g.is_dirty(r));
        }
    }

    #[test]
    fn set_cell_marks_only_that_row_dirty() {
        let mut g = Grid::new(4, 3, 0);
        let mut words = [0u64; 1];
        g.take_dirty(&mut words);
        g.set_cell(1, 2, ch('x'));
        assert_eq!(g.cell(1, 2).codepoint(), 'x');
        assert!(!g.is_dirty(0));
        assert!(g.is_dirty(2));
        g.take_dirty(&mut words);
        assert_eq!(words[0], 0b100);
        assert!(!g.is_dirty(2));
    }

    #[test]
    fn scroll_up_full_moves_top_row_into_scrollback() {
        let mut g = Grid::new(3, 2, 5);
        g.set_cell(0, 0, ch('a'));
        g.set_cell(0, 1, ch('b'));
        g.scroll_up_full(1, Cell::default());
        assert_eq!(row_text(&g, 0), "b");
        assert_eq!(row_text(&g, 1), "");
        assert_eq!(g.scrollback_len(), 1);
        assert_eq!(g.line(g.first_line_id()).unwrap().cells()[0].codepoint(), 'a');
        assert!(g.is_dirty(0) && g.is_dirty(1));
    }

    #[test]
    fn ring_evicts_oldest_and_advances_first_line_id() {
        let mut g = Grid::new(1, 1, 2);
        for c in ['a', 'b', 'c', 'd'] {
            g.set_cell(0, 0, ch(c));
            g.scroll_up_full(1, Cell::default());
        }
        assert_eq!(g.scrollback_len(), 2);
        assert_eq!(g.line_count(), 3);
        assert_eq!(g.first_line_id(), 2);
        assert_eq!(g.line(1), None);
        assert_eq!(g.line(2).unwrap().cells()[0].codepoint(), 'c');
        assert_eq!(g.line(3).unwrap().cells()[0].codepoint(), 'd');
        assert_eq!(g.screen_line_id(0), 4);
        assert_eq!(g.line(5), None);
    }

    #[test]
    fn no_scrollback_grid_still_scrolls() {
        let mut g = Grid::new(2, 2, 0);
        g.set_cell(0, 1, ch('z'));
        g.scroll_up_full(1, Cell::default());
        assert_eq!(row_text(&g, 0), "z");
        assert_eq!(g.scrollback_len(), 0);
        assert_eq!(g.first_line_id(), 1);
    }

    #[test]
    fn scroll_by_more_than_capacity_is_safe() {
        let mut g = Grid::new(2, 2, 1);
        g.scroll_up_full(10, Cell::default());
        assert_eq!(g.scrollback_len(), 1);
        assert_eq!(g.first_line_id(), 9);
    }

    #[test]
    fn scroll_up_full_by_huge_n_is_closed_form() {
        let mut g = Grid::new(1, 3, 2);
        for r in 0..3 {
            g.set_cell(0, r, ch((b'a' + r as u8) as char));
        }
        g.scroll_up_full(65_535, Cell::default());
        assert_eq!(g.scrollback_len(), 2);
        assert_eq!(g.line_count(), 5);
        assert_eq!(g.first_line_id(), 65_535 + 3 - 5);
        for r in 0..3 {
            assert_eq!(row_text(&g, r), "");
        }
        assert!(g.line(g.first_line_id()).is_some());
        assert!(g.line(g.first_line_id() - 1).is_none());
    }

    #[test]
    fn scroll_up_full_by_zero_changes_nothing() {
        let mut g = filled(1, 2, 2);
        let mut words = [0u64; 1];
        g.take_dirty(&mut words);
        g.scroll_up_region(0, 1, 0, Cell::default());
        g.scroll_up_full(0, Cell::default());
        assert_eq!(row_text(&g, 0), "0");
        assert!(!g.is_dirty(0));
        assert_eq!(g.first_line_id(), 0);
    }

    #[test]
    fn dirty_words_covers_all_rows() {
        let g = Grid::new(1, 130, 0);
        assert_eq!(g.dirty_words(), 3);
    }

    fn filled(cols: usize, rows: usize, scrollback: usize) -> Grid {
        let mut g = Grid::new(cols, rows, scrollback);
        for r in 0..rows {
            g.set_cell(0, r, ch((b'0' + r as u8) as char));
        }
        g
    }

    #[test]
    fn region_scroll_up_only_touches_the_region() {
        let mut g = filled(1, 5, 5);
        g.scroll_up_region(1, 3, 1, Cell::default());
        let rows: Vec<String> = (0..5).map(|r| row_text(&g, r)).collect();
        assert_eq!(rows, ["0", "2", "3", "", "4"]);
        assert_eq!(g.scrollback_len(), 0);
    }

    #[test]
    fn region_scroll_down_only_touches_the_region() {
        let mut g = filled(1, 5, 5);
        g.scroll_down_region(1, 3, 2, Cell::default());
        let rows: Vec<String> = (0..5).map(|r| row_text(&g, r)).collect();
        assert_eq!(rows, ["0", "", "", "1", "4"]);
    }

    #[test]
    fn region_scroll_by_region_size_clears_it() {
        let mut g = filled(1, 3, 0);
        g.scroll_up_region(0, 1, 5, Cell::default());
        let rows: Vec<String> = (0..3).map(|r| row_text(&g, r)).collect();
        assert_eq!(rows, ["", "", "2"]);
    }

    #[test]
    fn full_region_scroll_uses_scrollback() {
        let mut g = filled(1, 3, 5);
        g.scroll_up_region(0, 2, 1, Cell::default());
        assert_eq!(g.scrollback_len(), 1);
        assert_eq!(row_text(&g, 0), "1");
    }

    #[test]
    fn viewport_scrolls_into_history_and_clamps() {
        let mut g = filled(1, 2, 3);
        g.scroll_up_full(2, Cell::default());
        assert_eq!(g.scrollback_len(), 2);
        g.scroll_viewport(1);
        assert_eq!(g.viewport(), 1);
        assert_eq!(g.visible_row(0).cells()[0].codepoint(), '1');
        assert_eq!(g.visible_line_id(0), 1);
        g.scroll_viewport(50);
        assert_eq!(g.viewport(), 2);
        assert_eq!(g.visible_row(0).cells()[0].codepoint(), '0');
        g.scroll_viewport(-50);
        assert_eq!(g.viewport(), 0);
        assert_eq!(g.visible_row(0).cells()[0].codepoint(), ' ');
    }

    #[test]
    fn new_output_keeps_viewport_anchored() {
        let mut g = filled(1, 2, 5);
        g.scroll_up_full(1, Cell::default());
        g.scroll_viewport(1);
        g.scroll_up_full(1, Cell::default());
        assert_eq!(g.viewport(), 2);
        assert_eq!(g.visible_row(0).cells()[0].codepoint(), '0');
    }

    #[test]
    fn clear_scrollback_keeps_the_screen() {
        let mut g = filled(1, 2, 5);
        g.scroll_up_full(2, Cell::default());
        g.scroll_viewport(2);
        g.clear_scrollback();
        assert_eq!(g.scrollback_len(), 0);
        assert_eq!(g.viewport(), 0);
        assert_eq!(g.first_line_id(), 2);
        assert_eq!(row_text(&g, 0), "");
    }

    #[test]
    fn resize_wider_pads_and_narrower_truncates() {
        let mut g = filled(2, 2, 0);
        g.set_cell(1, 0, ch('x'));
        g.resize(4, 2, Cell::default());
        assert_eq!(g.cols(), 4);
        assert_eq!(g.row(0).len(), 4);
        assert_eq!(row_text(&g, 0), "0x");
        g.resize(1, 2, Cell::default());
        assert_eq!(row_text(&g, 0), "0");
    }

    #[test]
    fn resize_shorter_pushes_top_rows_into_scrollback() {
        let mut g = filled(1, 4, 10);
        g.resize(1, 2, Cell::default());
        assert_eq!(g.rows(), 2);
        assert_eq!(g.scrollback_len(), 2);
        assert_eq!(row_text(&g, 0), "2");
        assert_eq!(g.line(0).unwrap().cells()[0].codepoint(), '0');
    }

    #[test]
    fn resize_taller_pulls_scrollback_back_then_pads() {
        let mut g = filled(1, 2, 10);
        g.scroll_up_full(1, Cell::default());
        g.resize(1, 5, Cell::default());
        assert_eq!(g.rows(), 5);
        assert_eq!(g.scrollback_len(), 0);
        let rows: Vec<String> = (0..5).map(|r| row_text(&g, r)).collect();
        assert_eq!(rows, ["0", "1", "", "", ""]);
        assert!(g.dirty_words() >= 1 && g.is_dirty(4));
    }

    #[test]
    fn resize_after_ring_wrap_preserves_order() {
        let mut g = Grid::new(1, 2, 2);
        for c in ['a', 'b', 'c', 'd', 'e'] {
            g.set_cell(0, 1, ch(c));
            g.scroll_up_full(1, Cell::default());
        }
        g.resize(1, 4, Cell::default());
        let rows: Vec<String> = (0..4).map(|r| row_text(&g, r)).collect();
        assert_eq!(rows, ["c", "d", "e", ""]);
    }

    #[test]
    fn resize_shorter_evicts_rows_beyond_scrollback_cap() {
        let mut g = Grid::new(1, 2, 2);
        for i in 0..10u8 {
            g.set_cell(0, 1, ch((b'a' + i) as char));
            g.scroll_up_full(1, Cell::default());
        }
        assert_eq!(g.scrollback_len(), 2);
        g.resize(1, 1, Cell::default());
        assert_eq!(g.rows(), 1);
        assert_eq!(g.scrollback_len(), 2);
        assert!(g.scrollback_len() <= g.scrollback_capacity());
        assert_eq!(g.line_count(), 3);
        assert_eq!(row_text(&g, 0), "");
        assert_eq!(g.line(g.first_line_id()).unwrap().cells()[0].codepoint(), 'i');
    }
}
