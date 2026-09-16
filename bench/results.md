# Core throughput

`cargo run --release -p termbench` feeds 100 MB of mixed output into a
200 by 60 grid with 10,000 lines of scrollback. Add a row whenever a
commit changes performance. The end to end terminal benchmarks (latency,
startup, memory) live with the macOS shell.

| date | commit | machine | MB/s |
|---|---|---|---|
| 2026-09-16 | 51ae344 | Apple M4 | 197 |
