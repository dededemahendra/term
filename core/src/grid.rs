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
    /// `out` are zeroed; a short `out` receives a prefix.
    pub fn take_dirty(&mut self, out: &mut [u64]) {
        let n = out.len().min(self.dirty.len());
        out[..n].copy_from_slice(&self.dirty[..n]);
        for w in &mut out[n..] {
            *w = 0;
        }
        self.dirty.fill(0);
    }

    /// Scrolls the whole screen up by `n`. Top rows enter scrollback and
    /// `n` rows cleared to `template` appear at the bottom.
    pub fn scroll_up_full(&mut self, n: usize, template: Cell) {
        let capacity = self.capacity();
        for _ in 0..n {
            if self.len < capacity {
                self.len += 1;
            } else {
                self.start = (self.start + 1) % capacity;
                self.dropped += 1;
            }
            let i = self.storage_index(self.len - 1);
            self.storage[i].clear(template);
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
    fn dirty_words_covers_all_rows() {
        let g = Grid::new(1, 130, 0);
        assert_eq!(g.dirty_words(), 3);
    }
}
