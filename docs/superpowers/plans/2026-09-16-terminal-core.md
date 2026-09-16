# Terminal Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the portable Rust core of the terminal emulator: VT parser integration, packed cell grid with scrollback, screen state, selection, a C ABI, plus compatibility snapshots, a chaos test, a fuzz target and a throughput benchmark.

**Architecture:** A single Rust crate `termcore` with one module per responsibility (cell, color, grid, screen, selection, term, ffi). The `vte` crate drives a `Screen` that implements `vte::Perform`. `Term` wraps parser plus screen plus selection and is the only type the C ABI touches. No platform code anywhere in this plan; the macOS shell is a second plan written after this core exists.

**Tech Stack:** Rust 1.98.1 (edition 2021), `vte` 0.15, `unicode-width` 0.2, `cargo-fuzz` 0.13 (nightly, fuzz only). No other dependencies.

**Spec:** `docs/superpowers/specs/2026-09-16-terminal-emulator-design.md`

## Global Constraints

- Rust toolchain pinned to `1.98.1` via `rust-toolchain.toml`. Edition `2021`.
- Only two runtime dependencies: `vte = "0.15"` and `unicode-width = "0.2"`.
- The core never panics on input. Any byte sequence is consumed or ignored.
- Feeding bytes never allocates on the parse and grid path. Documented exceptions: the first sighting of a new 24-bit colour interns it into the overflow table; DSR and DA reply bytes and the OSC title string may allocate; RIS (ESC c, a full reset) rebuilds the screen and may allocate. Resize is not on the feed path.
- A cell is one packed `u64`: bits 0..21 codepoint, 21..29 flags, 29..45 fg index, 45..61 bg index, bit 61 selected, 62..64 reserved.
- Colour index `0xFFFF` means "default colour". Indices 0..256 are the palette, 256..0xFFFF the overflow table (65,279 entries).
- The C ABI is the only boundary. No callbacks from Rust into the shell. Every function returns a status code or a length.
- Mouse and focus report encoding is the shell's job. The core exposes the modes; the core's response buffer only carries replies the parser itself triggered (DSR, DA).
- Australian English, no em dashes, sentence case in all docs and comments.
- Commit after every task with a Conventional Commits message.

## File structure

```
term/
  Cargo.toml                     workspace root, release profile
  rust-toolchain.toml
  .gitignore
  core/
    Cargo.toml                   crate termcore, rlib + staticlib + cdylib
    include/termcore.h           hand written C header matching ffi.rs
    src/
      lib.rs                     module list only
      cell.rs                    packed Cell, flags, DEFAULT_COLOR
      color.rs                   Rgb, palette256, ColorTable (overflow interning)
      grid.rs                    Row, Grid ring buffer, scrollback, viewport, dirty bitmap
      screen.rs                  Screen: cursor, modes, SGR, scroll region, alt screen, vte::Perform
      selection.rs               Selection, Point, text extraction
      term.rs                    Term: parser + screen + selection, copy_visible, dump
      ffi.rs                     extern "C" surface
    tests/
      chaos.rs                   deterministic random byte torture test
      ffi.rs                     exercises the C ABI from Rust
      compat.rs                  snapshot runner
      compat/
        make_fixtures.sh         regenerates the hand written .in fixtures
        record.sh                records a real program into a .in fixture
        *.in, *.snap
    fuzz/
      Cargo.toml
      fuzz_targets/feed.rs
  bench/
    Cargo.toml                   crate termbench
    src/main.rs                  100 MB feed throughput
    results.md
```

---

### Task 1: Workspace scaffold

**Files:**
- Create: `Cargo.toml`
- Create: `rust-toolchain.toml`
- Create: `.gitignore`
- Create: `core/Cargo.toml`
- Create: `core/src/lib.rs`

**Interfaces:**
- Produces: crate `termcore` that later tasks add modules to.

- [ ] **Step 1: Write the workspace root**

`Cargo.toml`:

```toml
[workspace]
resolver = "2"
members = ["core"]
exclude = ["core/fuzz"]

[profile.release]
lto = "fat"
codegen-units = 1
panic = "abort"
opt-level = 3
```

`rust-toolchain.toml`:

```toml
[toolchain]
channel = "1.98.1"
profile = "minimal"
```

`.gitignore`:

```
/target
/core/fuzz/target
/core/fuzz/corpus
/core/fuzz/artifacts
.DS_Store
```

- [ ] **Step 2: Write the core crate**

`core/Cargo.toml`:

```toml
[package]
name = "termcore"
version = "0.1.0"
edition = "2021"
description = "Portable terminal emulator core: parser, grid, screen state, C ABI"
license = "MIT"

[lib]
name = "termcore"
crate-type = ["rlib", "staticlib", "cdylib"]

[dependencies]
vte = "0.15"
unicode-width = "0.2"
```

`core/src/lib.rs`:

```rust
//! Portable terminal emulator core.
//!
//! Bytes in, cells out. No windows, fonts, GPUs or processes live here.

#[cfg(test)]
mod smoke {
    #[test]
    fn workspace_builds() {
        assert_eq!(2 + 2, 4);
    }
}
```

- [ ] **Step 3: Run the smoke test**

Run: `cargo test -p termcore`
Expected: `test smoke::workspace_builds ... ok`, 1 passed.

- [ ] **Step 4: Confirm the static library builds**

Run: `cargo build -p termcore --release && ls target/release/libtermcore.a`
Expected: the `.a` path is printed.

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml rust-toolchain.toml .gitignore core
git commit -m "chore: scaffold termcore workspace"
```

---

### Task 2: Packed cell

**Files:**
- Create: `core/src/cell.rs`
- Modify: `core/src/lib.rs`

**Interfaces:**
- Produces: `Cell` (`#[repr(transparent)]` over `u64`), `Cell::new(char, u8, u16, u16)`, `codepoint()`, `flags()`, `fg()`, `bg()`, `selected()`, `has(u8)`, `with_codepoint`, `with_flags`, `with_fg`, `with_bg`, `with_selected`, `raw()`, module `flags` with `BOLD ITALIC UNDERLINE STRIKE INVERSE WIDE WIDE_SPACER DIM`, const `DEFAULT_COLOR: u16 = 0xFFFF`. `Cell::default()` is a space with default colours and no flags.

- [ ] **Step 1: Write the failing tests**

`core/src/cell.rs` (tests only for now, the implementation comes in step 3; write the whole file in step 3 and the tests are the `mod tests` block at the bottom):

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrips_every_field() {
        let c = Cell::new('é', flags::BOLD | flags::UNDERLINE, 12, 300);
        assert_eq!(c.codepoint(), 'é');
        assert_eq!(c.flags(), flags::BOLD | flags::UNDERLINE);
        assert_eq!(c.fg(), 12);
        assert_eq!(c.bg(), 300);
        assert!(!c.selected());
    }

    #[test]
    fn default_is_blank_with_default_colours() {
        let c = Cell::default();
        assert_eq!(c.codepoint(), ' ');
        assert_eq!(c.flags(), 0);
        assert_eq!(c.fg(), DEFAULT_COLOR);
        assert_eq!(c.bg(), DEFAULT_COLOR);
    }

    #[test]
    fn with_setters_leave_other_fields_alone() {
        let c = Cell::new('a', flags::ITALIC, 1, 2);
        let d = c.with_codepoint('b').with_fg(0xFFFF).with_bg(255).with_flags(flags::WIDE);
        assert_eq!(d.codepoint(), 'b');
        assert_eq!(d.flags(), flags::WIDE);
        assert_eq!(d.fg(), 0xFFFF);
        assert_eq!(d.bg(), 255);
        assert_eq!(c.codepoint(), 'a');
    }

    #[test]
    fn selected_bit_is_outside_flags() {
        let c = Cell::new('x', 0xFF, 0xFFFF, 0xFFFF).with_selected(true);
        assert!(c.selected());
        assert_eq!(c.flags(), 0xFF);
        assert_eq!(c.codepoint(), 'x');
        assert!(!c.with_selected(false).selected());
    }

    #[test]
    fn max_codepoint_fits() {
        let c = Cell::new('\u{10FFFF}', 0, 0, 0);
        assert_eq!(c.codepoint(), '\u{10FFFF}');
    }

    #[test]
    fn has_checks_a_single_flag() {
        let c = Cell::new(' ', flags::WIDE_SPACER, 0, 0);
        assert!(c.has(flags::WIDE_SPACER));
        assert!(!c.has(flags::WIDE));
    }
}
```

- [ ] **Step 2: Run to verify failure**

Add `pub mod cell;` to `core/src/lib.rs` (above the smoke module), create `core/src/cell.rs` containing only the tests block above, then run:

Run: `cargo test -p termcore cell`
Expected: compile error, `Cell` not found.

- [ ] **Step 3: Write the implementation**

Replace `core/src/cell.rs` with the full file (keep the tests block at the bottom):

```rust
//! Packed 64-bit terminal cell.
//!
//! Layout, least significant bit first:
//!
//! | bits   | field                                             |
//! |--------|---------------------------------------------------|
//! | 0..21  | codepoint (21 bits, max 0x10FFFF)                 |
//! | 21..29 | flags (8 bits, see [`flags`])                     |
//! | 29..45 | foreground colour index (16 bits)                 |
//! | 45..61 | background colour index (16 bits)                 |
//! | 61     | selected (set only on copies handed to renderer)  |
//! | 62..64 | reserved                                          |

/// Style flag bits. Combine with `|`.
pub mod flags {
    pub const BOLD: u8 = 1 << 0;
    pub const ITALIC: u8 = 1 << 1;
    pub const UNDERLINE: u8 = 1 << 2;
    pub const STRIKE: u8 = 1 << 3;
    pub const INVERSE: u8 = 1 << 4;
    /// First half of a two column glyph.
    pub const WIDE: u8 = 1 << 5;
    /// Second half of a two column glyph. Never rendered.
    pub const WIDE_SPACER: u8 = 1 << 6;
    pub const DIM: u8 = 1 << 7;
}

/// Colour index meaning "use the configured default foreground or background".
pub const DEFAULT_COLOR: u16 = 0xFFFF;

const CP_MASK: u64 = (1 << 21) - 1;
const FLAGS_SHIFT: u32 = 21;
const FLAGS_MASK: u64 = 0xFF << FLAGS_SHIFT;
const FG_SHIFT: u32 = 29;
const FG_MASK: u64 = 0xFFFF << FG_SHIFT;
const BG_SHIFT: u32 = 45;
const BG_MASK: u64 = 0xFFFF << BG_SHIFT;
const SELECTED_BIT: u64 = 1 << 61;

#[repr(transparent)]
#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub struct Cell(u64);

impl Default for Cell {
    fn default() -> Self {
        Cell::new(' ', 0, DEFAULT_COLOR, DEFAULT_COLOR)
    }
}

impl Cell {
    pub const fn new(c: char, flags: u8, fg: u16, bg: u16) -> Cell {
        Cell(
            (c as u64 & CP_MASK)
                | ((flags as u64) << FLAGS_SHIFT)
                | ((fg as u64) << FG_SHIFT)
                | ((bg as u64) << BG_SHIFT),
        )
    }

    pub fn codepoint(self) -> char {
        char::from_u32((self.0 & CP_MASK) as u32).unwrap_or(' ')
    }

    pub const fn flags(self) -> u8 {
        ((self.0 & FLAGS_MASK) >> FLAGS_SHIFT) as u8
    }

    pub const fn fg(self) -> u16 {
        ((self.0 & FG_MASK) >> FG_SHIFT) as u16
    }

    pub const fn bg(self) -> u16 {
        ((self.0 & BG_MASK) >> BG_SHIFT) as u16
    }

    pub const fn selected(self) -> bool {
        self.0 & SELECTED_BIT != 0
    }

    pub const fn has(self, flag: u8) -> bool {
        self.flags() & flag != 0
    }

    pub const fn with_codepoint(self, c: char) -> Cell {
        Cell((self.0 & !CP_MASK) | (c as u64 & CP_MASK))
    }

    pub const fn with_flags(self, flags: u8) -> Cell {
        Cell((self.0 & !FLAGS_MASK) | ((flags as u64) << FLAGS_SHIFT))
    }

    pub const fn with_fg(self, fg: u16) -> Cell {
        Cell((self.0 & !FG_MASK) | ((fg as u64) << FG_SHIFT))
    }

    pub const fn with_bg(self, bg: u16) -> Cell {
        Cell((self.0 & !BG_MASK) | ((bg as u64) << BG_SHIFT))
    }

    pub const fn with_selected(self, selected: bool) -> Cell {
        if selected {
            Cell(self.0 | SELECTED_BIT)
        } else {
            Cell(self.0 & !SELECTED_BIT)
        }
    }

    pub const fn raw(self) -> u64 {
        self.0
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cargo test -p termcore cell`
Expected: 6 passed.

- [ ] **Step 5: Commit**

```bash
git add core/src/cell.rs core/src/lib.rs
git commit -m "feat(core): add packed 64-bit cell"
```

---

### Task 3: Colour table

**Files:**
- Create: `core/src/color.rs`
- Modify: `core/src/lib.rs`

**Interfaces:**
- Consumes: `cell::DEFAULT_COLOR`.
- Produces: `Rgb { r, g, b }` (`#[repr(C)]`), `palette256(u8) -> Rgb`, `FIRST_OVERFLOW_INDEX: u16 = 256`, `MAX_OVERFLOW: usize`, `ColorTable::new()`, `intern(Rgb) -> Option<u16>`, `get(u16) -> Option<Rgb>`, `entries() -> &[Rgb]`, `reset()`.

- [ ] **Step 1: Write the failing tests**

Add `pub mod color;` to `core/src/lib.rs` and create `core/src/color.rs` with only this block:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn palette_endpoints_match_xterm() {
        assert_eq!(palette256(0), Rgb { r: 0, g: 0, b: 0 });
        assert_eq!(palette256(1), Rgb { r: 205, g: 0, b: 0 });
        assert_eq!(palette256(15), Rgb { r: 255, g: 255, b: 255 });
        assert_eq!(palette256(16), Rgb { r: 0, g: 0, b: 0 });
        assert_eq!(palette256(21), Rgb { r: 0, g: 0, b: 255 });
        assert_eq!(palette256(231), Rgb { r: 255, g: 255, b: 255 });
        assert_eq!(palette256(232), Rgb { r: 8, g: 8, b: 8 });
        assert_eq!(palette256(255), Rgb { r: 238, g: 238, b: 238 });
    }

    #[test]
    fn intern_returns_stable_indices_from_256() {
        let mut t = ColorTable::new();
        let a = t.intern(Rgb { r: 1, g: 2, b: 3 }).unwrap();
        let b = t.intern(Rgb { r: 4, g: 5, b: 6 }).unwrap();
        let a_again = t.intern(Rgb { r: 1, g: 2, b: 3 }).unwrap();
        assert_eq!(a, 256);
        assert_eq!(b, 257);
        assert_eq!(a_again, a);
        assert_eq!(t.get(a), Some(Rgb { r: 1, g: 2, b: 3 }));
        assert_eq!(t.entries().len(), 2);
    }

    #[test]
    fn get_below_256_uses_palette_and_default_is_none() {
        let t = ColorTable::new();
        assert_eq!(t.get(1), Some(Rgb { r: 205, g: 0, b: 0 }));
        assert_eq!(t.get(crate::cell::DEFAULT_COLOR), None);
        assert_eq!(t.get(300), None);
    }

    #[test]
    fn reset_empties_the_table() {
        let mut t = ColorTable::new();
        t.intern(Rgb { r: 9, g: 9, b: 9 });
        t.reset();
        assert!(t.entries().is_empty());
        assert_eq!(t.intern(Rgb { r: 9, g: 9, b: 9 }), Some(256));
    }

    #[test]
    fn table_is_bounded() {
        let mut t = ColorTable::new();
        let mut last = None;
        for i in 0..MAX_OVERFLOW {
            let rgb = Rgb { r: (i >> 16) as u8, g: (i >> 8) as u8, b: i as u8 };
            last = t.intern(rgb);
            assert!(last.is_some());
        }
        assert_eq!(last, Some(0xFFFE));
        assert_eq!(t.intern(Rgb { r: 255, g: 255, b: 255 }), None);
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p termcore color`
Expected: compile error, `Rgb` not found.

- [ ] **Step 3: Write the implementation**

Replace `core/src/color.rs` with the full file (tests block stays at the bottom):

```rust
//! Colour indices and the 24-bit overflow table.
//!
//! Cells store a 16-bit colour index. 0..256 is the xterm palette (the
//! shell may override 0..16 from config). 256..0xFFFF are 24-bit colours
//! interned on first sight. 0xFFFF is the default colour marker.

use std::collections::HashMap;

use crate::cell::DEFAULT_COLOR;

#[repr(C)]
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

pub const FIRST_OVERFLOW_INDEX: u16 = 256;
/// Number of 24-bit colours the overflow table can hold.
pub const MAX_OVERFLOW: usize = DEFAULT_COLOR as usize - FIRST_OVERFLOW_INDEX as usize;

const ANSI16: [Rgb; 16] = [
    Rgb { r: 0, g: 0, b: 0 },
    Rgb { r: 205, g: 0, b: 0 },
    Rgb { r: 0, g: 205, b: 0 },
    Rgb { r: 205, g: 205, b: 0 },
    Rgb { r: 0, g: 0, b: 238 },
    Rgb { r: 205, g: 0, b: 205 },
    Rgb { r: 0, g: 205, b: 205 },
    Rgb { r: 229, g: 229, b: 229 },
    Rgb { r: 127, g: 127, b: 127 },
    Rgb { r: 255, g: 0, b: 0 },
    Rgb { r: 0, g: 255, b: 0 },
    Rgb { r: 255, g: 255, b: 0 },
    Rgb { r: 92, g: 92, b: 255 },
    Rgb { r: 255, g: 0, b: 255 },
    Rgb { r: 0, g: 255, b: 255 },
    Rgb { r: 255, g: 255, b: 255 },
];

fn cube(v: u8) -> u8 {
    if v == 0 {
        0
    } else {
        55 + v * 40
    }
}

/// Standard xterm 256 colour palette.
pub fn palette256(index: u8) -> Rgb {
    match index {
        0..=15 => ANSI16[index as usize],
        16..=231 => {
            let i = index - 16;
            Rgb { r: cube(i / 36), g: cube((i % 36) / 6), b: cube(i % 6) }
        }
        232..=255 => {
            let v = 8 + (index - 232) * 10;
            Rgb { r: v, g: v, b: v }
        }
    }
}

#[derive(Debug, Default)]
pub struct ColorTable {
    entries: Vec<Rgb>,
    lookup: HashMap<Rgb, u16>,
}

impl ColorTable {
    pub fn new() -> ColorTable {
        ColorTable::default()
    }

    /// Returns the index for `rgb`, adding it if unseen. `None` when full.
    pub fn intern(&mut self, rgb: Rgb) -> Option<u16> {
        if let Some(&i) = self.lookup.get(&rgb) {
            return Some(i);
        }
        if self.entries.len() >= MAX_OVERFLOW {
            return None;
        }
        let index = FIRST_OVERFLOW_INDEX + self.entries.len() as u16;
        self.entries.push(rgb);
        self.lookup.insert(rgb, index);
        Some(index)
    }

    /// Resolves an index. Palette for 0..256, table above, `None` for
    /// the default marker or an unknown index.
    pub fn get(&self, index: u16) -> Option<Rgb> {
        if index < FIRST_OVERFLOW_INDEX {
            Some(palette256(index as u8))
        } else if index == DEFAULT_COLOR {
            None
        } else {
            self.entries.get((index - FIRST_OVERFLOW_INDEX) as usize).copied()
        }
    }

    /// Overflow entries in index order, starting at index 256.
    pub fn entries(&self) -> &[Rgb] {
        &self.entries
    }

    pub fn reset(&mut self) {
        self.entries.clear();
        self.lookup.clear();
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cargo test -p termcore color`
Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
git add core/src/color.rs core/src/lib.rs
git commit -m "feat(core): add palette and 24-bit colour overflow table"
```

---

### Task 4: Grid ring buffer, scrollback and dirty rows

**Files:**
- Create: `core/src/grid.rs`
- Modify: `core/src/lib.rs`

**Interfaces:**
- Consumes: `cell::Cell`.
- Produces: `Row` (`new(cols)`, `cells()`, `cells_mut()`, `len()`, `clear(Cell)`, `resize(usize, Cell)`, pub field `wrapped: bool`), `Grid::new(cols, rows, scrollback)`, `cols()`, `rows()`, `scrollback_capacity()`, `scrollback_len()`, `row(r)`, `row_mut(r)` (marks dirty), `cell(col, row)`, `set_cell(col, row, Cell)`, `mark_dirty(r)`, `mark_all_dirty()`, `is_dirty(r)`, `dirty_words()`, `take_dirty(&mut [u64])`, `scroll_up_full(n, Cell)`, `first_line_id()`, `line_count()`, `line(id) -> Option<&Row>`, `screen_line_id(r)`.
- Coordinates: a **screen row** `r` in `0..rows` is what the cursor addresses. A **line id** is a `u64` that names one row for its whole life in the ring, so selections survive scrolling.

- [ ] **Step 1: Write the failing tests**

Add `pub mod grid;` to `core/src/lib.rs` and create `core/src/grid.rs` with only this block:

```rust
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
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p termcore grid`
Expected: compile error, `Grid` not found.

- [ ] **Step 3: Write the implementation**

Replace `core/src/grid.rs` with the full file (tests block at the bottom):

```rust
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
```

- [ ] **Step 4: Run to verify pass**

Run: `cargo test -p termcore grid`
Expected: 7 passed.

- [ ] **Step 5: Commit**

```bash
git add core/src/grid.rs core/src/lib.rs
git commit -m "feat(core): add grid ring buffer with scrollback and dirty rows"
```

---

### Task 5: Grid region scrolling, viewport and resize

**Files:**
- Modify: `core/src/grid.rs`

**Interfaces:**
- Produces on `Grid`: `scroll_up_region(top, bottom, n, Cell)`, `scroll_down_region(top, bottom, n, Cell)`, `clear_scrollback()`, `viewport()`, `scroll_viewport(delta: i32)` (positive = older), `visible_row(r)`, `visible_line_id(r)`, `resize(cols, rows, Cell)`.

- [ ] **Step 1: Write the failing tests**

Append inside the existing `mod tests` in `core/src/grid.rs`:

```rust
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
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p termcore grid`
Expected: compile error, no method `scroll_up_region`.

- [ ] **Step 3: Write the implementation**

Add these methods inside `impl Grid` in `core/src/grid.rs`, after `screen_line_id`:

```rust
    /// Scrolls rows `top..=bottom` up by `n`. Rows leaving the top of a
    /// partial region are lost; a full screen region uses scrollback.
    pub fn scroll_up_region(&mut self, top: usize, bottom: usize, n: usize, template: Cell) {
        if top == 0 && bottom == self.rows - 1 {
            return self.scroll_up_full(n, template);
        }
        if top > bottom || bottom >= self.rows || n == 0 {
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
```

- [ ] **Step 4: Run to verify pass**

Run: `cargo test -p termcore grid`
Expected: 19 passed.

- [ ] **Step 5: Commit**

```bash
git add core/src/grid.rs
git commit -m "feat(core): add region scrolling, viewport and resize to grid"
```

---

### Task 6: Screen printing, control characters and wrapping

**Files:**
- Create: `core/src/screen.rs`
- Modify: `core/src/lib.rs`

**Interfaces:**
- Consumes: `Grid`, `Row`, `Cell`, `flags`, `DEFAULT_COLOR`, `unicode_width::UnicodeWidthChar`, `vte::Perform`.
- Produces: `Cursor { col, row, pending_wrap }`, `Modes` (`#[repr(C)]`, all one-byte fields, `Default` has `autowrap = true`, `cursor_visible = true`), `Screen::new(cols, rows, scrollback)`, `grid()`, `grid_mut()`, `cols()`, `rows()`, `cursor()`, `modes()`, `template()`, `row_text(r)`. Private helpers later tasks call: `blank()`, `linefeed()`, `carriage_return()`, `tab_forward()`, `split_wide(col, row)`, `put_char(c, width)`. `Screen` implements `vte::Perform` with `print` and `execute`.
- Test helper pattern used by every screen test from here on:

```rust
fn feed(s: &mut Screen, bytes: &[u8]) {
    let mut parser = vte::Parser::new();
    parser.advance(s, bytes);
}
```

- [ ] **Step 1: Write the failing tests**

Add `pub mod screen;` to `core/src/lib.rs` and create `core/src/screen.rs` with only this block:

```rust
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
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p termcore screen`
Expected: compile error, `Screen` not found.

- [ ] **Step 3: Write the implementation**

Replace `core/src/screen.rs` with the full file (tests block at the bottom):

```rust
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
```

- [ ] **Step 4: Run to verify pass**

Run: `cargo test -p termcore screen`
Expected: 10 passed.

- [ ] **Step 5: Commit**

```bash
git add core/src/screen.rs core/src/lib.rs
git commit -m "feat(core): add screen with printing, wrapping and control characters"
```

---

### Task 7: CSI cursor movement, erase, insert, delete, scroll region, reports

**Files:**
- Modify: `core/src/screen.rs`

**Interfaces:**
- Produces on `Screen`: `take_responses(&mut [u8]) -> usize`, `responses_len()`, `resize(cols, rows)`. Private: `move_cursor_to(row, col)`, `report(&str)`, `set_cursor_style(u16)`. Free functions `param(&Params, index, default) -> u16` (treats 0 as absent) and `param0(&Params, index) -> u16` (0 when absent). `csi_dispatch` on the `Perform` impl, with arms for `m`, `h`, `l`, `s`, `u` added in Tasks 8 and 9.
- New fields on `Screen`: `responses: Vec<u8>`, `last_char: Option<char>`.

- [ ] **Step 1: Write the failing tests**

Append inside `mod tests` in `core/src/screen.rs`:

```rust
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
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p termcore screen`
Expected: compile error, no method `take_responses`, plus failing CSI tests.

- [ ] **Step 3: Write the implementation**

In `core/src/screen.rs`:

Change the vte import to:

```rust
use vte::{Params, Perform};
```

Add two free functions after `default_tabs`:

```rust
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
```

Add fields to `Screen` (after `modes`) and initialise them in `new`:

```rust
    responses: Vec<u8>,
    last_char: Option<char>,
```

```rust
            responses: Vec::new(),
            last_char: None,
```

In `put_char`, add as the last line of the function:

```rust
        self.last_char = Some(c);
```

Add these methods to `impl Screen` after `put_char`:

```rust
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
```

Add `csi_dispatch` to the `impl Perform for Screen` block, after `execute`:

```rust
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
```

- [ ] **Step 4: Run to verify pass**

Run: `cargo test -p termcore screen`
Expected: 28 passed.

- [ ] **Step 5: Commit**

```bash
git add core/src/screen.rs
git commit -m "feat(core): add CSI cursor, erase, scroll region and device reports"
```

---

### Task 8: SGR attributes and colours

**Files:**
- Modify: `core/src/screen.rs`

**Interfaces:**
- Consumes: `ColorTable`, `Rgb`, `vte::ParamsIter`.
- Produces on `Screen`: `colors() -> &ColorTable`. Private `sgr(&Params)`. New field `colors: ColorTable`. Free function `ext_arg(&[u16], &mut ParamsIter, usize) -> Option<u16>`.

- [ ] **Step 1: Write the failing tests**

Append inside `mod tests` in `core/src/screen.rs`:

```rust
    #[test]
    fn sgr_bold_red() {
        let mut s = screen(10, 1);
        feed(&mut s, b"\x1b[1;31mX");
        let c = s.grid().cell(0, 0);
        assert_eq!(c.flags(), flags::BOLD);
        assert_eq!(c.fg(), 1);
        assert_eq!(c.bg(), crate::cell::DEFAULT_COLOR);
    }

    #[test]
    fn sgr_reset_with_zero_and_with_no_parameter() {
        let mut s = screen(10, 1);
        feed(&mut s, b"\x1b[1mX\x1b[0mY\x1b[4mZ\x1b[mW");
        assert_eq!(s.grid().cell(0, 0).flags(), flags::BOLD);
        assert_eq!(s.grid().cell(1, 0).flags(), 0);
        assert_eq!(s.grid().cell(2, 0).flags(), flags::UNDERLINE);
        assert_eq!(s.grid().cell(3, 0).flags(), 0);
    }

    #[test]
    fn sgr_truecolor_semicolon_form() {
        let mut s = screen(10, 1);
        feed(&mut s, b"\x1b[38;2;10;20;30mX");
        let fg = s.grid().cell(0, 0).fg();
        assert!(fg >= 256);
        assert_eq!(s.colors().get(fg), Some(Rgb { r: 10, g: 20, b: 30 }));
    }

    #[test]
    fn sgr_truecolor_colon_forms() {
        let mut s = screen(10, 1);
        feed(&mut s, b"\x1b[38:2::1:2:3mA\x1b[48:2:4:5:6mB");
        let a = s.grid().cell(0, 0);
        let b = s.grid().cell(1, 0);
        assert_eq!(s.colors().get(a.fg()), Some(Rgb { r: 1, g: 2, b: 3 }));
        assert_eq!(s.colors().get(b.bg()), Some(Rgb { r: 4, g: 5, b: 6 }));
        assert_eq!(a.fg(), b.fg());
    }

    #[test]
    fn sgr_indexed_256() {
        let mut s = screen(10, 1);
        feed(&mut s, b"\x1b[38;5;200mX\x1b[48:5:100mY");
        assert_eq!(s.grid().cell(0, 0).fg(), 200);
        assert_eq!(s.grid().cell(1, 0).bg(), 100);
    }

    #[test]
    fn sgr_bright_and_default_colours() {
        let mut s = screen(10, 1);
        feed(&mut s, b"\x1b[92;103mX\x1b[39;49mY");
        let x = s.grid().cell(0, 0);
        let y = s.grid().cell(1, 0);
        assert_eq!((x.fg(), x.bg()), (10, 11));
        assert_eq!((y.fg(), y.bg()), (crate::cell::DEFAULT_COLOR, crate::cell::DEFAULT_COLOR));
    }

    #[test]
    fn sgr_clears_individual_attributes() {
        let mut s = screen(10, 1);
        feed(&mut s, b"\x1b[1;2;3;4;7;9mA\x1b[22;23;24;27;29mB");
        let all = flags::BOLD | flags::DIM | flags::ITALIC | flags::UNDERLINE | flags::INVERSE | flags::STRIKE;
        assert_eq!(s.grid().cell(0, 0).flags(), all);
        assert_eq!(s.grid().cell(1, 0).flags(), 0);
    }

    #[test]
    fn sgr_does_not_touch_existing_cells() {
        let mut s = screen(10, 1);
        feed(&mut s, b"A\x1b[1mB");
        assert_eq!(s.grid().cell(0, 0).flags(), 0);
        assert_eq!(s.grid().cell(1, 0).flags(), flags::BOLD);
    }

    #[test]
    fn erase_uses_current_background_only() {
        let mut s = screen(10, 1);
        feed(&mut s, b"\x1b[1;31;44m\x1b[2K");
        let c = s.grid().cell(5, 0);
        assert_eq!(c.bg(), 4);
        assert_eq!(c.fg(), crate::cell::DEFAULT_COLOR);
        assert_eq!(c.flags(), 0);
    }

    #[test]
    fn sgr_truncated_extended_colour_is_ignored() {
        let mut s = screen(10, 1);
        feed(&mut s, b"\x1b[38;2;1mX\x1b[38;5mY");
        assert_eq!(s.grid().cell(0, 0).fg(), crate::cell::DEFAULT_COLOR);
        assert_eq!(s.grid().cell(1, 0).fg(), crate::cell::DEFAULT_COLOR);
    }
```

Also add to the `use` lines at the top of `mod tests`:

```rust
    use crate::color::Rgb;
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p termcore screen`
Expected: compile error, no method `colors`.

- [ ] **Step 3: Write the implementation**

In `core/src/screen.rs`:

Change the imports to:

```rust
use vte::{Params, ParamsIter, Perform};

use crate::cell::{flags, Cell, DEFAULT_COLOR};
use crate::color::{ColorTable, Rgb};
use crate::grid::Grid;
```

Add a free function after `param0`:

```rust
/// Argument `index` of an extended colour spec. Colon form carries the
/// arguments as subparameters of `p`; semicolon form spreads them over
/// the following parameters in `it`.
fn ext_arg(p: &[u16], it: &mut ParamsIter<'_>, index: usize) -> Option<u16> {
    if p.len() > 1 {
        p.get(index).copied()
    } else {
        it.next().map(|next| next[0])
    }
}
```

Add a field to `Screen` (after `last_char`) and initialise it in `new`:

```rust
    colors: ColorTable,
```

```rust
            colors: ColorTable::new(),
```

Add to `impl Screen`:

```rust
    pub fn colors(&self) -> &ColorTable {
        &self.colors
    }

    fn add_flag(&mut self, flag: u8) {
        self.template = self.template.with_flags(self.template.flags() | flag);
    }

    fn remove_flag(&mut self, flag: u8) {
        self.template = self.template.with_flags(self.template.flags() & !flag);
    }

    /// Resolves a 38 or 48 colour spec. Returns a palette index for
    /// `;5;n`, an interned index for `;2;r;g;b`, `None` when malformed.
    fn extended_color(&mut self, p: &[u16], it: &mut ParamsIter<'_>) -> Option<u16> {
        match ext_arg(p, it, 1)? {
            5 => Some(ext_arg(p, it, 2)?.min(255)),
            2 => {
                let (r, g, b) = if p.len() > 1 {
                    match p.len() {
                        5 => (p[2], p[3], p[4]),
                        6.. => (p[3], p[4], p[5]),
                        _ => return None,
                    }
                } else {
                    (it.next()?[0], it.next()?[0], it.next()?[0])
                };
                let rgb = Rgb { r: r.min(255) as u8, g: g.min(255) as u8, b: b.min(255) as u8 };
                self.colors.intern(rgb)
            }
            _ => None,
        }
    }

    fn sgr(&mut self, params: &Params) {
        let mut it = params.iter();
        while let Some(p) = it.next() {
            match p[0] {
                0 => self.template = Cell::default(),
                1 => self.add_flag(flags::BOLD),
                2 => self.add_flag(flags::DIM),
                3 => self.add_flag(flags::ITALIC),
                4 => self.add_flag(flags::UNDERLINE),
                7 => self.add_flag(flags::INVERSE),
                9 => self.add_flag(flags::STRIKE),
                22 => self.remove_flag(flags::BOLD | flags::DIM),
                23 => self.remove_flag(flags::ITALIC),
                24 => self.remove_flag(flags::UNDERLINE),
                27 => self.remove_flag(flags::INVERSE),
                29 => self.remove_flag(flags::STRIKE),
                30..=37 => self.template = self.template.with_fg(p[0] - 30),
                38 => {
                    if let Some(index) = self.extended_color(p, &mut it) {
                        self.template = self.template.with_fg(index);
                    }
                }
                39 => self.template = self.template.with_fg(DEFAULT_COLOR),
                40..=47 => self.template = self.template.with_bg(p[0] - 40),
                48 => {
                    if let Some(index) = self.extended_color(p, &mut it) {
                        self.template = self.template.with_bg(index);
                    }
                }
                49 => self.template = self.template.with_bg(DEFAULT_COLOR),
                90..=97 => self.template = self.template.with_fg(p[0] - 90 + 8),
                100..=107 => self.template = self.template.with_bg(p[0] - 100 + 8),
                _ => {}
            }
        }
    }
```

Add the arm to `csi_dispatch`, before the `_ => {}` arm:

```rust
            (b"", 'm') => self.sgr(params),
```

- [ ] **Step 4: Run to verify pass**

Run: `cargo test -p termcore screen`
Expected: 38 passed.

- [ ] **Step 5: Commit**

```bash
git add core/src/screen.rs
git commit -m "feat(core): add SGR attributes, 256 colour and 24-bit colour"
```

---

### Task 9: Modes, alternate screen, save and restore, ESC and OSC

**Files:**
- Modify: `core/src/screen.rs`

**Interfaces:**
- Produces on `Screen`: `title() -> &str`. Private: `set_modes`, `set_private_mode`, `switch_alt`, `save_cursor`, `restore_cursor`, `reverse_index`, `reset`. New fields: `saved_primary: Option<SavedCursor>`, `saved_alt: Option<SavedCursor>`, `title: String`. `esc_dispatch` and `osc_dispatch` on the `Perform` impl. DCS (`hook`, `put`, `unhook`) stays at the trait default, which ignores it.

- [ ] **Step 1: Write the failing tests**

Append inside `mod tests` in `core/src/screen.rs`:

```rust
    #[test]
    fn decset_and_decrst_flip_modes() {
        let mut s = screen(10, 2);
        feed(&mut s, b"\x1b[?1h\x1b[?2004h\x1b[?1000h\x1b[?1006h\x1b[?1004h\x1b[?25l\x1b[?7l\x1b[4h\x1b[?12h");
        let m = s.modes();
        assert!(m.app_cursor && m.bracketed_paste && m.mouse_sgr && m.focus_events && m.insert && m.cursor_blink);
        assert!(!m.cursor_visible && !m.autowrap);
        assert_eq!(m.mouse, 2);
        feed(&mut s, b"\x1b[?1002h");
        assert_eq!(s.modes().mouse, 3);
        feed(&mut s, b"\x1b[?1003h");
        assert_eq!(s.modes().mouse, 4);
        feed(&mut s, b"\x1b[?9h");
        assert_eq!(s.modes().mouse, 1);
        feed(&mut s, b"\x1b[?1000l\x1b[?25h\x1b[4l");
        assert_eq!(s.modes().mouse, 0);
        assert!(s.modes().cursor_visible && !s.modes().insert);
    }

    #[test]
    fn autowrap_off_overwrites_last_column() {
        let mut s = screen(3, 2);
        feed(&mut s, b"\x1b[?7labcdXY");
        assert_eq!(s.row_text(0), "abY");
        assert_eq!(s.cursor().row, 0);
    }

    #[test]
    fn insert_mode_shifts_right() {
        let mut s = screen(10, 1);
        feed(&mut s, b"abc\x1b[1G\x1b[4hX");
        assert_eq!(s.row_text(0), "Xabc");
    }

    #[test]
    fn alt_screen_1049_saves_and_restores() {
        let mut s = screen(10, 2);
        feed(&mut s, b"hello\x1b[?1049h");
        assert!(s.modes().alt_screen);
        assert_eq!(s.row_text(0), "");
        feed(&mut s, b"world");
        assert_eq!(s.row_text(0), "     world");
        feed(&mut s, b"\x1b[?1049l");
        assert!(!s.modes().alt_screen);
        assert_eq!(s.row_text(0), "hello");
        assert_eq!(s.cursor().col, 5);
    }

    #[test]
    fn alt_screen_47_keeps_cursor_where_it_is() {
        let mut s = screen(10, 2);
        feed(&mut s, b"ab\x1b[?47h");
        assert_eq!(s.cursor().col, 2);
        feed(&mut s, b"\x1b[?47l");
        assert_eq!(s.cursor().col, 2);
        assert_eq!(s.row_text(0), "ab");
    }

    #[test]
    fn alt_screen_has_no_scrollback() {
        let mut s = screen(10, 2);
        feed(&mut s, b"\x1b[?1049h\n\n\n\n");
        assert_eq!(s.grid().scrollback_len(), 0);
    }

    #[test]
    fn save_and_restore_cursor_with_attributes() {
        let mut s = screen(10, 5);
        feed(&mut s, b"\x1b[1m\x1b[3;3H\x1b7\x1b[m\x1b[H\x1b8X");
        let c = s.grid().cell(2, 2);
        assert_eq!(c.codepoint(), 'X');
        assert_eq!(c.flags(), flags::BOLD);
        feed(&mut s, b"\x1b[2;2H\x1b[s\x1b[H\x1b[uY");
        assert_eq!(s.grid().cell(1, 1).codepoint(), 'Y');
    }

    #[test]
    fn restore_without_save_goes_home() {
        let mut s = screen(10, 5);
        feed(&mut s, b"\x1b[3;3H\x1b8");
        assert_eq!((s.cursor().col, s.cursor().row), (0, 0));
    }

    #[test]
    fn reverse_index_scrolls_down_at_top() {
        let mut s = screen(5, 3);
        feed(&mut s, b"a\r\nb\x1bM\x1bM");
        let rows: Vec<String> = (0..3).map(|r| s.row_text(r)).collect();
        assert_eq!(rows, ["", "a", "b"]);
        assert_eq!(s.cursor().row, 0);
    }

    #[test]
    fn nel_and_ind() {
        let mut s = screen(5, 3);
        feed(&mut s, b"ab\x1bEc\x1bD");
        assert_eq!(s.row_text(1), "c");
        assert_eq!((s.cursor().col, s.cursor().row), (1, 2));
    }

    #[test]
    fn hts_sets_a_tab_stop() {
        let mut s = screen(20, 1);
        feed(&mut s, b"\x1b[3G\x1bH\x1b[G\tx");
        assert_eq!(s.row_text(0), "  x");
    }

    #[test]
    fn ris_resets_everything() {
        let mut s = screen(10, 5);
        feed(&mut s, b"xy\x1b[1m\x1b[?1049h\x1b[5;5Hab\x1bc");
        assert!(!s.modes().alt_screen);
        assert_eq!((s.cursor().col, s.cursor().row), (0, 0));
        assert_eq!(s.template().flags(), 0);
        assert_eq!(s.row_text(0), "");
        assert_eq!(s.grid().scrollback_capacity(), 10);
    }

    #[test]
    fn osc_sets_title() {
        let mut s = screen(10, 1);
        feed(&mut s, b"\x1b]0;My title\x07");
        assert_eq!(s.title(), "My title");
        feed(&mut s, b"\x1b]2;Other\x1b\\");
        assert_eq!(s.title(), "Other");
        feed(&mut s, b"\x1b]52;c;aGVsbG8=\x07");
        assert_eq!(s.title(), "Other");
    }

    #[test]
    fn decaln_fills_with_e() {
        let mut s = screen(3, 2);
        feed(&mut s, b"\x1b#8");
        assert_eq!(s.row_text(0), "EEE");
        assert_eq!(s.row_text(1), "EEE");
    }

    #[test]
    fn keypad_modes() {
        let mut s = screen(3, 2);
        feed(&mut s, b"\x1b=");
        assert!(s.modes().app_keypad);
        feed(&mut s, b"\x1b>");
        assert!(!s.modes().app_keypad);
    }

    #[test]
    fn origin_mode_confines_cursor_and_reports_relative() {
        let mut s = screen(10, 5);
        feed(&mut s, b"\x1b[2;4r\x1b[?6h\x1b[H");
        assert_eq!(s.cursor().row, 1);
        feed(&mut s, b"\x1b[99;1H");
        assert_eq!(s.cursor().row, 3);
        feed(&mut s, b"\x1b[6n");
        let mut out = [0u8; 16];
        let n = s.take_responses(&mut out);
        assert_eq!(&out[..n], b"\x1b[3;1R");
    }

    #[test]
    fn dcs_is_ignored() {
        let mut s = screen(10, 1);
        feed(&mut s, b"\x1bPq#0;2;0;0;0\x1b\\X");
        assert_eq!(s.row_text(0), "X");
    }

    #[test]
    fn charset_designation_is_ignored() {
        let mut s = screen(10, 1);
        feed(&mut s, b"\x1b(B\x1b)0X");
        assert_eq!(s.row_text(0), "X");
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p termcore screen`
Expected: compile error, no method `title`.

- [ ] **Step 3: Write the implementation**

In `core/src/screen.rs`:

Add after the `Cursor` struct:

```rust
#[derive(Clone, Copy, Debug)]
struct SavedCursor {
    col: usize,
    row: usize,
    template: Cell,
    origin: bool,
}
```

Add fields to `Screen` (after `colors`) and initialise in `new`:

```rust
    saved_primary: Option<SavedCursor>,
    saved_alt: Option<SavedCursor>,
    title: String,
```

```rust
            saved_primary: None,
            saved_alt: None,
            title: String::new(),
```

Add to `impl Screen`:

```rust
    pub fn title(&self) -> &str {
        &self.title
    }

    fn set_modes(&mut self, params: &Params, intermediates: &[u8], enable: bool) {
        let private = intermediates == b"?";
        for p in params.iter() {
            let mode = p[0];
            if private {
                self.set_private_mode(mode, enable);
            } else if mode == 4 {
                self.modes.insert = enable;
            }
        }
    }

    fn set_private_mode(&mut self, mode: u16, enable: bool) {
        match mode {
            1 => self.modes.app_cursor = enable,
            6 => {
                self.modes.origin = enable;
                self.move_cursor_to(0, 0);
            }
            7 => self.modes.autowrap = enable,
            9 => self.modes.mouse = if enable { 1 } else { 0 },
            12 => self.modes.cursor_blink = enable,
            25 => self.modes.cursor_visible = enable,
            47 | 1047 => self.switch_alt(enable, false),
            1000 => self.modes.mouse = if enable { 2 } else { 0 },
            1002 => self.modes.mouse = if enable { 3 } else { 0 },
            1003 => self.modes.mouse = if enable { 4 } else { 0 },
            1004 => self.modes.focus_events = enable,
            1006 => self.modes.mouse_sgr = enable,
            1049 => self.switch_alt(enable, true),
            2004 => self.modes.bracketed_paste = enable,
            _ => {}
        }
    }

    /// Switches between primary and alternate screen. The alternate
    /// screen is cleared on entry. With `with_cursor` (mode 1049) the
    /// cursor and attributes are saved on entry and restored on exit.
    fn switch_alt(&mut self, to_alt: bool, with_cursor: bool) {
        if to_alt == self.modes.alt_screen {
            return;
        }
        if to_alt {
            if with_cursor {
                self.save_cursor();
            }
            self.modes.alt_screen = true;
            let blank = self.blank();
            for r in 0..self.rows() {
                self.alt.row_mut(r).clear(blank);
            }
        } else {
            self.modes.alt_screen = false;
            if with_cursor {
                self.restore_cursor();
            }
            self.primary.mark_all_dirty();
        }
        self.cursor.pending_wrap = false;
    }

    fn save_cursor(&mut self) {
        let saved = SavedCursor {
            col: self.cursor.col,
            row: self.cursor.row,
            template: self.template,
            origin: self.modes.origin,
        };
        if self.modes.alt_screen {
            self.saved_alt = Some(saved);
        } else {
            self.saved_primary = Some(saved);
        }
    }

    fn restore_cursor(&mut self) {
        let saved = if self.modes.alt_screen { self.saved_alt } else { self.saved_primary };
        match saved {
            Some(s) => {
                self.template = s.template;
                self.modes.origin = s.origin;
                self.cursor.row = s.row.min(self.rows() - 1);
                self.cursor.col = s.col.min(self.cols() - 1);
                self.cursor.pending_wrap = false;
            }
            None => {
                self.template = Cell::default();
                self.modes.origin = false;
                self.move_cursor_to(0, 0);
            }
        }
    }

    fn reverse_index(&mut self) {
        self.cursor.pending_wrap = false;
        if self.cursor.row == self.scroll_top {
            let (top, bottom, blank) = (self.scroll_top, self.scroll_bottom, self.blank());
            self.grid_mut().scroll_down_region(top, bottom, 1, blank);
        } else if self.cursor.row > 0 {
            self.cursor.row -= 1;
        }
    }

    /// RIS: back to a freshly created screen of the same size.
    fn reset(&mut self) {
        let (cols, rows, scrollback) = (self.cols(), self.rows(), self.primary.scrollback_capacity());
        *self = Screen::new(cols, rows, scrollback);
    }

    /// DECALN: fill the screen with E, reset margins, home the cursor.
    fn screen_alignment(&mut self) {
        let cell = Cell::default().with_codepoint('E');
        for r in 0..self.rows() {
            self.grid_mut().row_mut(r).clear(cell);
        }
        self.scroll_top = 0;
        self.scroll_bottom = self.rows() - 1;
        self.move_cursor_to(0, 0);
    }
```

Add these arms to `csi_dispatch`, before the `_ => {}` arm:

```rust
            (b"", 'h') | (b"?", 'h') => self.set_modes(params, intermediates, true),
            (b"", 'l') | (b"?", 'l') => self.set_modes(params, intermediates, false),
            (b"", 's') => self.save_cursor(),
            (b"", 'u') => self.restore_cursor(),
```

Add to `impl Perform for Screen`, after `csi_dispatch`:

```rust
    fn esc_dispatch(&mut self, intermediates: &[u8], _ignore: bool, byte: u8) {
        match (intermediates, byte) {
            (b"", b'7') => self.save_cursor(),
            (b"", b'8') => self.restore_cursor(),
            (b"", b'D') => self.linefeed(),
            (b"", b'E') => {
                self.carriage_return();
                self.linefeed();
            }
            (b"", b'H') => {
                let c = self.cursor.col;
                self.tabs[c] = true;
            }
            (b"", b'M') => self.reverse_index(),
            (b"", b'c') => self.reset(),
            (b"", b'=') => self.modes.app_keypad = true,
            (b"", b'>') => self.modes.app_keypad = false,
            (b"#", b'8') => self.screen_alignment(),
            _ => {}
        }
    }

    fn osc_dispatch(&mut self, params: &[&[u8]], _bell_terminated: bool) {
        if let [kind, text, ..] = params {
            let kind: &[u8] = kind;
            if kind == b"0" || kind == b"2" {
                self.title = String::from_utf8_lossy(text).into_owned();
            }
        }
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `cargo test -p termcore screen`
Expected: 56 passed.

- [ ] **Step 5: Commit**

```bash
git add core/src/screen.rs
git commit -m "feat(core): add modes, alternate screen, cursor save and restore, ESC and OSC"
```

---

### Task 10: Basic emoji sequences

**Files:**
- Modify: `core/src/screen.rs`

**Interfaces:**
- Changes `print` on the `Perform` impl. New fields `pending_zwj: bool` and `just_printed: bool` (set by `put_char`, cleared by `execute`, `csi_dispatch`, `esc_dispatch` and `resize`). Private `emoji_presentation()`, which acts only when `just_printed` is set.
- Rule: a zero width joiner drops the next printable character (so a ZWJ family collapses to its first emoji). Skin tone modifiers and variation selector 15 are dropped. Variation selector 16 upgrades the previous narrow cell to wide when there is room. Combining marks and other zero width characters are dropped.

- [ ] **Step 1: Write the failing tests**

Append inside `mod tests` in `core/src/screen.rs`:

```rust
    #[test]
    fn skin_tone_modifier_collapses_into_base() {
        let mut s = screen(10, 1);
        feed(&mut s, "👍🏽x".as_bytes());
        let base = s.grid().cell(0, 0);
        assert_eq!(base.codepoint(), '👍');
        assert!(base.has(flags::WIDE));
        assert!(s.grid().cell(1, 0).has(flags::WIDE_SPACER));
        assert_eq!(s.grid().cell(2, 0).codepoint(), 'x');
    }

    #[test]
    fn zwj_sequence_keeps_first_emoji() {
        let mut s = screen(10, 1);
        feed(&mut s, "👨\u{200D}👩\u{200D}👧x".as_bytes());
        assert_eq!(s.grid().cell(0, 0).codepoint(), '👨');
        assert!(s.grid().cell(0, 0).has(flags::WIDE));
        assert_eq!(s.grid().cell(2, 0).codepoint(), 'x');
        assert_eq!(s.cursor().col, 3);
    }

    #[test]
    fn vs16_upgrades_narrow_char_to_wide() {
        let mut s = screen(10, 1);
        feed(&mut s, "\u{2764}\u{FE0F}x".as_bytes());
        let heart = s.grid().cell(0, 0);
        assert_eq!(heart.codepoint(), '\u{2764}');
        assert!(heart.has(flags::WIDE));
        assert!(s.grid().cell(1, 0).has(flags::WIDE_SPACER));
        assert_eq!(s.grid().cell(2, 0).codepoint(), 'x');
        assert_eq!(s.cursor().col, 3);
    }

    #[test]
    fn vs16_in_last_column_stays_narrow() {
        let mut s = screen(2, 1);
        feed(&mut s, "a\u{2764}\u{FE0F}".as_bytes());
        let heart = s.grid().cell(1, 0);
        assert_eq!(heart.codepoint(), '\u{2764}');
        assert!(!heart.has(flags::WIDE));
        assert!(s.cursor().pending_wrap);
    }

    #[test]
    fn combining_marks_are_dropped() {
        let mut s = screen(10, 1);
        feed(&mut s, "e\u{0301}x".as_bytes());
        assert_eq!(s.row_text(0), "ex");
    }

    #[test]
    fn vs15_is_ignored() {
        let mut s = screen(10, 1);
        feed(&mut s, "\u{2603}\u{FE0E}x".as_bytes());
        assert_eq!(s.row_text(0), "\u{2603}x");
        assert!(!s.grid().cell(0, 0).has(flags::WIDE));
    }

    #[test]
    fn vs16_after_a_control_character_is_a_noop() {
        let mut s = screen(10, 1);
        feed(&mut s, "\t\u{FE0F}x".as_bytes());
        assert_eq!(s.row_text(0), "        x");
        assert_eq!(s.cursor().col, 9);
        assert!(!s.grid().cell(7, 0).has(flags::WIDE));
        let mut s = screen(10, 1);
        feed(&mut s, "a\x1b[3G\u{FE0F}x".as_bytes());
        assert_eq!(s.row_text(0), "a x");
        assert!(!s.grid().cell(1, 0).has(flags::WIDE));
    }

    #[test]
    fn zwj_state_does_not_leak_across_control_chars() {
        let mut s = screen(10, 1);
        feed(&mut s, "a\u{200D}\rb".as_bytes());
        assert_eq!(s.row_text(0), "b");
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p termcore screen`
Expected: `skin_tone_modifier_collapses_into_base`, `zwj_sequence_keeps_first_emoji`, `vs16_upgrades_narrow_char_to_wide` and `zwj_state_does_not_leak_across_control_chars` fail.

- [ ] **Step 3: Write the implementation**

Add two fields to `Screen` (after `title`) and initialise them in `new`:

```rust
    pending_zwj: bool,
    /// True when the cell before the cursor was written by the last print.
    just_printed: bool,
```

```rust
            pending_zwj: false,
            just_printed: false,
```

In `put_char`, after `self.last_char = Some(c);`, add `self.just_printed = true;`. Add `self.just_printed = false;` as the first line of `csi_dispatch` and of `esc_dispatch`, and in `resize` after `self.cursor.pending_wrap = false;`.

Add to `impl Screen`:

```rust
    /// VS16 after a narrow glyph: make it wide if the next column is free.
    fn emoji_presentation(&mut self) {
        let cols = self.cols();
        let row = self.cursor.row;
        if !self.just_printed || self.cursor.pending_wrap || self.cursor.col == 0 {
            return;
        }
        let col = self.cursor.col - 1;
        let prev = self.grid().cell(col, row);
        if prev.has(flags::WIDE) || prev.has(flags::WIDE_SPACER) || col + 1 >= cols {
            return;
        }
        let wide = prev.with_flags(prev.flags() | flags::WIDE);
        let spacer = prev.with_codepoint(' ').with_flags(prev.flags() | flags::WIDE_SPACER);
        self.split_wide(col + 1, row);
        self.grid_mut().set_cell(col, row, wide);
        self.grid_mut().set_cell(col + 1, row, spacer);
        if col + 2 >= cols {
            self.cursor.col = cols - 1;
            self.cursor.pending_wrap = true;
        } else {
            self.cursor.col = col + 2;
        }
    }
```

Replace `print` in `impl Perform for Screen` with:

```rust
    fn print(&mut self, c: char) {
        match c {
            '\u{200D}' => {
                self.pending_zwj = true;
                return;
            }
            '\u{FE0F}' => {
                self.emoji_presentation();
                return;
            }
            '\u{FE0E}' | '\u{1F3FB}'..='\u{1F3FF}' => return,
            _ => {}
        }
        if self.pending_zwj {
            self.pending_zwj = false;
            return;
        }
        let width = match c.width() {
            Some(w) if w > 0 => w.min(2),
            _ => return,
        };
        self.put_char(c, width);
    }
```

Add as the first lines of `execute`:

```rust
        self.pending_zwj = false;
        self.just_printed = false;
```

- [ ] **Step 4: Run to verify pass**

Run: `cargo test -p termcore screen`
Expected: 64 passed.

- [ ] **Step 5: Commit**

```bash
git add core/src/screen.rs
git commit -m "feat(core): collapse basic emoji sequences into one cell"
```

---

### Task 11: Selection

**Files:**
- Create: `core/src/selection.rs`
- Modify: `core/src/lib.rs`

**Interfaces:**
- Consumes: `Grid::line(id)`, `Grid::cols()`, `Row::wrapped`, `flags::WIDE_SPACER`.
- Produces: `SelectionMode { Normal, Word, Line }` with `from_u8(u8)`, `Point { line: u64, col: usize }` (ordered by line then col), `Selection::new(Point, SelectionMode)`, `extend(Point)`, `bounds(&Grid) -> (Point, Point)` (inclusive, ordered, mode expansion applied), `contains(&Grid, Point) -> bool`, `text(&Grid) -> String`.

- [ ] **Step 1: Write the failing tests**

Add `pub mod selection;` to `core/src/lib.rs` and create `core/src/selection.rs` with only this block:

```rust
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
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p termcore selection`
Expected: compile error, `Selection` not found.

- [ ] **Step 3: Write the implementation**

Replace `core/src/selection.rs` with the full file (tests block at the bottom):

```rust
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
```

- [ ] **Step 4: Run to verify pass**

Run: `cargo test -p termcore selection`
Expected: 10 passed.

- [ ] **Step 5: Commit**

```bash
git add core/src/selection.rs core/src/lib.rs
git commit -m "feat(core): add selection with word and line modes"
```

---

### Task 12: Term wrapper and chaos test

**Files:**
- Create: `core/src/term.rs`
- Create: `core/tests/chaos.rs`
- Modify: `core/src/lib.rs`

**Interfaces:**
- Consumes: `Screen`, `Selection`, `Point`, `SelectionMode`, `Cell`, `vte::Parser`.
- Produces: `Term::new(cols, rows, scrollback)`, `feed(&[u8])`, `screen()`, `screen_mut()`, `resize(cols, rows)`, `scroll_viewport(i32)`, `selection() -> Option<Selection>`, `selection_start(col, row, SelectionMode) -> bool`, `selection_extend(col, row) -> bool`, `selection_clear()`, `selection_text() -> String`, `copy_visible(&mut [Cell]) -> bool`, `dump() -> String`. Selection coordinates are **visible** rows (viewport applied), which is what a mouse click gives the shell.

- [ ] **Step 1: Write the failing tests**

Add `pub mod term;` to `core/src/lib.rs` and create `core/src/term.rs` with only this block:

```rust
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
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p termcore term`
Expected: compile error, `Term` not found.

- [ ] **Step 3: Write the implementation**

Replace `core/src/term.rs` with the full file (tests block at the bottom):

```rust
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
```

- [ ] **Step 4: Run to verify pass**

Run: `cargo test -p termcore term`
Expected: 8 passed.

- [ ] **Step 5: Write the chaos test**

Create `core/tests/chaos.rs`:

```rust
//! Feeds deterministic pseudo random bytes, biased towards escape
//! sequence syntax, through the core. Any panic is a bug in the core.

use termcore::cell::Cell;
use termcore::selection::SelectionMode;
use termcore::term::Term;

struct XorShift(u64);

impl XorShift {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
}

const INTERESTING: &[u8] =
    b"\x1b[]?;:0123456789ABCDEFGHIJKLMPSTXZabcdefghlmnqrsu@` \x07\x08\x09\x0a\x0d\x9b\\P()#78=>\xc3\xa9\xe6\x97\xa5\xf0\x9f\x91\x8d\xe2\x80\x8d\xef\xb8\x8f";

fn fill(rng: &mut XorShift, buf: &mut [u8]) {
    for b in buf {
        let r = rng.next();
        *b = if r % 3 == 0 {
            (r >> 8) as u8
        } else {
            INTERESTING[((r >> 8) as usize) % INTERESTING.len()]
        };
    }
}

#[test]
fn random_bytes_never_panic() {
    let mut rng = XorShift(0x9E37_79B9_7F4A_7C15);
    let mut term = Term::new(80, 24, 100);
    let mut buf = vec![0u8; 4096];
    let mut responses = vec![0u8; 256];
    for round in 0..768 {
        let len = (rng.next() % 4096) as usize;
        fill(&mut rng, &mut buf[..len]);
        term.feed(&buf[..len]);
        if round % 64 == 0 {
            let cols = 1 + (rng.next() % 200) as usize;
            let rows = 1 + (rng.next() % 100) as usize;
            term.resize(cols, rows);
        }
        // Drive a selection through the same chaos: coordinates are
        // sometimes out of range on purpose, which must be rejected.
        let cols = term.screen().cols();
        let rows = term.screen().rows();
        let col = (rng.next() % (cols as u64 + 2)) as usize;
        let row = (rng.next() % (rows as u64 + 2)) as usize;
        match round % 4 {
            0 => {
                term.selection_start(col, row, SelectionMode::from_u8((rng.next() % 3) as u8));
            }
            1 | 2 => {
                term.selection_extend(col, row);
            }
            _ => term.selection_clear(),
        }
        term.scroll_viewport((rng.next() % 7) as i32 - 3);
        let mut cells = vec![Cell::default(); cols * rows];
        assert!(term.copy_visible(&mut cells), "copy_visible rejected a correctly sized buffer");
        let _ = term.selection_text();
        let screen = term.screen();
        let cursor = screen.cursor();
        assert!(
            cursor.col < screen.cols() && cursor.row < screen.rows(),
            "cursor out of bounds after round {round}"
        );
        let _ = term.dump();
        term.screen_mut().take_responses(&mut responses);
    }
}

#[test]
fn tiny_grids_survive_everything() {
    let mut rng = XorShift(42);
    let mut buf = vec![0u8; 512];
    for (cols, rows) in [(1, 1), (1, 5), (5, 1), (2, 2)] {
        let mut term = Term::new(cols, rows, 3);
        for _ in 0..64 {
            fill(&mut rng, &mut buf);
            term.feed(&buf);
            let _ = term.dump();
        }
    }
}
```

- [ ] **Step 6: Run the chaos test**

Run: `cargo test -p termcore --test chaos`
Expected: 2 passed. If either panics, the panic message names the line in `screen.rs` or `grid.rs`. Fix the bounds bug there, add a minimal regression test to the matching `mod tests` block that reproduces the exact byte sequence, and rerun until green. Do not weaken the chaos test.

- [ ] **Step 7: Commit**

```bash
git add core/src/term.rs core/src/lib.rs core/tests/chaos.rs
git commit -m "feat(core): add Term wrapper, visible copy with selection, chaos test"
```

---

### Task 13: C ABI and header

**Files:**
- Create: `core/src/ffi.rs`
- Create: `core/include/termcore.h`
- Create: `core/tests/ffi.rs`
- Modify: `core/src/lib.rs`

**Interfaces:**
- Consumes: `Term`, `Cell`, `Rgb`, `Modes`, `SelectionMode`.
- Produces: the `extern "C"` functions listed in the header below, `TermCursor` (`#[repr(C)]`), status constants `TERM_OK = 0`, `TERM_ERR_NULL = 1`, `TERM_ERR_SMALL = 2`, `TERM_ERR_ARG = 3`.
- Contract for text getters (`term_selection_text`, `term_title`): return the full length in bytes; write `min(len, full)` bytes when `out` is non null. Call with a null `out` to size a buffer.

- [ ] **Step 1: Write the failing tests**

Add `pub mod ffi;` to `core/src/lib.rs`. Create `core/tests/ffi.rs`:

```rust
use std::ptr;

use termcore::color::Rgb;
use termcore::ffi::*;
use termcore::screen::Modes;

#[test]
fn full_round_trip_through_the_c_abi() {
    unsafe {
        let t = term_new(10, 3, 5);
        assert!(!t.is_null());
        let input = b"hi\x1b[1;31mX\x1b[6n";
        assert_eq!(term_feed(t, input.as_ptr(), input.len()), TERM_OK);

        let mut cells = vec![0u64; 30];
        assert_eq!(term_grid(t, cells.as_mut_ptr(), 29), TERM_ERR_SMALL);
        assert_eq!(term_grid(t, cells.as_mut_ptr(), 30), TERM_OK);
        assert_eq!(cells[0] & 0x1F_FFFF, 'h' as u64);
        assert_eq!((cells[2] >> 21) & 0xFF, 1);
        assert_eq!((cells[2] >> 29) & 0xFFFF, 1);

        let mut cursor = TermCursor::default();
        assert_eq!(term_cursor(t, &mut cursor), TERM_OK);
        assert_eq!((cursor.col, cursor.row, cursor.visible), (3, 0, 1));

        let mut resp = [0u8; 16];
        let n = term_responses(t, resp.as_mut_ptr(), resp.len());
        assert_eq!(&resp[..n], b"\x1b[1;4R");

        let mut dirty = [0u64; 1];
        assert_eq!(term_dirty_rows(t, dirty.as_mut_ptr(), 1), TERM_OK);
        assert_eq!(dirty[0] & 0b111, 0b111);
        assert_eq!(term_dirty_rows(t, dirty.as_mut_ptr(), 1), TERM_OK);
        assert_eq!(dirty[0], 0);
        assert_eq!(term_dirty_rows(t, dirty.as_mut_ptr(), 0), TERM_ERR_SMALL);

        let seq = b"\x1b[?2004h";
        term_feed(t, seq.as_ptr(), seq.len());
        let mut modes = Modes::default();
        assert_eq!(term_modes(t, &mut modes), TERM_OK);
        assert!(modes.bracketed_paste);

        assert_eq!(term_selection_start(t, 0, 0, 0), TERM_OK);
        assert_eq!(term_selection_extend(t, 2, 0), TERM_OK);
        assert_eq!(term_selection_start(t, 50, 0, 0), TERM_ERR_ARG);
        let needed = term_selection_text(t, ptr::null_mut(), 0);
        assert_eq!(needed, 3);
        let mut text = vec![0u8; needed];
        assert_eq!(term_selection_text(t, text.as_mut_ptr(), needed), 3);
        assert_eq!(&text, b"hiX");
        assert_eq!(term_grid(t, cells.as_mut_ptr(), 30), TERM_OK);
        assert_eq!((cells[0] >> 61) & 1, 1);
        assert_eq!((cells[3] >> 61) & 1, 0);
        assert_eq!(term_selection_clear(t), TERM_OK);
        assert_eq!(term_selection_text(t, ptr::null_mut(), 0), 0);

        let seq = b"\x1b[38;2;1;2;3m";
        term_feed(t, seq.as_ptr(), seq.len());
        let mut rgb = [Rgb::default(); 4];
        assert_eq!(term_colors(t, rgb.as_mut_ptr(), 4), 1);
        assert_eq!(rgb[0], Rgb { r: 1, g: 2, b: 3 });

        let seq = b"\x1b]0;Title\x07";
        term_feed(t, seq.as_ptr(), seq.len());
        let mut title = [0u8; 3];
        assert_eq!(term_title(t, title.as_mut_ptr(), 3), 5);
        assert_eq!(&title, b"Tit");

        assert_eq!(term_resize(t, 0, 5), TERM_ERR_ARG);
        assert_eq!(term_resize(t, 4, 2), TERM_OK);
        assert_eq!(term_scroll_viewport(t, 5), TERM_OK);
        term_free(t);
    }
}

#[test]
fn null_pointers_are_rejected() {
    unsafe {
        assert!(term_new(0, 1, 0).is_null());
        assert_eq!(term_feed(ptr::null_mut(), b"x".as_ptr(), 1), TERM_ERR_NULL);
        let t = term_new(2, 2, 0);
        assert_eq!(term_feed(t, ptr::null(), 3), TERM_ERR_NULL);
        assert_eq!(term_feed(t, ptr::null(), 0), TERM_OK);
        assert_eq!(term_grid(t, ptr::null_mut(), 4), TERM_ERR_NULL);
        assert_eq!(term_cursor(t, ptr::null_mut()), TERM_ERR_NULL);
        assert_eq!(term_modes(t, ptr::null_mut()), TERM_ERR_NULL);
        assert_eq!(term_responses(t, ptr::null_mut(), 8), 0);
        assert_eq!(term_colors(t, ptr::null_mut(), 8), 0);
        term_free(t);
        term_free(ptr::null_mut());
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p termcore --test ffi`
Expected: compile error, unresolved import `termcore::ffi`.

- [ ] **Step 3: Write the implementation**

Create `core/src/ffi.rs`:

```rust
//! C ABI. Every pointer is null checked. Slices are only built from
//! pointer and length pairs the caller supplied together.
//!
//! # Safety
//! All functions taking `*mut Term` require a pointer from `term_new`
//! that has not been passed to `term_free`. Output pointers must point
//! to at least `len` writable elements.

use std::ptr;
use std::slice;

use crate::cell::Cell;
use crate::color::Rgb;
use crate::screen::Modes;
use crate::selection::SelectionMode;
use crate::term::Term;

pub const TERM_OK: i32 = 0;
pub const TERM_ERR_NULL: i32 = 1;
pub const TERM_ERR_SMALL: i32 = 2;
pub const TERM_ERR_ARG: i32 = 3;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TermCursor {
    pub col: u16,
    pub row: u16,
    /// 0 block, 1 underline, 2 bar.
    pub shape: u8,
    pub blink: u8,
    /// 0 when hidden by DECTCEM or while the viewport is scrolled back.
    pub visible: u8,
}

unsafe fn copy_prefix(src: &[u8], out: *mut u8, len: usize) {
    if out.is_null() || len == 0 {
        return;
    }
    let n = src.len().min(len);
    ptr::copy_nonoverlapping(src.as_ptr(), out, n);
}

#[no_mangle]
pub extern "C" fn term_new(cols: u16, rows: u16, scrollback: u32) -> *mut Term {
    if cols == 0 || rows == 0 {
        return ptr::null_mut();
    }
    Box::into_raw(Box::new(Term::new(cols as usize, rows as usize, scrollback as usize)))
}

/// # Safety
/// `term` is null or came from `term_new` and is not used afterwards.
#[no_mangle]
pub unsafe extern "C" fn term_free(term: *mut Term) {
    if !term.is_null() {
        drop(Box::from_raw(term));
    }
}

/// # Safety
/// `bytes` points to `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn term_feed(term: *mut Term, bytes: *const u8, len: usize) -> i32 {
    let Some(term) = term.as_mut() else { return TERM_ERR_NULL };
    if len == 0 {
        return TERM_OK;
    }
    if bytes.is_null() {
        return TERM_ERR_NULL;
    }
    term.feed(slice::from_raw_parts(bytes, len));
    TERM_OK
}

/// # Safety
/// See module docs.
#[no_mangle]
pub unsafe extern "C" fn term_resize(term: *mut Term, cols: u16, rows: u16) -> i32 {
    let Some(term) = term.as_mut() else { return TERM_ERR_NULL };
    if cols == 0 || rows == 0 {
        return TERM_ERR_ARG;
    }
    term.resize(cols as usize, rows as usize);
    TERM_OK
}

/// Copies the visible grid, `cols * rows` packed cells, row major.
///
/// # Safety
/// `out` points to `len` writable `u64`.
#[no_mangle]
pub unsafe extern "C" fn term_grid(term: *mut Term, out: *mut u64, len: usize) -> i32 {
    let Some(term) = term.as_ref() else { return TERM_ERR_NULL };
    if out.is_null() {
        return TERM_ERR_NULL;
    }
    let need = term.screen().cols() * term.screen().rows();
    if len < need {
        return TERM_ERR_SMALL;
    }
    let cells = slice::from_raw_parts_mut(out as *mut Cell, need);
    term.copy_visible(cells);
    TERM_OK
}

/// Copies and clears the dirty row bitmap, one bit per visible row.
/// Needs `ceil(rows / 64)` words.
///
/// # Safety
/// `out` points to `len` writable `u64`.
#[no_mangle]
pub unsafe extern "C" fn term_dirty_rows(term: *mut Term, out: *mut u64, len: usize) -> i32 {
    let Some(term) = term.as_mut() else { return TERM_ERR_NULL };
    if out.is_null() {
        return TERM_ERR_NULL;
    }
    if len < term.screen().grid().dirty_words() {
        return TERM_ERR_SMALL;
    }
    let words = slice::from_raw_parts_mut(out, len);
    term.screen_mut().grid_mut().take_dirty(words);
    TERM_OK
}

/// # Safety
/// `out` points to a writable `TermCursor`.
#[no_mangle]
pub unsafe extern "C" fn term_cursor(term: *mut Term, out: *mut TermCursor) -> i32 {
    let Some(term) = term.as_ref() else { return TERM_ERR_NULL };
    let Some(out) = out.as_mut() else { return TERM_ERR_NULL };
    let screen = term.screen();
    let cursor = screen.cursor();
    let modes = screen.modes();
    let visible = modes.cursor_visible && screen.grid().viewport() == 0;
    *out = TermCursor {
        col: cursor.col as u16,
        row: cursor.row as u16,
        shape: modes.cursor_shape,
        blink: modes.cursor_blink as u8,
        visible: visible as u8,
    };
    TERM_OK
}

/// # Safety
/// `out` points to a writable `Modes` (`TermModes` in C).
#[no_mangle]
pub unsafe extern "C" fn term_modes(term: *mut Term, out: *mut Modes) -> i32 {
    let Some(term) = term.as_ref() else { return TERM_ERR_NULL };
    let Some(out) = out.as_mut() else { return TERM_ERR_NULL };
    *out = term.screen().modes();
    TERM_OK
}

/// Positive `delta` scrolls towards older content. Clamped.
///
/// # Safety
/// See module docs.
#[no_mangle]
pub unsafe extern "C" fn term_scroll_viewport(term: *mut Term, delta: i32) -> i32 {
    let Some(term) = term.as_mut() else { return TERM_ERR_NULL };
    term.scroll_viewport(delta);
    TERM_OK
}

/// `mode`: 0 normal, 1 word, 2 line. Coordinates are visible cells.
///
/// # Safety
/// See module docs.
#[no_mangle]
pub unsafe extern "C" fn term_selection_start(term: *mut Term, col: u16, row: u16, mode: u8) -> i32 {
    let Some(term) = term.as_mut() else { return TERM_ERR_NULL };
    if term.selection_start(col as usize, row as usize, SelectionMode::from_u8(mode)) {
        TERM_OK
    } else {
        TERM_ERR_ARG
    }
}

/// # Safety
/// See module docs.
#[no_mangle]
pub unsafe extern "C" fn term_selection_extend(term: *mut Term, col: u16, row: u16) -> i32 {
    let Some(term) = term.as_mut() else { return TERM_ERR_NULL };
    if term.selection_extend(col as usize, row as usize) {
        TERM_OK
    } else {
        TERM_ERR_ARG
    }
}

/// # Safety
/// See module docs.
#[no_mangle]
pub unsafe extern "C" fn term_selection_clear(term: *mut Term) -> i32 {
    let Some(term) = term.as_mut() else { return TERM_ERR_NULL };
    term.selection_clear();
    TERM_OK
}

/// Returns the UTF-8 length of the selected text and writes up to `len`
/// bytes of it to `out` (no terminator). Null `out` only sizes.
///
/// # Safety
/// `out` is null or points to `len` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn term_selection_text(term: *mut Term, out: *mut u8, len: usize) -> usize {
    let Some(term) = term.as_ref() else { return 0 };
    let text = term.selection_text();
    copy_prefix(text.as_bytes(), out, len);
    text.len()
}

/// Drains up to `len` bytes the terminal wants written to the shell.
/// Returns the number written.
///
/// # Safety
/// `out` is null or points to `len` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn term_responses(term: *mut Term, out: *mut u8, len: usize) -> usize {
    let Some(term) = term.as_mut() else { return 0 };
    if out.is_null() || len == 0 {
        return 0;
    }
    term.screen_mut().take_responses(slice::from_raw_parts_mut(out, len))
}

/// Copies the 24-bit overflow colours (cell index 256 upward) and
/// returns how many exist. Writes at most `len`.
///
/// # Safety
/// `out` is null or points to `len` writable `TermRgb`.
#[no_mangle]
pub unsafe extern "C" fn term_colors(term: *mut Term, out: *mut Rgb, len: usize) -> usize {
    let Some(term) = term.as_ref() else { return 0 };
    let entries = term.screen().colors().entries();
    if !out.is_null() && len > 0 {
        let n = entries.len().min(len);
        ptr::copy_nonoverlapping(entries.as_ptr(), out, n);
    }
    entries.len()
}

/// Same contract as `term_selection_text`, for the OSC 0/2 title.
///
/// # Safety
/// `out` is null or points to `len` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn term_title(term: *mut Term, out: *mut u8, len: usize) -> usize {
    let Some(term) = term.as_ref() else { return 0 };
    let title = term.screen().title();
    copy_prefix(title.as_bytes(), out, len);
    title.len()
}
```

Create `core/include/termcore.h`:

```c
/* termcore C ABI. Keep in sync with core/src/ffi.rs. */
#ifndef TERMCORE_H
#define TERMCORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Term Term;

enum {
    TERM_OK = 0,
    TERM_ERR_NULL = 1,
    TERM_ERR_SMALL = 2,
    TERM_ERR_ARG = 3
};

/* Packed cell: bits 0..21 codepoint, 21..29 flags, 29..45 fg, 45..61 bg, 61 selected. */
enum {
    TERM_FLAG_BOLD = 1 << 0,
    TERM_FLAG_ITALIC = 1 << 1,
    TERM_FLAG_UNDERLINE = 1 << 2,
    TERM_FLAG_STRIKE = 1 << 3,
    TERM_FLAG_INVERSE = 1 << 4,
    TERM_FLAG_WIDE = 1 << 5,
    TERM_FLAG_WIDE_SPACER = 1 << 6,
    TERM_FLAG_DIM = 1 << 7
};

#define TERM_CELL_CODEPOINT(c) ((uint32_t)((c) & 0x1FFFFFu))
#define TERM_CELL_FLAGS(c) ((uint8_t)(((c) >> 21) & 0xFFu))
#define TERM_CELL_FG(c) ((uint16_t)(((c) >> 29) & 0xFFFFu))
#define TERM_CELL_BG(c) ((uint16_t)(((c) >> 45) & 0xFFFFu))
#define TERM_CELL_SELECTED(c) ((((c) >> 61) & 1u) != 0)

/* Colour index meaning "configured default". 0..256 palette, 256.. overflow. */
#define TERM_COLOR_DEFAULT 0xFFFFu

typedef struct {
    uint16_t col;
    uint16_t row;
    uint8_t shape;   /* 0 block, 1 underline, 2 bar */
    uint8_t blink;
    uint8_t visible; /* 0 when hidden or scrolled back */
} TermCursor;

typedef struct {
    bool bracketed_paste;
    uint8_t mouse;        /* 0 off, 1 X10, 2 normal, 3 button, 4 any */
    bool mouse_sgr;
    bool app_cursor;
    bool app_keypad;
    bool focus_events;
    bool alt_screen;
    bool origin;
    bool autowrap;
    bool insert;
    bool cursor_visible;
    bool cursor_blink;
    uint8_t cursor_shape; /* 0 block, 1 underline, 2 bar */
} TermModes;

typedef struct {
    uint8_t r, g, b;
} TermRgb;

Term *term_new(uint16_t cols, uint16_t rows, uint32_t scrollback);
void term_free(Term *term);
int32_t term_feed(Term *term, const uint8_t *bytes, size_t len);
int32_t term_resize(Term *term, uint16_t cols, uint16_t rows);
int32_t term_grid(Term *term, uint64_t *out, size_t len);
int32_t term_dirty_rows(Term *term, uint64_t *out, size_t len);
int32_t term_cursor(Term *term, TermCursor *out);
int32_t term_modes(Term *term, TermModes *out);
int32_t term_scroll_viewport(Term *term, int32_t delta);
int32_t term_selection_start(Term *term, uint16_t col, uint16_t row, uint8_t mode);
int32_t term_selection_extend(Term *term, uint16_t col, uint16_t row);
int32_t term_selection_clear(Term *term);
size_t term_selection_text(Term *term, uint8_t *out, size_t len);
size_t term_responses(Term *term, uint8_t *out, size_t len);
size_t term_colors(Term *term, TermRgb *out, size_t len);
size_t term_title(Term *term, uint8_t *out, size_t len);

#ifdef __cplusplus
}
#endif

#endif
```

- [ ] **Step 4: Run to verify pass**

Run: `cargo test -p termcore --test ffi`
Expected: 2 passed.

- [ ] **Step 5: Check the header compiles and the symbols exist**

Run:

```bash
cargo build -p termcore --release
echo '#include "core/include/termcore.h"
int main(void) { Term *t = term_new(80, 24, 100); term_free(t); return 0; }' > target/termcore_check.c
cc -I. -Wall -Wextra -Werror target/termcore_check.c target/release/libtermcore.a -o target/termcore_check && target/termcore_check && echo LINK_OK
nm target/release/libtermcore.dylib | grep -c ' T _term_'
```

Expected: `LINK_OK`, then `16`. The count is taken from the shared library because the Xcode command line `nm` cannot parse the static archive's object format from this Rust version; the static archive is what the C check links, so `LINK_OK` proves the same symbols are there.

- [ ] **Step 6: Commit**

```bash
git add core/src/ffi.rs core/src/lib.rs core/include/termcore.h core/tests/ffi.rs
git commit -m "feat(core): add C ABI and header"
```

---

### Task 14: Compatibility snapshot harness and fixtures

**Files:**
- Create: `core/tests/compat.rs`
- Create: `core/tests/compat/make_fixtures.sh`
- Create: `core/tests/compat/record.sh`
- Create: `core/tests/compat/*.in` (generated by the script) and `*.snap` (generated by the runner, then checked by hand)

**Interfaces:**
- Consumes: `Term::new(80, 24, 100)`, `Term::feed`, `Term::dump`.
- Produces: a test that fails when any fixture's dump differs from its snapshot. `UPDATE_SNAPSHOTS=1` rewrites snapshots.

- [ ] **Step 1: Write the runner**

Create `core/tests/compat.rs`:

```rust
//! Feeds every `tests/compat/*.in` through an 80x24 terminal and
//! compares `Term::dump()` with the matching `.snap`.
//!
//! Regenerate snapshots with `UPDATE_SNAPSHOTS=1 cargo test --test compat`,
//! then read every changed `.snap` before committing it.

use std::fs;
use std::path::Path;

use termcore::term::Term;

#[test]
fn fixtures_match_snapshots() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/compat");
    let update = std::env::var_os("UPDATE_SNAPSHOTS").is_some();
    let mut failures = Vec::new();
    let mut count = 0;
    let mut entries: Vec<_> = fs::read_dir(&dir).unwrap().map(|e| e.unwrap().path()).collect();
    entries.sort();
    for path in entries {
        if path.extension().and_then(|e| e.to_str()) != Some("in") {
            continue;
        }
        count += 1;
        let input = fs::read(&path).unwrap();
        let mut term = Term::new(80, 24, 100);
        term.feed(&input);
        let actual = term.dump();
        let snap = path.with_extension("snap");
        if update {
            fs::write(&snap, &actual).unwrap();
            continue;
        }
        match fs::read_to_string(&snap) {
            Ok(expected) if expected == actual => {}
            Ok(expected) => failures.push(format!(
                "{}\n--- expected\n{expected}\n--- actual\n{actual}\n",
                path.display()
            )),
            Err(_) => failures.push(format!(
                "{}: no snapshot. Run with UPDATE_SNAPSHOTS=1 and review the result.",
                path.display()
            )),
        }
    }
    assert!(count > 0, "no fixtures found in {}", dir.display());
    assert!(failures.is_empty(), "\n{}", failures.join("\n"));
}
```

- [ ] **Step 2: Write the fixture scripts**

Create `core/tests/compat/make_fixtures.sh` (save as UTF-8):

```sh
#!/bin/sh
# Regenerates the hand written fixtures. Each one exercises a family of
# escape sequences; the expected screen for each is listed in the
# implementation plan, Task 14.
set -eu
cd "$(dirname "$0")"

printf 'line one\r\nline two\r\n\033[3;5Hmoved\033[1;1H\033[2Cx\033[24;1Hbottom' > cursor.in
printf '\033[31mred\033[0m plain \033[1;44mbold on blue\033[m\r\n\033[38;2;1;2;3mtrue\033[38:5:200m 256\033[m' > colours.in
printf 'primary\033[?1049h\033[Halt text\033[?1049l back' > altscreen.in
printf '\033[2;4r\033[2;1Ha\r\nb\r\nc\r\nd\r\ne\033[r' > scrollregion.in
printf 'a%.0s' $(seq 1 100) > wrap.in
printf '日本語 ok\r\nnaïve 👍🏽 ❤️ end' > utf8.in
printf 'abcdef\033[3G\033[2@\033[6G\033[P\033[2K\033[Hgone\033[1;3H\033[K' > editing.in
```

Create `core/tests/compat/record.sh`:

```sh
#!/bin/sh
# Records a real program into a fixture at 80x24, the size the runner uses.
# Usage: record.sh NAME COMMAND [ARGS...]
# Example: record.sh vim-quit vim -u NONE -c ':q'
# Only deterministic programs make stable fixtures. Review the resulting
# .snap by eye before committing; the recording includes echoed input.
set -eu
cd "$(dirname "$0")"
name=$1
shift
stty cols 80 rows 24
script -q "$name.in" "$@"
```

Run:

```bash
chmod +x core/tests/compat/make_fixtures.sh core/tests/compat/record.sh
core/tests/compat/make_fixtures.sh
ls core/tests/compat/*.in | wc -l
```

Expected: `7`.

- [ ] **Step 3: Generate snapshots and check them by hand**

Run: `UPDATE_SNAPSHOTS=1 cargo test -p termcore --test compat`
Expected: 1 passed, and seven `.snap` files appear.

Each `.snap` is the 24 screen rows joined by newlines, so it holds 23 newline characters; when row 24 is blank the file therefore ends with a newline byte, and when row 24 has text it does not. Open each and check the non-empty lines against this table. Lines not listed must be empty.

| fixture | line | expected text |
|---|---|---|
| cursor | 1 | `lixe one` |
| cursor | 2 | `line two` |
| cursor | 3 | `    moved` |
| cursor | 24 | `bottom` |
| colours | 1 | `red plain bold on blue` |
| colours | 2 | `true 256` |
| altscreen | 1 | `primary back` |
| scrollregion | 2 | `c` |
| scrollregion | 3 | `d` |
| scrollregion | 4 | `e` |
| wrap | 1 | eighty `a` |
| wrap | 2 | twenty `a` |
| utf8 | 1 | `日本語 ok` |
| utf8 | 2 | `naïve 👍 ❤ end` |
| editing | 1 | `go` |

Derivations for the two least obvious ones. `editing`: `abcdef`, cursor to column 3, insert two blanks gives `ab  cdef`, cursor to column 6, delete one gives `ab  def`, erase whole line, home, print `gone`, cursor to column 3, erase to end gives `go`. `scrollregion`: region is rows 2 to 4, five lines are printed inside it, so the first two scroll off the top of the region and are lost.

If any line differs, the bug is in the core, not the fixture. Fix it in `screen.rs` or `grid.rs`, add a unit test there, regenerate, and check again.

- [ ] **Step 4: Run the test in checking mode**

Run: `cargo test -p termcore --test compat`
Expected: 1 passed.

- [ ] **Step 5: Commit**

```bash
git add core/tests/compat.rs core/tests/compat
git commit -m "test(core): add compatibility snapshot harness and fixtures"
```

---

### Task 15: Fuzz target

**Files:**
- Create: `core/fuzz/Cargo.toml`
- Create: `core/fuzz/fuzz_targets/feed.rs`
- Create: `core/fuzz/.gitignore`

**Interfaces:**
- Consumes: `Term::new`, `feed`, `resize`, `dump`.
- Produces: `cargo +nightly fuzz run feed` from `core/`.

- [ ] **Step 1: Write the fuzz crate**

`core/fuzz/Cargo.toml`:

```toml
[package]
name = "termcore-fuzz"
version = "0.0.0"
publish = false
edition = "2021"

[package.metadata]
cargo-fuzz = true

[dependencies]
libfuzzer-sys = "0.4"
termcore = { path = ".." }

[[bin]]
name = "feed"
path = "fuzz_targets/feed.rs"
test = false
doc = false
bench = false

[workspace]
```

`core/fuzz/fuzz_targets/feed.rs`:

```rust
//! Run from core/: cargo +nightly fuzz run feed -- -max_total_time=60
//! Needs: rustup toolchain install nightly && cargo install cargo-fuzz

#![no_main]

use libfuzzer_sys::fuzz_target;
use termcore::term::Term;

fuzz_target!(|data: &[u8]| {
    let mut term = Term::new(80, 24, 50);
    for chunk in data.chunks(7) {
        term.feed(chunk);
    }
    if let Some(&b) = data.first() {
        term.resize(1 + (b as usize % 120), 1 + (b as usize / 2 % 60));
        term.feed(data);
    }
    let _ = term.dump();
    let _ = term.selection_text();
});
```

`core/fuzz/.gitignore`:

```
target
corpus
artifacts
coverage
```

- [ ] **Step 2: Install the tooling and run for one minute**

Run:

```bash
rustup toolchain install nightly --profile minimal
cargo install cargo-fuzz --locked
cd core && cargo +nightly fuzz run feed -- -max_total_time=60
```

Expected: output ends with a line starting `Done` and a non zero run count, exit status 0. If it finds a crash it prints the artifact path under `core/fuzz/artifacts/feed/`. Reproduce with `cargo +nightly fuzz run feed <artifact path>`, fix the core, add a unit test with those bytes, rerun.

- [ ] **Step 3: Confirm the workspace still builds without nightly**

Run: `cargo test -p termcore`
Expected: all tests pass; the fuzz crate is excluded from the workspace and does not build here.

- [ ] **Step 4: Commit**

```bash
git add core/fuzz
git commit -m "test(core): add libFuzzer target for the feed path"
```

---

### Task 16: Throughput benchmark

**Files:**
- Create: `bench/Cargo.toml`
- Create: `bench/src/main.rs`
- Create: `bench/results.md`
- Modify: `Cargo.toml` (workspace members)

**Interfaces:**
- Consumes: `Term::new`, `feed`, `Screen::row_text`.
- Produces: `cargo run --release -p termbench` printing MB/s.

- [ ] **Step 1: Add the bench crate**

In the root `Cargo.toml`, change members to:

```toml
members = ["core", "bench"]
```

`bench/Cargo.toml`:

```toml
[package]
name = "termbench"
version = "0.1.0"
edition = "2021"
publish = false

[dependencies]
termcore = { path = "../core" }
```

`bench/src/main.rs`:

```rust
//! Feeds a deterministic 100 MB stream of mixed text and escape
//! sequences through the core and reports throughput.
//! Run: cargo run --release -p termbench

use std::time::Instant;

use termcore::term::Term;

const TARGET_BYTES: usize = 100 * 1024 * 1024;

fn build_stream() -> Vec<u8> {
    let mut out = Vec::with_capacity(TARGET_BYTES + 256);
    let mut state: u64 = 0x2545_F491_4F6C_DD1D;
    while out.len() < TARGET_BYTES {
        state = state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        match (state >> 60) % 6 {
            0 => out.extend_from_slice(b"\x1b[1;32mINFO\x1b[0m compiling module core::grid\r\n"),
            1 => out.extend_from_slice(b"\x1b[38;2;200;100;50mwarning:\x1b[m unused variable `x`\r\n"),
            2 => out.extend_from_slice(b"\x1b[2K\x1b[G[=====>     ] 42% building\r"),
            3 => out.extend_from_slice("日本語テキスト ünïcödé ✓ 👍\r\n".as_bytes()),
            4 => out.extend_from_slice(b"\x1b[3;1H\x1b[K\x1b[24;1H"),
            _ => {
                for _ in 0..4 {
                    out.extend_from_slice(
                        b"the quick brown fox jumps over the lazy dog 0123456789\r\n",
                    );
                }
            }
        }
    }
    out
}

fn main() {
    let stream = build_stream();
    let mut term = Term::new(200, 60, 10_000);
    let start = Instant::now();
    for chunk in stream.chunks(64 * 1024) {
        term.feed(chunk);
    }
    let elapsed = start.elapsed().as_secs_f64();
    let mb = stream.len() as f64 / (1024.0 * 1024.0);
    println!("fed {mb:.1} MB in {elapsed:.3} s = {:.0} MB/s", mb / elapsed);
    println!("last row: {:?}", term.screen().row_text(59));
}
```

`bench/results.md`:

```markdown
# Core throughput

`cargo run --release -p termbench` feeds 100 MB of mixed output into a
200 by 60 grid with 10,000 lines of scrollback. Add a row whenever a
commit changes performance. The end to end terminal benchmarks (latency,
startup, memory) live with the macOS shell.

| date | commit | machine | MB/s |
|---|---|---|---|
```

- [ ] **Step 2: Run it**

Run: `cargo run --release -p termbench`
Expected: two lines, the first ending in `MB/s`. Anything below 200 MB/s on Apple Silicon means something in the feed path allocates or copies per byte; profile with `cargo instruments` or `samply` before moving on.

- [ ] **Step 3: Record the first result**

Append a row to `bench/results.md` with today's date, the short commit hash from `git rev-parse --short HEAD`, the machine (`sysctl -n machdep.cpu.brand_string`) and the MB/s printed.

- [ ] **Step 4: Commit**

```bash
git add Cargo.toml bench
git commit -m "bench: add core feed throughput benchmark"
```

---

## Done criteria for this plan

- `cargo test -p termcore` passes: unit tests, `chaos`, `ffi`, `compat`.
- `cargo build -p termcore --release` yields `target/release/libtermcore.a` that links from C with the header.
- One minute of fuzzing finds nothing.
- `bench/results.md` has a first row.

The next plan builds the macOS shell against `core/include/termcore.h`.
