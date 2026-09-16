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

/* Creates a terminal. cols and rows must be at least 1; scrollback is
 * clamped to TERM_MAX_SCROLLBACK. Returns NULL on bad arguments. */
#define TERM_MAX_SCROLLBACK 1000000u
Term *term_new(uint16_t cols, uint16_t rows, uint32_t scrollback);
void term_free(Term *term);

/* Feeds raw PTY output. Never fails on content; only on a NULL term. */
int32_t term_feed(Term *term, const uint8_t *bytes, size_t len);
int32_t term_resize(Term *term, uint16_t cols, uint16_t rows);

/* Copies the visible grid (viewport applied) as packed cells in row
 * major order. out needs cols * rows entries or TERM_ERR_SMALL is
 * returned and nothing is written. */
int32_t term_grid(Term *term, uint64_t *out, size_t len);

/* Copies and clears the dirty row bitmap, one bit per visible row.
 * out needs (rows + 63) / 64 words or TERM_ERR_SMALL is returned and
 * the bitmap is left untouched. */
int32_t term_dirty_rows(Term *term, uint64_t *out, size_t len);

/* visible is 0 while the cursor is hidden or the viewport is scrolled
 * back; do not draw it then. */
int32_t term_cursor(Term *term, TermCursor *out);
int32_t term_modes(Term *term, TermModes *out);

/* Positive delta scrolls towards older content. Clamped. */
int32_t term_scroll_viewport(Term *term, int32_t delta);

/* Selection coordinates are visible cells (viewport applied).
 * mode: 0 normal, 1 word, 2 line. TERM_ERR_ARG if out of range. */
int32_t term_selection_start(Term *term, uint16_t col, uint16_t row, uint8_t mode);
int32_t term_selection_extend(Term *term, uint16_t col, uint16_t row);
int32_t term_selection_clear(Term *term);

/* Text getters: return the full UTF-8 length in bytes and write at
 * most len bytes, no NUL terminator. Call once with out = NULL to size
 * a buffer, then again with the buffer. A short buffer may cut a
 * multi-byte character. */
size_t term_selection_text(Term *term, uint8_t *out, size_t len);
size_t term_title(Term *term, uint8_t *out, size_t len);

/* Drains up to len bytes the terminal wants written back to the PTY
 * (cursor position and device attribute replies). Returns the count. */
size_t term_responses(Term *term, uint8_t *out, size_t len);

/* Copies the 24-bit overflow colours (cell index 256 upward) and
 * returns how many exist in total. Copies at most len entries. */
size_t term_colors(Term *term, TermRgb *out, size_t len);

#ifdef __cplusplus
}
#endif

#endif
