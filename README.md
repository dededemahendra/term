# term

A fast, lightweight terminal emulator. The goal is the lowest possible
keystroke latency, a quick cold start and high throughput, in that order.
macOS is the first target; the core is written to port to Linux and
Windows later.

## Architecture

Two pieces with a narrow boundary between them:

- **`core/`** is a portable Rust library (`termcore`). It holds the VT
  parser, a packed-cell grid with scrollback, screen state, selection and
  the response bytes a program expects back. It exposes a small C ABI
  (`core/include/termcore.h`) and links as a static library. It knows
  nothing about any platform's windowing or graphics.
- **`macos/`** is a thin Swift and AppKit shell that draws the grid with
  Metal. One instanced draw call per frame, a glyph atlas built with Core
  Text, a pseudo terminal for the child process, and keyboard, mouse and
  clipboard handling. It talks to the core only through the C ABI.

Keeping the state and parsing in a platform-free core means a second
platform is a new shell, not a rewrite.

## Features

- 256-colour and 24-bit truecolour, with bold, italic, underline,
  strikethrough, dim, inverse and hidden text.
- Wide characters and colour emoji, with Core Text font fallback for
  glyphs the primary font lacks.
- Scrollback, selection by character, word and line, copy and paste with
  bracketed paste, and Command-click to open a URL.
- Live font zoom, multiple windows, and a flat `key = value` config file.
- Deliberately no tabs.

## Performance

Measured on an Apple M4, warm, at backing scale 1. Numbers move with the
machine and the display; the method and results live in
`bench-shell/results.md` and `bench/`.

- Keystroke to GPU commit around 0.5 ms; keystroke to presented frame
  around 4.8 ms on a 60 Hz display.
- A 100 MB stream consumed in about 0.9 s, faster than Ghostty (1.3 s)
  and close to Alacritty (0.8 s) on the same machine.
- Idle resident memory around 80 MB.
- Warm start to first frame around 105 ms. This is still above the 80 ms
  target and is dominated by fixed AppKit and driver start-up cost;
  see the benchmark notes.

## Requirements

- macOS 14 or later on a Metal-capable Mac (any Mac from the last decade).
- Xcode and its toolchain to build; the Rust toolchain is pinned by
  `rust-toolchain.toml`.

## Build and run

```sh
# Build the Rust core as a static library.
macos/scripts/build-core.sh            # add --universal for x86_64 + arm64

# Build and assemble macos/build/Term.app, then launch it.
macos/scripts/bundle.sh
macos/scripts/run.sh
```

Run the test suites with:

```sh
cargo test                             # core
swift test --package-path macos        # shell
```

The Metal shader is compiled at runtime from source, so the app builds
and runs without Xcode's separate Metal toolchain. `macos/scripts/build-shaders.sh`
precompiles it into the bundle when that toolchain is installed.

## Configuration

Settings live in `~/.config/term/config`, a flat `key = value` file that
is read at launch. Colours are `#rrggbb`. Keys include `font`,
`font-size`, `line-height`, `padding`, `cursor-style`, `cursor-blink`,
`scrollback`, `foreground`, `background` and `shell`.

For a Starship or powerline prompt, set a Nerd Font as the primary font,
for example:

```
font = JetBrainsMono Nerd Font Mono
```

The icons those prompts use live in Unicode's Private Use Area, which has
no system fallback, so the primary font must supply them.

## Status

Version 0.1, macOS only. Linux and Windows shells, Retina benchmark
runs and further start-up work are the planned next steps.

## Licence

Not yet chosen. Until a licence is added, all rights are reserved.
