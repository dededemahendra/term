# Terminal emulator design

Date: 2026-09-16
Status: approved for planning

## Goal

A GUI terminal emulator, macOS first, that is lighter and faster than the
current field. Success is measured in this order:

1. Input latency. Keystroke to GPU commit under 1 ms median on Apple
   Silicon. Keystroke to pixel is then bounded by the display's refresh:
   about 8 ms average on a 60 Hz display, 4 ms on 120 Hz, which no
   terminal can beat.
2. Startup. Launch to first frame under 80 ms warm on Apple Silicon;
   AppKit and window server setup alone cost about 55 ms of that. Idle
   RSS under 80 MB, almost all of it AppKit and Metal framework memory.
   Near zero CPU when nothing is happening.
3. Throughput. Consume a 100 MB output stream without stalling, measured
   against Ghostty and Alacritty on the same machine.

Linux and Windows follow later. The core is portable from day one; only
the platform shell is macOS specific.

## Scope

### In for v1

- One window, one shell, single pane.
- Full VT100 and xterm compatibility. vim, tmux, htop, fish, Claude Code
  must all work.
- 24-bit colour, bold, italic, underline, strikethrough, inverse.
- Monospace font rendering with a glyph atlas. No ligatures.
- Scrollback with a fixed cap, stored in packed cells.
- Mouse selection, copy, paste with bracketed paste, drag scroll.
- Cmd-click on URLs.
- One plain text config file.
- Native macOS window: Retina, fullscreen, standard cmd shortcuts.
- Emoji and wide glyph (CJK) correctness. Basic emoji sequences (skin
  tone, ZWJ joins) collapse to one cell.

### Out for v1

- Tabs, splits, session restore.
- Ligatures.
- Images (Kitty or Sixel protocol).
- Theme gallery, GUI preferences, plugins, scripting.
- Shell integration, prompt markers, command history UI.
- Search in scrollback.
- Grapheme clustering beyond basic emoji sequences.
- Legacy character sets (DEC special graphics via ESC ( 0, SO and SI).
  The core is UTF-8 only; the programs named above draw boxes with
  Unicode under a UTF-8 locale.
- Config hot reload.
- Software rendering fallback.

## Architecture

One repo, two languages, three layers.

```
term/
  core/        Rust library. No platform code. C ABI (staticlib + cdylib).
  macos/       Swift package. AppKit window, PTY, CoreText, Metal renderer,
               assembled into Term.app by a script.
  bench/       Core throughput crate.
  bench-shell/ Startup, latency, throughput and memory scripts for the app.
  docs/superpowers/specs/
```

The core is the only layer that understands terminal semantics. It knows
nothing about windows, fonts, GPUs or processes. It takes bytes in and
answers questions about cells.

The Swift shell is deliberately thin. It pumps bytes from the PTY into the
core, asks the core what changed, draws it, and turns keystrokes into
bytes for the PTY.

### C ABI

The boundary is a small set of functions. Nothing else crosses it. There
are no callbacks from Rust into Swift.

- `term_new(cols, rows, scrollback) -> *Term`
- `term_free(*Term)`
- `term_feed(*Term, *const u8, len) -> status`
- `term_resize(*Term, cols, rows) -> status`
- `term_grid(*Term, *mut Cell, len) -> status` copies the visible grid as
  packed cells, in row major order, including the current scrollback
  viewport offset.
- `term_dirty_rows(*Term, *mut u64, len) -> status` copies the dirty row
  bitmap and clears it.
- `term_cursor(*Term, *mut CursorInfo) -> status` position, style,
  visibility.
- `term_modes(*Term, *mut Modes) -> status` bracketed paste, mouse
  reporting, application cursor keys, focus events, alt screen.
- `term_scroll_viewport(*Term, delta_rows)`
- `term_selection_start(*Term, col, row, mode)`,
  `term_selection_extend(*Term, col, row)`,
  `term_selection_clear(*Term)`
- `term_selection_text(*Term, *mut u8, len) -> written_len` UTF-8.
- `term_responses(*Term, *mut u8, len) -> written_len` bytes the terminal
  must write back to the shell (cursor position reports, device
  attributes). Mouse and focus reports originate in the shell, which
  encodes them itself using the modes the core exposes.
- `term_colors(*Term, *mut Rgb, len) -> status` the overflow colour table
  referenced by cell colour indices.

Every function returns a status code or a length. A failure is a bug and
the shell logs it. The shell never crashes on a core status.

## Core library (Rust)

Four modules, each independently testable.

### Parser

A VT500 series state machine in the design of the `vte` crate. Emits
actions (print, execute, CSI dispatch, OSC dispatch, ESC dispatch) to the
screen state. UTF-8 decoding happens here. Vendor and trim `vte` rather
than write from scratch; a hand rolled parser is where compatibility bugs
come from.

### Grid

Visible screen plus scrollback as a ring buffer of rows. A cell is one
packed 64-bit value:

| bits | field |
|---|---|
| 21 | codepoint |
| 8 | flags: bold, italic, underline, strike, inverse, wide, wide spacer, dim |
| 16 | foreground colour index |
| 16 | background colour index |
| 1 | selected (set only on copies handed to the renderer) |
| 2 | reserved |

Colour indices 0 to 255 are the xterm palette. Indices above 255 point
into an overflow table of RGB values, populated when an SGR sets a 24-bit
colour not already in the table. Index 0xFFFF is reserved as the
default colour marker, so the table holds 65,279 entries. It is never
evicted during a session. Fixed width packed cells mean row
copies are memcpy and the renderer reads them with no conversion.

Wide glyphs occupy two cells. The second is marked as a spacer. Width
comes from the Unicode East Asian Width table via a crate, plus an emoji
presentation table. Basic emoji sequences collapse into one cell.

Allocation policy: the grid is allocated once at creation and on resize.
Feeding bytes never allocates on the parse and grid path. The documented
exceptions are rare and bounded: interning a newly seen 24-bit colour,
building a DSR or DA reply, storing an OSC title, and a full reset (RIS),
which rebuilds the screen. Scrollback is a fixed ring; the oldest row is
overwritten.

### Screen state

Cursor, alternate screen, scroll region, saved cursor, current SGR
attributes, tab stops, and modes: bracketed paste, mouse reporting (X10,
normal, button, any, SGR encoding), application cursor keys, focus
events, origin mode, auto wrap, insert mode. This is what makes vim and
tmux behave.

### Selection and dirty tracking

Selection is a start and end in grid coordinates (scrollback aware) with
a mode: normal, word, line. Extracting text trims trailing whitespace per
row and joins rows with newlines unless the row was soft wrapped.

Dirty tracking is one bit per visible row, set by any write to that row
and cleared when the shell reads the bitmap. Scrolling marks every row
dirty.

## Rendering pipeline (Metal)

One pipeline, one draw call per frame. The shader source is embedded in
the app and compiled at runtime unless a precompiled library was built
with Xcode's Metal toolchain, in which case that is loaded instead.

The renderer keeps a persistent vertex buffer with one instance per cell.
Each instance is 16 bytes: grid column and row, atlas rectangle index,
foreground RGBA, background RGBA, flags. The vertex shader expands each
instance into a quad. The fragment shader samples the atlas for the glyph
and composites over the background. Underline, strikethrough, inverse and
the cursor are drawn by the same shader from flags. No second pass.

### Glyph atlas

One texture, grown on demand, populated lazily. When the shell meets a
codepoint and style the atlas has not seen, it rasterises with CoreText
into the atlas and caches the rectangle. Regular, bold, italic and bold
italic are separate entries. No eviction in v1.

### Per frame

1. Read dirty row bitmap from the core.
2. For each dirty row, read cells, look up or rasterise glyphs, rewrite
   that row's instances in the vertex buffer.
3. One draw call.

## Frame scheduling

This is the most important decision in the project.

- The PTY read runs on its own thread. It reads into a buffer, feeds the
  core immediately, then signals the main thread that the grid changed.
- The main thread does not wait for vsync. It renders as soon as
  signalled, with a coalescing window of about 1 ms so a burst of output
  produces one frame.
- The Metal layer runs with `presentsWithTransaction = false` and
  `displaySyncEnabled = false`, so a frame is presented when the GPU
  finishes rather than at the next vertical blank.
- Key input is handed to one serial write queue as soon as the key
  arrives, so a child that stops reading can never block the window or the
  reader thread; the hop costs tens of microseconds. Echo returns through
  the read path.
- Under sustained flood, if the core is fed faster than frames render,
  the render loop skips intermediate states and draws only the latest.
  The parser never blocks on the renderer.

## Platform shell (macOS, Swift)

- Window: one `NSWindow` with an `NSView` backed by `CAMetalLayer`.
  Retina via contents scale. Fullscreen, resize, configured padding.
  Resize recomputes grid size from the font's cell metrics and calls
  `term_resize`, then sends `TIOCSWINSZ`.
- PTY: `forkpty` through a small C shim (Swift cannot fork safely).
  Spawns the configured shell as a login shell with `TERM=xterm-256color`
  and `COLORTERM=truecolor`. Window size changes send `TIOCSWINSZ`. The
  child is hung up with SIGHUP on close; the reader thread closes the
  master afterwards, because closing it from another thread deadlocks on
  macOS.
- Input: control, function and option-as-meta keys are encoded straight
  from the key event; everything else goes through `NSTextInputClient`,
  so dead keys and input methods work. Cmd shortcuts: new window, close
  window, copy, paste, select all, font size up, down and reset. Paste is
  wrapped when bracketed paste mode is on.
- Mouse: click, drag, double and triple click drive core selection.
  Cmd-click on a URL opens it via `NSWorkspace`. Scroll wheel moves the
  viewport. When the program has mouse reporting on, events are encoded
  and sent to the PTY instead.
- Fonts: CoreText for rasterisation and metrics. One family, one size,
  four styles. Fallback for emoji and CJK comes from the CoreText cascade
  list.
- Clipboard: `NSPasteboard`, plain text only.

## Config

One file at `~/.config/term/config`. Flat `key = value`, one per line,
`#` comments. No sections, no includes. Parsed by the shell at launch.
Unknown keys are ignored with a warning on stderr. Missing file means
defaults. No reload; restart to apply.

| key | default |
|---|---|
| `font` | `Menlo` |
| `font-size` | `13` |
| `line-height` | `1.0` |
| `shell` | login shell from `SHELL`, else `/bin/zsh` |
| `scrollback` | `10000` |
| `padding` | `8` |
| `cursor-style` | `block` (`block`, `bar`, `underline`) |
| `cursor-blink` | `false` |
| `cursor-color` | `#ffffff` |
| `foreground` | `#d0d0d0` |
| `background` | `#000000` |
| `selection-background` | `#444444` |
| `color0` to `color15` | xterm defaults |
| `alt-is-meta` | `true` |
| `copy-on-select` | `false` |

## Error handling

The core never panics on input. Any byte sequence is consumed or
ignored. Enforced by fuzzing. C ABI functions return status codes; the
shell logs failures and continues.

Shell runtime failures, each with one defined behaviour:

- PTY spawn fails: open the window, print the error into the grid, exit
  on the next keypress.
- Font not found: fall back to Menlo with a stderr warning.
- Metal device unavailable: exit with a message.

Child exit closes the window. Nothing is restarted.

## Testing

- Core unit tests in Rust for parser, grid, screen state and selection.
- Compatibility tests: recorded byte streams from real programs (vim,
  htop, tmux, a Claude Code session) with expected grid snapshots. A
  regression shows as a snapshot diff.
- Fuzzing with `cargo fuzz` on `term_feed`, run in CI with a fixed time
  budget.
- Shell unit tests in Swift for key to escape sequence mapping and config
  parsing. The renderer is verified visually and by benchmarks.

## Benchmarks

Live in `bench/`, run manually, results recorded in
`bench/results.md` per commit that touches performance.

| benchmark | method | target |
|---|---|---|
| Latency | synthetic keystrokes echoed by the tty; time to GPU commit and to presented frame, median and p99 | under 1 ms median to commit |
| Startup | process start to first presented frame, warm, median of five | under 80 ms |
| Throughput | time to cat a fixed 100 MB file, compared with Ghostty and Alacritty when installed | at parity or better |
| Memory | RSS of the idle app after two seconds | under 80 MB |

Every result row records the display and its backing scale, because a
1x display draws a quarter of the pixels of a 2x one and the shell has
separate code paths for 1 px and 2 px decorations.

## Build and distribution

- `cargo build --release` builds the core as a static library; a
  `--universal` script option adds x86_64 and merges the two with lipo.
  Rust is pinned by `rust-toolchain.toml`.
- The macOS app is a Swift package linking the static library. A script
  assembles `Term.app` with an ad hoc signature for development; the
  release script builds a universal binary, signs and notarises when
  credentials are in the environment, and produces a `.dmg`. Tests run
  with `swift test` under Xcode's toolchain (`DEVELOPER_DIR`), because
  the command line tools ship no XCTest.
- Release is a notarised `.dmg` and a Homebrew cask.

## Open decisions deferred to later versions

- Tabs and splits.
- Search.
- Ligatures and full grapheme clustering.
- Linux shell (Wayland plus Vulkan or OpenGL) and Windows shell (ConPTY
  plus DirectX).
