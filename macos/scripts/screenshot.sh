#!/bin/sh
# Runs a command in the terminal, captures the window after 1.5 s and
# writes a PNG. Usage: scripts/screenshot.sh OUT.png COMMAND [ARGS...]
set -eu
cd "$(dirname "$0")/.."
out=$1
shift
TERM_SCREENSHOT="$out" build/Term.app/Contents/MacOS/Term -e /bin/sh -c "$*; sleep 3"
echo "wrote $out"
