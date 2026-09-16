//! Portable terminal emulator core.
//!
//! Bytes in, cells out. No windows, fonts, GPUs or processes live here.

pub mod cell;

#[cfg(test)]
mod smoke {
    #[test]
    fn workspace_builds() {
        assert_eq!(2 + 2, 4);
    }
}
