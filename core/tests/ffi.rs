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

#[test]
fn scrolled_back_viewport_hides_cursor_and_shows_history() {
    unsafe {
        let t = term_new(4, 2, 5);
        let input = b"a\r\nb\r\nc";
        term_feed(t, input.as_ptr(), input.len());
        assert_eq!(term_scroll_viewport(t, 1), TERM_OK);
        let mut cursor = TermCursor::default();
        assert_eq!(term_cursor(t, &mut cursor), TERM_OK);
        assert_eq!(cursor.visible, 0);
        let mut cells = vec![0u64; 8];
        assert_eq!(term_grid(t, cells.as_mut_ptr(), 8), TERM_OK);
        assert_eq!(cells[0] & 0x1F_FFFF, 'a' as u64);
        assert_eq!(term_scroll_viewport(t, -1), TERM_OK);
        assert_eq!(term_cursor(t, &mut cursor), TERM_OK);
        assert_eq!(cursor.visible, 1);
        term_free(t);
    }
}

#[test]
fn scrollback_is_clamped() {
    unsafe {
        let t = term_new(2, 2, u32::MAX);
        assert!(!t.is_null());
        assert_eq!((*t).screen().grid().scrollback_capacity(), TERM_MAX_SCROLLBACK as usize);
        term_free(t);
    }
}
