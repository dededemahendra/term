#!/bin/sh
# Time to cat a 100 MB text file through the terminal. Also runs the
# same file through Ghostty and Alacritty when they are installed.
set -eu
cd "$(dirname "$0")/../macos"
BIG=/tmp/term-bench-100mb.txt
if [ ! -f "$BIG" ]; then
    python3 -c "
import sys
line = ('the quick brown fox jumps over the lazy dog 0123456789 ' * 2) + '\n'
sys.stdout.write(line * (100 * 1024 * 1024 // len(line)))" > "$BIG"
fi
OUT=/tmp/term-bench-throughput.txt
rm -f "$OUT"
build/Term.app/Contents/MacOS/Term -e /bin/sh -c "( time cat $BIG ) 2> $OUT"
printf 'term: '; grep real "$OUT"
for app in Ghostty Alacritty; do
    if [ -d "/Applications/$app.app" ]; then
        rm -f "$OUT"
        open -n "/Applications/$app.app" --args -e /bin/sh -c "( time cat $BIG ) 2> $OUT"
        # Wait for the timing to land, then close the comparison instance
        # ourselves: some terminals keep their window open after -e exits.
        for _ in $(seq 1 60); do
            [ -s "$OUT" ] && break
            sleep 1
        done
        sleep 1
        pkill -f "term-bench-100mb" 2>/dev/null || true
        printf '%s: ' "$app"; grep real "$OUT" || echo "no result"
    fi
done
