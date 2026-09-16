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
