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

/// Upper bound on scrollback rows accepted by `term_new`.
pub const TERM_MAX_SCROLLBACK: u32 = 1_000_000;

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
    let scrollback = scrollback.min(TERM_MAX_SCROLLBACK) as usize;
    Box::into_raw(Box::new(Term::new(cols as usize, rows as usize, scrollback)))
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
