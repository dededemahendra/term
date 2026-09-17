# Shell benchmarks

Run each script from the repository root after `macos/scripts/bundle.sh`.
Latency splits into the terminal's own cost (key to GPU commit) and the
display's refresh wait (key to presented frame); the second depends on
the monitor. Add a row whenever a change affects performance.

| date | commit | machine, display and backing scale | startup warm | key to commit | key to present | 100 MB cat | idle RSS |
|---|---|---|---|---|---|---|---|
| 2026-09-17 | pre-plan spike | Apple M4, 60 Hz 1080p external, 1x | 100 ms | 0.47 ms | 7.3 ms | 0.75 s | 74 MB |
| 2026-09-17 | 08c9681 | Apple M4, 60 Hz 1080p external, 1x | 147.6 ms | 0.48 ms | 4.81 ms | 0.88 s | 81 MB |

Both rows were measured at backing scale 1 on the external display; the
2x path (the built-in Retina panel) has not been measured yet.

Startup at 08c9681 breaks down as roughly 95 ms from process start to
the pipeline being built (framework load, atlas, shader compile) and
about 51 ms from there to the first presented frame. The second part is
the first `nextDrawable` plus the size handshake; the precompiled shader
library saves about 1 ms, so it is not the lever. The fix wave removed
the redundant resizes in that window; the drawable cost remains a
hand-over item.
