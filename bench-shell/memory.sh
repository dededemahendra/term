#!/bin/sh
# Resident memory of the idle app after two seconds, in MB.
set -eu
cd "$(dirname "$0")/../macos"
build/Term.app/Contents/MacOS/Term -e /bin/sleep 4 >/dev/null 2>&1 &
sleep 2
ps -o rss= -p "$!" | awk '{printf "%.0f MB\n", $1 / 1024}'
wait
