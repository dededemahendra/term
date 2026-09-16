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
