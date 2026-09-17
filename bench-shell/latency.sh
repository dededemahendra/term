#!/bin/sh
# Keystroke latency: 200 synthetic keys echoed by the tty. Prints the
# probe's summary line: key to GPU commit is the terminal's own cost,
# key to present includes the display's refresh wait.
set -eu
cd "$(dirname "$0")/../macos"
TERM_PROBE=1 TERM_PROBE_KEYS=200 build/Term.app/Contents/MacOS/Term -e /bin/cat 2>&1 | grep '^latency' | tail -1
