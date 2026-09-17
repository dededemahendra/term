# Shell benchmarks

Run each script from the repository root after `macos/scripts/bundle.sh`.
Latency splits into the terminal's own cost (key to GPU commit) and the
display's refresh wait (key to presented frame); the second depends on
the monitor. Add a row whenever a change affects performance.

| date | commit | machine and display | startup warm | key to commit | key to present | 100 MB cat | idle RSS |
|---|---|---|---|---|---|---|---|
| 2026-09-17 | pre-plan spike | Apple M4, 60 Hz 1080p external | 100 ms | 0.47 ms | 7.3 ms | 0.75 s | 74 MB |
| 2026-09-17 | 08c9681 | Apple M4, 60 Hz 1080p external | 147.6 ms | 0.48 ms | 4.81 ms | 0.88 s | 81 MB |
