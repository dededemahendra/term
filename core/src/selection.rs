//! Text selection in line id coordinates, so it survives scrolling.

use crate::cell::flags;
use crate::grid::Grid;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SelectionMode {
    Normal,
    Word,
    Line,
}

impl SelectionMode {
    pub fn from_u8(v: u8) -> SelectionMode {
        match v {
            1 => SelectionMode::Word,
            2 => SelectionMode::Line,
            _ => SelectionMode::Normal,
        }
    }
}

/// A cell position. `line` is a grid line id (see `Grid::visible_line_id`).
/// Ordering is by line, then column.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Point {
    pub line: u64,
    pub col: usize,
}

#[derive(Clone, Copy, Debug)]
pub struct Selection {
    pub anchor: Point,
    pub head: Point,
    pub mode: SelectionMode,
}

fn is_word_char(c: char) -> bool {
    !c.is_whitespace() && !"()[]{}<>'\",;|".contains(c)
}

fn word_start(grid: &Grid, p: Point) -> usize {
    let Some(row) = grid.line(p.line) else { return p.col };
    let cells = row.cells();
    let mut c = p.col.min(cells.len() - 1);
    while c > 0 && is_word_char(cells[c].codepoint()) && is_word_char(cells[c - 1].codepoint()) {
        c -= 1;
    }
    c
}

fn word_end(grid: &Grid, p: Point) -> usize {
    let Some(row) = grid.line(p.line) else { return p.col };
    let cells = row.cells();
    let last = cells.len() - 1;
    let mut c = p.col.min(last);
    while c < last && is_word_char(cells[c].codepoint()) && is_word_char(cells[c + 1].codepoint()) {
        c += 1;
    }
    c
}

impl Selection {
    pub fn new(point: Point, mode: SelectionMode) -> Selection {
        Selection { anchor: point, head: point, mode }
    }

    pub fn extend(&mut self, point: Point) {
        self.head = point;
    }

    /// Ordered, inclusive bounds with the mode's expansion applied.
    pub fn bounds(&self, grid: &Grid) -> (Point, Point) {
        let (mut start, mut end) = if self.anchor <= self.head {
            (self.anchor, self.head)
        } else {
            (self.head, self.anchor)
        };
        match self.mode {
            SelectionMode::Normal => {}
            SelectionMode::Line => {
                start.col = 0;
                end.col = grid.cols() - 1;
            }
            SelectionMode::Word => {
                start.col = word_start(grid, start);
                end.col = word_end(grid, end);
            }
        }
        (start, end)
    }

    pub fn contains(&self, grid: &Grid, point: Point) -> bool {
        let (start, end) = self.bounds(grid);
        point >= start && point <= end
    }

    /// Selected text. Trailing blanks are trimmed per row, wide spacers
    /// skipped, and rows joined with a newline unless soft wrapped.
    pub fn text(&self, grid: &Grid) -> String {
        let (start, end) = self.bounds(grid);
        let mut out = String::new();
        for line in start.line..=end.line {
            let Some(row) = grid.line(line) else { continue };
            let cells = row.cells();
            let last = cells.len() - 1;
            let from = if line == start.line { start.col.min(last) } else { 0 };
            let to = if line == end.line { end.col.min(last) } else { last };
            if from <= to {
                let text: String = cells[from..=to]
                    .iter()
                    .filter(|c| !c.has(flags::WIDE_SPACER))
                    .map(|c| c.codepoint())
                    .collect();
                out.push_str(text.trim_end());
            }
            if line != end.line && !row.wrapped {
                out.push('\n');
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cell::{flags, Cell};
    use crate::grid::Grid;

    fn grid_with(lines: &[&str]) -> Grid {
        let mut g = Grid::new(16, lines.len(), 4);
        for (r, line) in lines.iter().enumerate() {
            for (c, ch) in line.chars().enumerate() {
                g.set_cell(c, r, Cell::default().with_codepoint(ch));
            }
        }
        g
    }

    fn p(line: u64, col: usize) -> Point {
        Point { line, col }
    }

    #[test]
    fn normal_selection_across_lines() {
        let g = grid_with(&["hello", "world"]);
        let mut s = Selection::new(p(0, 2), SelectionMode::Normal);
        s.extend(p(1, 2));
        assert_eq!(s.text(&g), "llo\nwor");
    }

    #[test]
    fn reversed_anchor_is_normalised() {
        let g = grid_with(&["hello", "world"]);
        let mut s = Selection::new(p(1, 2), SelectionMode::Normal);
        s.extend(p(0, 2));
        assert_eq!(s.text(&g), "llo\nwor");
        assert_eq!(s.bounds(&g), (p(0, 2), p(1, 2)));
    }

    #[test]
    fn wrapped_rows_join_without_newline() {
        let mut g = grid_with(&["abcdefgh", "ij"]);
        g.row_mut(0).wrapped = true;
        let mut s = Selection::new(p(0, 0), SelectionMode::Normal);
        s.extend(p(1, 1));
        assert_eq!(s.text(&g), "abcdefghij");
    }

    #[test]
    fn trailing_whitespace_is_trimmed_per_line() {
        let g = grid_with(&["hi      ", "x"]);
        let mut s = Selection::new(p(0, 0), SelectionMode::Normal);
        s.extend(p(1, 7));
        assert_eq!(s.text(&g), "hi\nx");
    }

    #[test]
    fn word_mode_expands_to_word_boundaries() {
        let g = grid_with(&["foo bar-baz qux"]);
        let s = Selection::new(p(0, 5), SelectionMode::Word);
        assert_eq!(s.bounds(&g), (p(0, 4), p(0, 10)));
        assert_eq!(s.text(&g), "bar-baz");
    }

    #[test]
    fn line_mode_takes_whole_lines() {
        let g = grid_with(&["  ab  ", "cd"]);
        let s = Selection::new(p(0, 3), SelectionMode::Line);
        assert_eq!(s.text(&g), "  ab");
    }

    #[test]
    fn wide_spacers_are_skipped() {
        let mut g = grid_with(&[""]);
        g.set_cell(0, 0, Cell::new('日', flags::WIDE, 0, 0));
        g.set_cell(1, 0, Cell::new(' ', flags::WIDE_SPACER, 0, 0));
        g.set_cell(2, 0, Cell::default().with_codepoint('x'));
        let mut s = Selection::new(p(0, 0), SelectionMode::Normal);
        s.extend(p(0, 2));
        assert_eq!(s.text(&g), "日x");
    }

    #[test]
    fn contains_uses_expanded_bounds() {
        let g = grid_with(&["foo bar"]);
        let s = Selection::new(p(0, 5), SelectionMode::Word);
        assert!(s.contains(&g, p(0, 4)));
        assert!(s.contains(&g, p(0, 6)));
        assert!(!s.contains(&g, p(0, 3)));
    }

    #[test]
    fn evicted_lines_are_skipped() {
        let mut g = Grid::new(4, 1, 1);
        for c in ['a', 'b', 'c'] {
            g.set_cell(0, 0, Cell::default().with_codepoint(c));
            if c != 'c' {
                g.scroll_up_full(1, Cell::default());
            }
        }
        assert_eq!(g.first_line_id(), 1);
        let mut s = Selection::new(p(0, 0), SelectionMode::Normal);
        s.extend(p(2, 3));
        assert_eq!(s.text(&g), "b\nc");
    }

    #[test]
    fn selection_mode_from_u8() {
        assert_eq!(SelectionMode::from_u8(0), SelectionMode::Normal);
        assert_eq!(SelectionMode::from_u8(1), SelectionMode::Word);
        assert_eq!(SelectionMode::from_u8(2), SelectionMode::Line);
        assert_eq!(SelectionMode::from_u8(9), SelectionMode::Normal);
    }
}
