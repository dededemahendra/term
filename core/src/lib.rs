//! Portable terminal emulator core.
//!
//! Bytes in, cells out. No windows, fonts, GPUs or processes live here.

pub mod cell;
pub mod color;
pub mod ffi;
pub mod grid;
pub mod screen;
pub mod selection;
pub mod term;

#[cfg(test)]
mod smoke {
    #[test]
    fn workspace_builds() {
        assert_eq!(2 + 2, 4);
    }
}
