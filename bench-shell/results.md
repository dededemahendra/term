# Shell benchmarks

Run each script from the repository root after `macos/scripts/bundle.sh`.
Latency splits into the terminal's own cost (key to GPU commit) and the
display's refresh wait (key to presented frame); the second depends on
the monitor. Add a row whenever a change affects performance.

| date | commit | machine, display and backing scale | startup warm | key to commit | key to present | 100 MB cat | idle RSS |
|---|---|---|---|---|---|---|---|
| 2026-09-17 | pre-plan spike | Apple M4, 60 Hz 1080p external, 1x | 100 ms | 0.47 ms | 7.3 ms | 0.75 s | 74 MB |
| 2026-09-17 | 08c9681 | Apple M4, 60 Hz 1080p external, 1x | 147.6 ms | 0.48 ms | 4.81 ms | 0.88 s | 81 MB |
| 2026-09-18 | 5345fac | Apple M4, 60 Hz 1080p external, 1x | 105.6 ms | 0.48 ms | 4.81 ms | 0.88 s | 81 MB |

Both rows were measured at backing scale 1 on the external display; the
2x path (the built-in Retina panel) has not been measured yet.

Startup at 08c9681 breaks down as roughly 95 ms from process start to
the pipeline being built (framework load, atlas, shader compile) and
about 51 ms from there to the first presented frame. The second part is
the first `nextDrawable` plus the size handshake; the precompiled shader
library saves about 1 ms, so it is not the lever. The fix wave removed
the redundant resizes in that window; the drawable cost remains a
hand-over item.

The 5345fac row measures the shared-device change: `MTLCreateSystemDefaultDevice`
now runs on a background thread from the first line of the process, and the
window reuses that one device. Over twelve interleaved warm launches the median
process-start-to-first-frame fell from 110.8 ms to 105.6 ms (mean 112.1 to
105.2, minimum 100.6 to 96.7). The 147.6 ms figure was a cold first bundle;
warm launches of the merged code without this change sit around 110 ms.

Warm startup is still above the 80 ms target and now sits close to a floor
this architecture imposes. A representative marks trace: process start to
`main` about 7 ms; to just before `app.run()` about 52 ms (first
`NSApplication.shared` and Metal or GPU-driver initialisation, which do not
parallelise with each other); `app.run()` to the launch callback about 26 ms
of AppKit run-loop spin-up; then session, atlas and pipeline about 10 ms; the
first `renderer.update` and `nextDrawable` about 14 ms; and the first GPU
present about 10 ms. The roughly 85 ms before our own first-frame work is
fixed AppKit, dyld and driver cost that a tuning pass cannot remove; the
remaining levers are architectural (a resident process that reuses a warm
window, or linking fewer frameworks), not code tuning. Latency, the higher
priority, already meets its target.
