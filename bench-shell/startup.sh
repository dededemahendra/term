#!/bin/sh
# Median warm launch time (process start to first presented frame) over
# five runs of the bundled app. Prints one number in milliseconds.
set -eu
cd "$(dirname "$0")/../macos"
BIN=build/Term.app/Contents/MacOS/Term
TERM_PROBE=1 TERM_SCREENSHOT=/dev/null "$BIN" -e /bin/sleep 1 >/dev/null 2>&1 || true
for i in 1 2 3 4 5; do
    TERM_PROBE=1 TERM_SCREENSHOT=/dev/null "$BIN" -e /bin/sleep 1 2>&1 | sed -n 's/^startup: \([0-9.]*\) ms.*/\1/p'
done | sort -n | sed -n '3p'
